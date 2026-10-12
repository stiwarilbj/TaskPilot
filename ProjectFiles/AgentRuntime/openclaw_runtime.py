#!/usr/bin/env python3
"""OpenClaw-powered visible desktop loop for TaskPilot.

TaskPilot owns macOS permissions, capture, Accessibility actions, display routing,
and cleanup. This helper sends each current TaskPilot observation to OpenClaw over
the official ACP stdio bridge, asks for one JSON action, and returns that action
to the native controller over JSONL.
"""

from __future__ import annotations

import argparse
import base64
from collections import deque
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
import shutil
import shlex
import signal
import subprocess
import sys
import threading
import time
import uuid
import tempfile
import struct
import zlib
from datetime import datetime
from typing import Any


MAX_STEPS = 100
MAX_IDENTICAL_ACTIONS = 3
PROMPT_TIMEOUT_SECONDS = None  # Wait for completion or an explicit provider/transport error.
SCREEN_POLL_SECONDS = 0.15
SCREEN_STABLE_SECONDS = 0.3
PRODUCT_NAME = "TaskPilot"
LEGACY_APPLICATION_SUPPORT_FOLDER = "Orbit Agent"
from request_policy import (
    ALL_MODELS, PRIMARY_MODELS, FALLBACK_MODELS, CONFIG_VERSION,
    AdaptiveModelRouter, Failure, ModelAttemptError, RecoveryExhaustedError, RuntimeState, classify_failure, model_route,
)
from provider_errors import ProviderRequestError, facts as provider_error_facts, message_text, response_error
from action_receipts import BridgeReplyLost, RuntimeInbox, reconcile_receipt
from prompt_compiler import (
    PROMPT_COMPILER_VERSION, COMPLETION_RULES, json_data, recovery_condition,
    decision_rules, compile_prompt, compile_repair,
)

from observation_context import select_elements, historical_progress, coordinate_targets, structural_identity, RELATIONSHIPS_VERSION, words
from screen_coordinates import COORDINATE_MAPPING_VERSION, CoordinateMappingError, validate_observation_mapping
from observation_completeness import (OBSERVATION_COMPLETENESS_VERSION, ObservationCompletenessError,
                                      validate_completeness, prompt_coverage, coverage_cache_input)
from local_text_recognition import (TEXT_RECOGNITION_VERSION, TextRecognitionError,
                                    validate_text_recognition, prompt_text_recognition, detail_images)
from task_evidence import TaskEvidenceLedger, CHECKLIST_VERSION, LARGEST_PATTERN
from expected_effects import ExpectedEffect, EXPECTED_EFFECT_VERSION, FILE_EFFECTS

from response_validation import (
    VALIDATION_VERSION, ResponseValidationError, extract_json_object, bind_command_outcomes,
    normalize_action, validate_response,
)

MAX_COMPACT_ELEMENTS = 360
MAX_RECENT_ACTIONS = 8
from action_contract_generated import (
    TASK_PROTOCOL_VERSION,
    CONTRACT_HASH, CONTRACT_VERSION, VALID_ACTIONS, TRUSTED_NATIVE_ACTIONS,
    action_example, action_default, ACTION_REFERENCE, PROMPT_BOUNDS, ACTION_CAPABILITIES,
    CONTRACT, operation_example, COMMAND_OPERATION_REFERENCE,
)


STANDARD_LOCATIONS = {
    "desktop": "~/Desktop",
    "documents": "~/Documents",
    "downloads": "~/Downloads",
    "home": "~",
    "pictures": "~/Pictures",
    "movies": "~/Movies",
    "music": "~/Music",
}

_active_acp_process: subprocess.Popen[str] | None = None
_bridge_observation_revision: str | None = None
_task_generation_id: str | None = None
_observation_keywords: list[str] = []
_runtime_inbox: RuntimeInbox | None = None
_receipt_metrics = {"receipt_queries": 0, "receipt_recoveries": 0, "receipt_unresolved": 0}


def runtime_line(timeout: float | None = None) -> str:
    global _runtime_inbox
    if _runtime_inbox is None or _runtime_inbox.stream is not sys.stdin:
        _runtime_inbox = RuntimeInbox(sys.stdin)
    return _runtime_inbox.read(timeout)


class ActionRejected(RuntimeError):
    def __init__(self, message: str, code: str = "action_rejected") -> None:
        super().__init__(message)
        self.code = code


class ModelCapacityError(RuntimeError):
    """A selected model hit a quota, rate, or temporary-capacity limit."""


def is_model_capacity_failure(error: BaseException | str) -> bool:
    message = str(error).lower()
    markers = (
        "429", "503", "rate limit", "rate-limit", "rate_limit", "quota", "resource exhausted",
        "resource_exhausted", "too many concurrent", "throttl", "concurrency limit",
        "weekly limit", "monthly limit", "daily limit", "usage limit",
        "all models failed", "overloaded", "model is unavailable", "model unavailable",
        "code=unavailable", "high demand", "temporarily unavailable",
        "first response retry", "model request timed out", "model timed out",
    )
    return isinstance(error, ModelCapacityError) or any(marker in message for marker in markers)


class TaskModelRouter(AdaptiveModelRouter):
    def __init__(self, state: RuntimeState | None = None) -> None:
        super().__init__(emit=emit, state=state)


def emit(kind: str, **payload: Any) -> None:
    envelope = {"kind": kind, **payload}
    if _task_generation_id is not None: envelope["task_generation_id"] = _task_generation_id
    print(json.dumps(envelope, separators=(",", ":")), flush=True)


def runtime_fingerprint(key: str) -> str:
    if key:
        return hashlib.sha256(key.encode()).hexdigest()
    # A profile-file digest invalidates readiness after external credential edits
    # without ever storing or emitting the credential itself.
    profile = Path.home() / ".openclaw/agents/main/agent/auth-profiles.json"
    try:
        return hashlib.sha256(profile.read_bytes()).hexdigest()
    except OSError:
        return "unconfigured"


def openclaw_version(path: str) -> str:
    result = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError("OpenClaw could not report its version. Repair the installation in Settings.")
    return result.stdout.strip()


def synchronize_model_configuration(path: str, state: RuntimeState) -> None:
    if state.value.get("config_version") == CONFIG_VERSION:
        return
    removed = {f"google/gemini-{v}-flash" for v in ("3.5", "3.6", "3.7")}
    def read(setting: str) -> Any:
        result = subprocess.run([path, "config", "get", setting], capture_output=True, text=True, timeout=15)
        if result.returncode:
            return None
        try:
            return json.loads(result.stdout)
        except ValueError:
            return result.stdout.strip()
    def write(setting: str, value: Any) -> None:
        result = subprocess.run([path, "config", "set", setting, json.dumps(value), "--strict-json", "--replace"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        if result.returncode:
            raise RuntimeError(f"TaskPilot could not update its {setting} model configuration. Reconfigure OpenClaw in Settings.")
    allowed = read("agents.defaults.modelPolicy.allow") or []
    extras = [m for m in allowed if isinstance(m, str) and m not in ALL_MODELS and m not in removed] if isinstance(allowed, list) else []
    write("agents.defaults.modelPolicy.allow", list(ALL_MODELS) + extras)
    model = read("agents.defaults.model")
    current = model if isinstance(model, dict) else {}
    extras = [m for m in current.get("fallbacks", []) if m not in ALL_MODELS and m not in removed]
    write("agents.defaults.model", {**current, "primary": PRIMARY_MODELS[0], "fallbacks": list(ALL_MODELS[1:]) + extras})
    image = read("agents.defaults.imageModel")
    if isinstance(image, dict):
        write("agents.defaults.imageModel", {**image, "primary": PRIMARY_MODELS[0], "fallbacks": [m for m in image.get("fallbacks", []) if m not in removed and m != PRIMARY_MODELS[0]]})
    aliases = read("agents.defaults.models")
    if isinstance(aliases, dict) and removed.intersection(aliases):
        write("agents.defaults.models", {m: v for m, v in aliases.items() if m not in removed})
    state.value["config_version"] = CONFIG_VERSION
    state.invalidate()


def model_configuration_fingerprint() -> str:
    path = Path(os.environ.get("OPENCLAW_CONFIG_PATH", str(Path.home() / ".openclaw/openclaw.json")))
    try:
        defaults = json.loads(path.read_text()).get("agents", {}).get("defaults", {})
        settings = {key: defaults.get(key) for key in ("model", "modelPolicy", "imageModel", "models")}
        return hashlib.sha256(json.dumps(settings, sort_keys=True).encode()).hexdigest()
    except (OSError, ValueError, AttributeError):
        return "unconfigured"


def prepare_runtime(path: str, key: str) -> RuntimeState:
    fingerprint, version = runtime_fingerprint(key), openclaw_version(path)
    state = RuntimeState(fingerprint, version, configuration=model_configuration_fingerprint())
    synchronize_model_configuration(path, state)
    state = RuntimeState(fingerprint, version, configuration=model_configuration_fingerprint())
    if key:
        sync_openclaw_google_key(path, key)
    return state


def synthetic_check_image(path: Path) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = b"".join(b"\0" + b"\xff\xff\xff" * 16 for _ in range(16))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) +
                     chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def check_models(path: str, key: str, read_only: bool = False) -> bool:
    state = RuntimeState(runtime_fingerprint(key), openclaw_version(path), configuration=model_configuration_fingerprint()) if read_only else prepare_runtime(path, key)
    checks = {m: {"model": m, "state": "configured", "detail": "Configured; not verified through TaskPilot"} for m in ALL_MODELS}
    for model in ALL_MODELS:
        checks[model].update(state.health(model))
    cached = state.verified_model()
    if cached:
        checks[cached].update(state="verified", detail="Verified through TaskPilot within the last ten minutes")
        emit("model_checks", checks=list(checks.values()), cached=True)
        return True
    if read_only:
        emit("model_checks", checks=list(checks.values()), cached=False)
        return False
    # A reported reset suppresses premature checks. With no reset, an explicit
    # Check may probe the owning model once to detect repaired billing/quota.
    unresolved = next((m for m in ALL_MODELS if state.credential_health(m).get("state") == "temporary" and
                       state.credential_health(m).get("retry_at") is None), None)
    probes = {m for m in ALL_MODELS if state.health(m).get("state") == "temporary" and state.health(m).get("retry_at") is None}
    if unresolved:
        owner = model_route(Failure.from_health(state.credential_health(unresolved)), unresolved)
        unresolved = owner if owner in ALL_MODELS else unresolved
        probes = {unresolved}
    if all(state.health(m).get("state") == "temporary" for m in ALL_MODELS) and not probes:
        emit("model_checks", checks=list(checks.values()), cached=False, prompt_calls=0, repairs=0)
        return False
    try:
        client = ACPClient(path)
    except Exception as error:
        state.record_failure(PRIMARY_MODELS[0], classify_failure(error, time.time(), PRIMARY_MODELS[0]))
        checks[PRIMARY_MODELS[0]].update(state.health(PRIMARY_MODELS[0]))
        emit("model_checks", checks=list(checks.values()), cached=False, prompt_calls=0)
        return False
    try:
        with tempfile.TemporaryDirectory(prefix="taskpilot-check-") as directory:
            image = Path(directory) / "check.png"
            synthetic_check_image(image)
            budget = ResponseRepairBudget()
            exhausted: set[str] = set()
            for model in ALL_MODELS:
                if model in exhausted or (model not in probes and state.health(model).get("state") == "temporary"):
                    continue
                try:
                    client.select_model(model)
                    validated_prompt(client, 'Do not call tools. Inspect this synthetic image and return exactly {"status":"done","check":"TASKPILOT_READY"}.', image, "readiness", budget)
                except Exception as error:
                    failure = classify_failure(error, time.time(), model)
                    state.record_failure(model, failure)
                    probes.discard(model)
                    if failure.scope == "credential":
                        probes.difference_update(m for m in ALL_MODELS if m.startswith((failure.provider or model.split('/', 1)[0]) + '/'))
                    stop = failure.kind in {"credentials", "transport", "configuration", "cancelled"}
                    for item in failure.attempts:
                        prior = Failure.from_health(item)
                        prior.recovered_upstream = True
                        if not prior.model and not (prior.scope == "credential" and prior.provider == model.split('/', 1)[0]):
                            continue
                        route = model_route(prior, model)
                        if route in ALL_MODELS:
                            state.record_failure(route, prior)
                            if prior.scope == "credential":
                                probes.difference_update(m for m in ALL_MODELS if m.startswith((prior.provider or model.split('/', 1)[0]) + '/'))
                            exhausted.add(route)
                            stop = stop or prior.kind in {"credentials", "transport", "configuration", "cancelled"}
                    for other in ALL_MODELS:
                        checks[other].update(state.health(other))
                    if stop:
                        break
                    continue
                state.verify(model)
                for other in ALL_MODELS:
                    checks[other] = {"model": other, "state": "configured", "detail": "Configured; not verified through TaskPilot", **state.health(other)}
                checks[model].update(state="verified", detail="Verified through TaskPilot with image input and structured output")
                break
    finally:
        client.close()
    emit("model_checks", checks=list(checks.values()), cached=False, prompt_calls=client.prompt_calls, repairs=int(budget.used))
    return any(c["state"] == "verified" for c in checks.values())


def bridge_exchange(method: str, display_id: int, params: dict[str, Any], timeout: float | None = None) -> dict[str, Any]:
    request_id = str(uuid.uuid4())
    emit(
        "bridge_request",
        request_id=request_id,
        method=method,
        params={"display_id": display_id, **params},
    )
    deadline = None if timeout is None else time.monotonic() + timeout
    while True:
        remaining = None if deadline is None else deadline - time.monotonic()
        if remaining is not None and remaining <= 0:
            raise BridgeReplyLost("The native action reply did not arrive; checking its receipt")
        line = runtime_line(remaining)
        try:
            response = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(response, dict) or response.get("kind") != "bridge_response":
            continue
        if response.get("request_id") != request_id:
            continue
        if _task_generation_id is not None and response.get("task_generation_id") != _task_generation_id:
            continue
        return response


def bridge_call(method: str, display_id: int, **params: Any) -> dict[str, Any]:
    global _bridge_observation_revision
    timeout = params.pop("_reply_timeout", None)
    if method == "observe":
        params.setdefault("observation_keywords", _observation_keywords)
    if method == "act":
        if _bridge_observation_revision:
            params.setdefault("observation_revision", _bridge_observation_revision)
        # A UUID represents this logical execution, not a hash of its payload.
        # Repairs and model selection happen before it can be allocated.
        if "action_id" not in params:
            params["action_id"] = str(uuid.uuid4()).lower()
        elif isinstance(params["action_id"], str):
            params["action_id"] = params["action_id"].lower()
        timeout = 30.0
        if params.get("action", {}).get("type") == "run_command":
            timeout += float(params["action"].get("timeout_seconds", action_default("run_command", "timeout_seconds")))
    try:
        response = bridge_exchange(method, display_id, params, timeout)
        if method == "act":
            receipt = response.get("action_receipt")
            if receipt is not None:
                if (not isinstance(receipt, dict) or receipt.get("action_id") != params["action_id"] or
                        type(receipt.get("terminal")) is not bool):
                    raise BridgeReplyLost("The native action reply has an invalid receipt")
                if not receipt["terminal"]:
                    raise BridgeReplyLost("The native action is still pending")
                state = receipt.get("state")
                if state not in {"confirmed", "unconfirmed", "rejected"}:
                    raise BridgeReplyLost("The native action receipt has an invalid state")
                if response.get("ok"):
                    result = response.get("result")
                    if (not isinstance(result, dict) or state == "rejected" or
                            (result.get("outcome") == "delivered_unconfirmed") != (state == "unconfirmed")):
                        raise BridgeReplyLost("The native action reply and receipt disagree")
                elif state == "confirmed":
                    raise BridgeReplyLost("The native action reply and receipt disagree")
            elif response.get("ok"):
                raise BridgeReplyLost("The native action reply lacks its receipt")
    except BridgeReplyLost as error:
        if method != "act": raise
        if not error.connected:
            _receipt_metrics["receipt_unresolved"] += 1
            raise
        response = reconcile_receipt(params["action_id"],
            lambda action_id, remaining: bridge_call("action_receipt", display_id,
                action_id=action_id, _reply_timeout=remaining), _receipt_metrics,
            clock=time.monotonic, sleep=time.sleep)
    if not response.get("ok"):
        raise ActionRejected(str(response.get("error") or f"{PRODUCT_NAME} rejected the request"),
                             str(response.get("error_code") or "action_rejected"))
    result = response.get("result")
    if isinstance(result, dict):
        if method == "observe" and isinstance(result, dict):
            if _task_generation_id is not None and result.get("task_generation_id") != _task_generation_id:
                raise ActionRejected("Observation belongs to another task", "cancelled")
            result = dict(result)
            result.pop("task_generation_id", None)
            try:
                validate_observation_mapping(result, required=_task_generation_id is not None)
                validate_completeness(result, required=_task_generation_id is not None)
                validate_text_recognition(result, required=_task_generation_id is not None)
            except (CoordinateMappingError, ObservationCompletenessError, TextRecognitionError) as error:
                _bridge_observation_revision = None
                discard_observation_image(result)
                raise ActionRejected(str(error), "observation_unstable") from error
            _bridge_observation_revision = result.get("observation_revision")
        return result
    return {}


def find_openclaw(explicit_path: str | None = None) -> str:
    candidates = [
        explicit_path,
        os.environ.get("ORBIT_OPENCLAW_PATH"),
        shutil.which("openclaw"),
        "/opt/homebrew/bin/openclaw",
        "/usr/local/bin/openclaw",
        str(Path.home() / ".openclaw" / "bin" / "openclaw"),
        str(Path.home() / ".local" / "bin" / "openclaw"),
        str(Path.home() / ".npm-global" / "bin" / "openclaw"),
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.realpath(candidate)
    raise RuntimeError(
        f"OpenClaw is not installed. Open {PRODUCT_NAME} Settings, install OpenClaw, run "
        "`openclaw setup`, then click Recheck."
    )


def default_openclaw_key_state_path() -> Path:
    override = os.environ.get("ORBIT_OPENCLAW_KEY_STATE")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / LEGACY_APPLICATION_SUPPORT_FOLDER / "openclaw-key-state.json"


def sync_openclaw_google_key(
    openclaw_path: str,
    api_key: str,
    state_path: Path | None = None,
) -> None:
    """Keep OpenClaw's google:orbit profile aligned with TaskPilot's saved key.

    The secret crosses only a private stdin pipe. The persisted comparison is
    a one-way digest, so TaskPilot can avoid restarting the Gateway on every task.
    """
    key = api_key.strip()
    if len(key) < 20:
        raise RuntimeError(
            f"Add and save a complete Gemini API key in {PRODUCT_NAME} Settings before running a task."
        )
    destination = state_path or default_openclaw_key_state_path()
    fingerprint = hashlib.sha256(key.encode("utf-8")).hexdigest()
    try:
        current = json.loads(destination.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        current = {}
    if isinstance(current, dict) and current.get("fingerprint") == fingerprint:
        return

    environment = dict(os.environ)
    environment["OPENCLAW_HIDE_BANNER"] = "1"
    environment["OPENCLAW_SUPPRESS_NOTES"] = "1"
    try:
        saved = subprocess.run(
            [
                openclaw_path, "models", "auth", "paste-api-key",
                "--provider", "google", "--profile-id", "google:orbit",
            ],
            input=key + "\n",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
            check=False,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(
            f"{PRODUCT_NAME} could not synchronize the saved Gemini API key with OpenClaw. "
            "Open Settings and click Reconfigure Gemini."
        ) from error
    finally:
        key = ""
    if saved.returncode != 0:
        raise RuntimeError(
            "OpenClaw rejected the saved Gemini API key. Open Settings and click Reconfigure Gemini."
        )

    # The Gateway keeps provider credentials in memory. Restart only after the
    # saved key changes, before ACP connects, so the next turn cannot use a
    # stale credential from an earlier TaskPilot setup.
    restarted = subprocess.run(
        [openclaw_path, "gateway", "restart"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=30,
        check=False,
        env=environment,
    )
    if restarted.returncode != 0:
        raise RuntimeError(
            f"{PRODUCT_NAME} saved the Gemini key, but OpenClaw could not reload it. "
            "Open Settings and click Reconfigure Gemini."
        )
    healthy = False
    for _attempt in range(12):
        health = subprocess.run(
            [openclaw_path, "health", "--json"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=8,
            check=False,
            env=environment,
        )
        if health.returncode == 0:
            healthy = True
            break
        time.sleep(0.5)
    if not healthy:
        raise RuntimeError(
            "OpenClaw did not become ready after reloading the Gemini key. "
            "Open Settings and click Reconfigure Gemini."
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps({"version": 1, "fingerprint": fingerprint}, separators=(",", ":")),
            encoding="utf-8",
        )
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def session_transcript_cursor(session_id: str, sessions_root: Path | None = None) -> tuple[Path, int] | None:
    root = sessions_root or Path.home() / ".openclaw/agents/main/sessions"
    try:
        registry = json.loads((root / "sessions.json").read_text())
        for name, value in registry.items():
            if name.endswith(f":{session_id}") and isinstance(value, dict):
                path = Path(value.get("sessionFile", "")).expanduser().resolve()
                if path.is_relative_to(root.resolve()) and path.is_file():
                    return path, path.stat().st_size
    except (OSError, ValueError, AttributeError):
        pass
    return None


def openclaw_session_error(session_id: str, sessions_root: Path | None = None,
                           after_cursor: tuple[Path, int] | None = None, *,
                           structured: bool = False, started_at: float | None = None) -> Any:
    """Recover provider failures that the current ACP bridge does not stream.

    OpenClaw records some Google capacity failures as a normal assistant
    message (for example, "temporarily overloaded") with stopReason=stop.
    ACP currently completes those turns without streaming the message body, so
    inspect the newest assistant record as well as explicit error records.
    """
    root = sessions_root or Path.home() / ".openclaw" / "agents" / "main" / "sessions"
    try:
        registry = json.loads((root / "sessions.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    if not isinstance(registry, dict):
        return ""
    entry: dict[str, Any] | None = None
    for key, value in registry.items():
        if isinstance(key, str) and key.endswith(f":{session_id}") and isinstance(value, dict):
            entry = value
            break
    if entry is None:
        return ""
    raw_session_file = entry.get("sessionFile")
    if not isinstance(raw_session_file, str) or not raw_session_file:
        return ""
    try:
        resolved_root = root.resolve()
        session_file = Path(raw_session_file).expanduser().resolve()
        if not session_file.is_relative_to(resolved_root):
            return ""
        with session_file.open("rb") as handle:
            size = handle.seek(0, os.SEEK_END)
            offset = after_cursor[1] if after_cursor and after_cursor[0] == session_file else 0
            handle.seek(max(offset, size - 262_144, 0), os.SEEK_SET)
            tail = handle.read().decode("utf-8", errors="ignore")
    except OSError:
        return ""
    for raw_line in reversed(tail.splitlines()):
        try:
            item = json.loads(raw_line)
        except json.JSONDecodeError:
            continue
        message = item.get("message") if isinstance(item, dict) else None
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        if started_at is not None and after_cursor is None and not current_transcript_message(message, item, started_at):
            return ""
        if message.get("stopReason") == "error":
            detail = message.get("errorMessage") or message.get("error")
            return message if structured else message_text(detail, "").strip()[:500]
        content = message.get("content")
        parts = content if isinstance(content, list) else [content]
        assistant_text = " ".join(
            str(part.get("text") or "").strip()
            for part in parts
            if isinstance(part, dict) and isinstance(part.get("text"), str)
        ).strip()
        lowered = assistant_text.lower()
        credential_failure = any(marker in lowered for marker in (
            "api key not valid", "invalid api key", "invalid credential",
            "permission denied", "forbidden", "unauthorized",
        ))
        if assistant_text and (is_model_capacity_failure(assistant_text) or credential_failure):
            return assistant_text if structured else assistant_text[:500]
        # Do not walk into an older turn and accidentally report a stale error.
        return ""
    return ""


def current_transcript_message(message: dict[str, Any], item: dict[str, Any], started_at: float) -> bool:
    stamp = message.get("timestamp") or item.get("timestamp")
    if isinstance(stamp, str):
        try: stamp = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() * 1000
        except (ValueError, OverflowError): return False
    return type(stamp) in {int, float} and stamp >= started_at


def user_facing_openclaw_error(detail: str) -> str:
    cleaned = " ".join(detail.split()).strip()
    lowered = cleaned.lower()
    if "api key not valid" in lowered or "invalid api key" in lowered or "invalid credential" in lowered:
        return (
            "Gemini rejected the saved API key. Open Settings → Gemini API key, enter the current key, "
            "click Check, then click Reconfigure Gemini."
        )
    return cleaned[:400]


def normalized_action(value: Any) -> dict[str, Any]:
    return normalize_action(value)


def effective_decision_status(decision: dict[str, Any]) -> str:
    """Recover models that label an otherwise valid next action as blocked."""
    status = str(decision.get("status") or "")
    action = decision.get("action")
    if status == "blocked" and isinstance(action, dict):
        action_type = str(action.get("type") or "")
        if action_type in VALID_ACTIONS - {"none"}:
            return "act"
    return status


def action_identity(action: dict[str, Any], observation: dict[str, Any]) -> str:
    """Identify an action independently of per-observation element IDs."""
    identity = {k: v for k, v in action.items() if k not in {"element_id", "observation_revision"}}
    element = next((e for e in observation.get("elements", [])
                    if isinstance(e, dict) and action.get("element_id") and e.get("id") == action.get("element_id")), None)
    if element:
        identity["target"] = {k: element.get(k) for k in ("pid", "role", "title")}
        identity["target"]["structure"] = structural_identity(element, observation)
    return json.dumps(identity, sort_keys=True, separators=(",", ":"))


def action_may_mutate(action: dict[str, Any], observation: dict[str, Any]) -> bool:
    kind = action.get("type")
    if kind in {"type_text", "set_value", "write_file", "run_command"}:
        return True
    if kind == "key":
        key = str(action.get("key")).lower()
        modifiers = {str(m).lower() for m in action.get("modifiers", [])}
        if key in {"tab", "escape", "left", "right", "up", "down", "home", "end", "page_up", "page_down"}:
            return False
        return not (key in {"a", "c", "f", "l"} and modifiers in ({"command"}, {"cmd"}))
    if kind not in {"press", "click", "double_click"}:
        return False
    element = next((e for e in observation.get("elements", [])
                    if isinstance(e, dict) and action.get("element_id") and e.get("id") == action.get("element_id")), {})
    label = str(element.get("title") or "")
    # Treat unknown controls as mutations. Only explicit navigation affordances
    # may be repeated after verified nonexecution; labels alone cannot prove
    # that a button such as "Increment" or "Continue" is harmless.
    if element.get("role") == "AXMenuBarItem":
        return False
    return label.strip().casefold() not in {"back", "forward", "next page", "previous page"}



def action_target(action: dict[str, Any], observation: dict[str, Any]) -> dict[str, Any] | None:
    elements = [e for e in observation.get("elements", []) if isinstance(e, dict)]
    if action.get("element_id"):
        return next((e for e in elements if e.get("id") == action["element_id"]), None)
    pid = action.get("pid")
    if action.get("type") in {"type_text", "key"}:
        fields = [e for e in elements if e.get("pid") == pid and e.get("focused") is True
                  and e.get("role") in {"AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"}]
        return fields[0] if len(fields) == 1 else None
    if "x" not in action or "y" not in action:
        return None
    targets = coordinate_targets(action, observation)
    return targets[0] if targets else None


def action_target_pid(action: dict[str, Any], observation: dict[str, Any]) -> int | None:
    target = action_target(action, observation)
    return target.get("pid") if target else action.get("pid")


def observation_window_state(application: dict[str, Any]) -> list[dict[str, Any]]:
    """Stable window evidence, excluding scoped IDs and activation metadata."""
    windows = [{key: window[key] for key in ("title", "frame", "source") if key in window}
               for window in application.get("windows", []) if isinstance(window, dict)]
    return sorted(windows, key=lambda window: json.dumps(window, sort_keys=True))


def target_identity(target: dict[str, Any] | None, observation: dict[str, Any]) -> dict[str, Any] | None:
    # Role changes do not establish that a mutation is safe to send again.
    return {**{k: target.get(k) for k in ("pid", "title", "window_title")},
            "structure": structural_identity(target, observation)} if target else None


def action_failure_recovery(code: str) -> str:
    return {"stale_target": "observe_again", "disabled_target": "wait_or_choose_enabled",
            "focus_mismatch": "observe_and_refocus", "activation_failed": "observe_and_activate",
            "unsupported_action": "choose_supported_method", "ambiguous_target": "select_specific_control",
            "delivery_uncertain": "inspect_effect"}.get(code, "choose_different_action")


class ActionRecovery:
    """Task-local bounds and effect checks; never execute a replacement action."""
    def __init__(self) -> None:
        self.failures: dict[str, int] = {}
        self.uncertain: list[tuple[dict[str, Any], dict[str, Any]]] = []
        self.suppressed: set[str] = set()

    def failure_key(self, action: dict[str, Any], observation: dict[str, Any]) -> str:
        target = action_target(action, observation)
        pid = action_target_pid(action, observation)
        parameters = {k: v for k, v in action.items() if k not in {"element_id", "observation_revision"}
                      and not (target and k in {"pid", "x", "y"})}
        context = {"action": parameters,
                   "target": {k: v for k, v in (target or {}).items() if k not in {"id", "parent_id", "window_id"}},
                   "windows": sorted([w for a in observation.get("applications", [])
                                      if isinstance(a, dict) and a.get("pid") == pid
                                      for w in observation_window_state(a)], key=lambda w: json.dumps(w, sort_keys=True))}
        return json.dumps(context, sort_keys=True)

    def rejected(self, action: dict[str, Any], observation: dict[str, Any], code: str) -> None:
        key = self.failure_key(action, observation)
        self.failures[key] = self.failures.get(key, 0) + 1
        if code == "delivery_uncertain":
            self.unconfirmed(action, observation)

    def unconfirmed(self, action: dict[str, Any], observation: dict[str, Any]) -> None:
        if action_may_mutate(action, observation):
            self.uncertain.append((action.copy(), observation))

    def succeeded(self, action: dict[str, Any], observation: dict[str, Any]) -> None:
        self.failures.pop(self.failure_key(action, observation), None)

    def overlaps(self, previous: dict[str, Any], before: dict[str, Any],
                 action: dict[str, Any], observation: dict[str, Any]) -> bool:
        if previous.get("type") in TRUSTED_NATIVE_ACTIONS or action.get("type") in TRUSTED_NATIVE_ACTIONS:
            if previous.get("type") == action.get("type") == "run_command":
                def effect(value):
                    source = value.get("command")
                    argv = value.get("argv")
                    if argv is None and isinstance(source, str):
                        # Compare only literal single commands across representations.
                        # Expansion/control operators keep their exact shell identity.
                        if not any(c in source for c in "$`|;&<>*?(){}\\\n"):
                            try: argv = shlex.split(source)
                            except ValueError: pass
                    cwd = os.path.normpath(os.path.expanduser(value.get("working_directory") or "~"))
                    return (argv if argv is not None else source, cwd)
                return effect(previous) == effect(action)
            if previous.get("type") == action.get("type") == "write_file":
                return os.path.normpath(os.path.expanduser(previous["path"])) == os.path.normpath(os.path.expanduser(action["path"]))
            return action_identity(previous, before) == action_identity(action, observation)
        pid = action_target_pid(previous, before)
        if pid is None or pid != action_target_pid(action, observation):
            return False
        if any(a.get("type") in {"click", "double_click"} and not a.get("element_id") for a in (previous, action)):
            return True  # Screenshot-only coordinates cannot prove a different control.
        # Enter can submit a form whose button has a different label/role.
        if any(a.get("type") == "key" and str(a.get("key", "")).lower() in {"return", "enter"}
               for a in (previous, action)):
            return True
        old_target, new_target = action_target(previous, before), action_target(action, observation)
        if old_target and new_target and old_target.get("native_identity") \
                and old_target.get("native_identity") == new_target.get("native_identity"):
            return True  # A relabeled panel cannot authorize replay of the same live control.
        first, second = target_identity(old_target, before), target_identity(new_target, observation)
        return first is None or second is None or first == second

    def check(self, action: dict[str, Any], observation: dict[str, Any]) -> dict[str, Any] | None:
        if action_may_mutate(action, observation):
            for previous, before in self.uncertain:
                if not self.overlaps(previous, before, action, observation):
                    continue
                target = action_target(action, observation)
                # Only a complete, nonsecure field value proves a replacement
                # succeeded. A changed screenshot or unchanged screen does not.
                if previous.get("type") == action.get("type") == "set_value" \
                        and previous.get("text") == action.get("text") and target \
                        and target.get("value_complete") is True \
                        and "securetextfield" not in (str(target.get("role", "")) + str(target.get("subrole", ""))).lower() \
                        and target.get("value", "") == action["text"]:
                    return {"message": "The fresh field value matches the earlier replacement; no input was repeated",
                            "outcome": "verified", "delivery_method": "local_check", "verification_scope": "text_value",
                            "recovery": "effect_already_present"}
                key = "uncertain:" + str(action_target_pid(action, observation)) + ":" + action_identity(previous, before)
                if key in self.suppressed:
                    raise RuntimeError("The previous input may already have changed the app. TaskPilot stopped rather than repeat an uncertain mutation.")
                self.suppressed.add(key)
                return {"message": "Do not replay or switch delivery methods for this uncertain mutation. Inspect fresh evidence of its effect, use a read-only check, or report the unresolved result.",
                        "outcome": "suppressed", "recovery": "inspect_effect"}
        key = self.failure_key(action, observation)
        if self.failures.get(key, 0) >= 2:
            if key in self.suppressed:
                raise RuntimeError("TaskPilot stopped after the same rejected action was proposed again without a changed target or recovery method.")
            self.suppressed.add(key)
            return {"message": "This action already failed twice in the same target state. Choose a different valid method or report exhausted recovery; do not send it again.",
                    "outcome": "suppressed", "recovery": "choose_different_action"}
        return None


def blocked_recovery_action(task: str, observation: dict[str, Any], history: list[dict[str, Any]]) -> dict[str, Any] | None:
    named = task_capability_context(task, observation)["explicitly_named_apps"]
    installed = observation.get("installed_applications", [])
    visible = {str(a.get("name", "")).casefold() for a in observation.get("applications", []) if isinstance(a, dict)}
    for name in named:
        matching = [a for a in installed if isinstance(a, dict) and str(a.get("name", "")).casefold() == name.casefold()]
        attempted = any(isinstance(e.get("action"), dict) and e["action"].get("type") == "launch_app"
                        and str(e["action"].get("app", "")).casefold() == name.casefold() for e in history)
        if len(matching) == 1 and name.casefold() not in visible and not attempted:
            return {"type": "launch_app", "app": matching[0]["name"], "bundle_id": matching[0].get("bundle_id", "")}
    return None


def record_action_diagnostic(action: dict[str, Any], result: dict[str, Any]) -> None:
    """Private bounded diagnostics omit text, paths, commands and screen data."""
    try:
        folder = Path.home() / "Library/Application Support" / LEGACY_APPLICATION_SUPPORT_FOLDER
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / "automation-diagnostics.jsonl"
        if path.exists() and path.stat().st_size > 1_000_000:
            path.unlink()
        entry = {"timestamp": time.time(), "runtime_pid": os.getpid(), "action": action.get("type"),
                 **{k: result[k] for k in ("outcome", "delivery_method", "error_code", "verification_scope", "recovery") if k in result}}
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "a") as output:
            output.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def observation_progress_signature(observation: dict[str, Any], pid: int | None = None) -> str:
    """Ignore revision churn, foreground restoration and tree enumeration order."""
    apps = []
    for app in observation.get("applications", []):
        if not isinstance(app, dict) or (pid is not None and app.get("pid") != pid): continue
        row = {key: app[key] for key in ("pid", "name", "window_count") if key in app}
        if "windows" in app:
            # Scoped window IDs and foreground flags aid selection, but change
            # between observations/restoration without a meaningful screen change.
            row["windows"] = observation_window_state(app)
        apps.append(row)
    elements = [{key: element[key] for key in
                ("pid", "role", "subrole", "title", "window_title", "value", "value_complete", "focused", "selection_range", "enabled", "busy", "frame", "sort_direction")
                if key in element}
                for element in observation.get("elements", []) if isinstance(element, dict)
                and (pid is None or element.get("pid") == pid)]
    return json.dumps({"applications": sorted(apps, key=lambda item: json.dumps(item, sort_keys=True)),
                       "elements": sorted(elements, key=lambda item: json.dumps(item, sort_keys=True))}, sort_keys=True)


def observation_image_digest(observation: dict[str, Any]) -> str | None:
    path = Path(str(observation.get("screenshot_path") or ""))
    return hashlib.blake2b(path.read_bytes(), digest_size=16).hexdigest() if path.is_file() else None


def discard_observation_image(observation: dict[str, Any] | None) -> None:
    if observation:
        path = Path(str(observation.get("screenshot_path") or ""))
        if path.is_file():
            path.unlink(missing_ok=True)


def screen_wait_limit(action_type: str) -> float:
    if action_type in TRUSTED_NATIVE_ACTIONS or action_type == "none":
        return 0.0
    return 5.0 if action_type == "navigate_browser" else 3.0 if action_type in {"launch_app", "open_route"} else 2.0


def observation_is_loading(observation: dict[str, Any], pid: int | None) -> bool:
    return any(e.get("busy") is True or e.get("role") == "AXProgressIndicator"
               or str(e.get("title") or e.get("value") or "").strip().casefold()
               in {"loading", "loading…", "loading..."}
               for e in observation.get("elements", []) if isinstance(e, dict) and (pid is None or e.get("pid") == pid))


def wait_for_screen_change(display_id: int, before: dict[str, Any], action: dict[str, Any],
                           baseline_image: str | None = None, timeout: float | None = None,
                           target_pid: int | None = None,
                           expected_effect: ExpectedEffect | None = None) -> tuple[dict[str, Any], dict[str, Any]]:
    """Observe only; never replay an action or ask a model during settling.

    Retain the final screenshot and its revision for the next decision. A stable
    screen change is evidence to inspect, not proof of task/action completion.
    """
    pid = target_pid or action.get("pid")
    if pid is None and action.get("element_id"):
        pid = next((e.get("pid") for e in before.get("elements", [])
                    if isinstance(e, dict) and e.get("id") == action["element_id"]), None)
    baseline = observation_progress_signature(before, pid)
    baseline_image = baseline_image or observation_image_digest(before)
    limit = screen_wait_limit(str(action.get("type"))) if timeout is None else timeout
    start = time.monotonic()
    deadline = start + limit
    latest = None
    stable_signature = None
    stable_since = start
    changed = False
    polls = 0
    effect_result = expected_effect.unknown() if expected_effect else None
    try:
        while True:
            remaining = deadline - time.monotonic()
            if latest is not None and remaining <= 0:
                reason = "bounded_wait_elapsed"
                break
            # The native consistency loop shares this wait's remaining budget.
            # An unstable capture is not a provider failure or permission to use
            # an older revision (native observation authority was invalidated).
            current = bridge_call("observe", display_id,
                                  consistency_budget_ms=max(1, min(5000, math.ceil(remaining * 1000))))
            discard_observation_image(latest)
            latest = current
            polls += 1
            semantic = observation_progress_signature(current, pid)
            image = observation_image_digest(current)
            signature = (semantic, image)
            now = time.monotonic()
            changed = semantic != baseline or (baseline_image is not None and image is not None and image != baseline_image)
            elements = [e for e in current.get("elements", []) if isinstance(e, dict)
                        and (pid is None or e.get("pid") == pid)]
            loading = observation_is_loading(current, pid)
            if loading and timeout is None:
                deadline = max(deadline, start + 5.0)
            if signature != stable_signature or loading:
                stable_signature, stable_since = signature, now
            if expected_effect:
                effect_result = expected_effect.observe(current)
            confirmed_effect = effect_result and effect_result['outcome'] == 'verified'
            ready = confirmed_effect if expected_effect and expected_effect.supported else changed
            if ready and not loading and now - stable_since >= SCREEN_STABLE_SECONDS:
                # Describe locally observed readiness without guessing what a
                # free-form expected_result means or claiming a mutation worked.
                reason = "expected_effect_verified" if confirmed_effect else "screen_changed"
                old = [e for e in before.get("elements", []) if isinstance(e, dict)
                       and (pid is None or e.get("pid") == pid)]
                dialogs = {"AXSheet", "AXMenu", "AXDialog"}
                if not confirmed_effect and any(e.get("role") in dialogs or e.get("subrole") == "AXDialog" for e in elements) and not any(
                        e.get("role") in dialogs or e.get("subrole") == "AXDialog" for e in old):
                    reason = "dialog_opened"
                elif not confirmed_effect and any(e.get("focused") is True and e.get("enabled", True) is True
                         and e.get("role") in {"AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"}
                         for e in elements):
                    reason = "field_ready"
                break
            if now >= deadline:
                reason = "bounded_wait_elapsed"
                break
            time.sleep(min(SCREEN_POLL_SECONDS, deadline - now))
        return latest, {"reason": reason, "changed": changed, "polls": polls,
                        **({'expected_effect': effect_result} if effect_result else {}),
                        "elapsed_seconds": round(time.monotonic() - start, 3)}
    except BaseException:
        discard_observation_image(latest)
        raise


def command_outcome_verified(action: dict[str, Any], result: dict[str, Any]) -> bool:
    expected = action.get("checks")
    actual = result.get("checks")
    if (result.get("verified") is not True or result.get("verification_scope") != "requested_outcomes"
            or result.get("timed_out") is not False or type(result.get("exit_code")) is not int
            or result["exit_code"] != 0 or not isinstance(expected, list) or not expected
            or not isinstance(actual, list) or len(expected) != len(actual)):
        return False
    for check, evidence in zip(expected, actual):
        if not isinstance(check, dict) or not isinstance(evidence, dict) or evidence.get("verified") is not True:
            return False
        if check.get("type") != evidence.get("type"):
            return False
        if "path" in check and os.path.normpath(os.path.expanduser(check["path"])) != evidence.get("path"):
            return False
    return True


def verify_expected_effect(display_id: int, before: dict[str, Any], action: dict[str, Any],
                           result: dict[str, Any], expectation: Any, baseline_image: str | None,
                           metrics: dict[str, Any]) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    effect = ExpectedEffect(expectation, before)
    checked = effect.unknown()
    observation = None
    if effect.kind in FILE_EFFECTS:
        checked = effect.reuse_native(action, result)
        if not checked or checked['outcome'] != 'verified':
            def count(): metrics['effect_checks'] = metrics.get('effect_checks', 0) + 1
            checked = effect.wait_file(lambda check: bridge_call('check_effect', display_id, check=check), count=count)
    screen_limit = screen_wait_limit(str(action.get('type')))
    if screen_limit > 0 or effect.kind in {'dialog_appeared', 'field_value'}:
        observation, settling = wait_for_screen_change(display_id, before, action, baseline_image,
            target_pid=result.get('pid'), timeout=0 if effect.kind in FILE_EFFECTS else (2.0 if screen_limit == 0 else None),
            expected_effect=effect if effect.kind not in FILE_EFFECTS else None)
        result = {**result, 'settling': settling}
        if effect.kind not in FILE_EFFECTS:
            checked = settling.get('expected_effect') or checked
            if effect.supported: metrics['effect_checks'] = metrics.get('effect_checks', 0) + settling['polls']
    # A check's scope is separate from acknowledgement of event delivery.
    # Unrelated changes never turn a supported unmet expectation into success.
    outcome = checked['outcome']
    if effect.supported:
        result = {**result, 'delivery_outcome': result.get('outcome'),
                  'outcome': 'verified' if outcome == 'verified' else 'delivered_unconfirmed',
                  'verification_scope': 'expected_effect' if outcome == 'verified' else 'expected_effect_unconfirmed'}
    key = 'verified_effects' if outcome == 'verified' else 'unconfirmed_effects'
    metrics[key] = metrics.get(key, 0) + 1
    return observation, {**result, 'expected_effect': checked}


def trusted_native_history(
    task: str,
    observation: dict[str, Any],
    history: list[dict[str, Any]],
) -> bool:
    """Compatibility helper: history alone never establishes task coverage."""
    return False


def native_action_can_finish(
    task: str,
    decision: dict[str, Any],
    action: dict[str, Any],
    result: dict[str, Any],
    observation: dict[str, Any],
) -> bool:
    """A model's finish flag is a verification candidate, not proof."""
    return False


def secure_input_target(
    observation: dict[str, Any],
    history: list[dict[str, Any]],
) -> dict[str, Any] | None:
    """Find one empty visible secure field without exposing its future value."""
    handled = {
        str(entry.get("result", {}).get("target_signature") or "")
        for entry in history
        if isinstance(entry, dict) and isinstance(entry.get("result"), dict)
        and entry.get("action") == "user_input_entered"
    }
    elements = observation.get("elements")
    if not isinstance(elements, list):
        return None
    for element in elements:
        if not isinstance(element, dict):
            continue
        role = str(element.get("role") or "")
        subrole = str(element.get("subrole") or "")
        description = " ".join(str(element.get(key) or "") for key in (
            "title", "description", "placeholder"
        )).strip()
        is_secure = "securetextfield" in f"{role} {subrole}".casefold()
        sensitive_label = any(phrase in description.casefold() for phrase in (
            "password", "passcode", "verification code", "security code", "one-time code", "otp"
        ))
        if not is_secure and not (
            role == "AXTextField" and sensitive_label
        ):
            continue
        element_id = str(element.get("id") or "")
        try:
            pid = int(element.get("pid") or 0)
        except (TypeError, ValueError):
            pid = 0
        if not element_id or pid <= 0:
            continue
        raw_value = str(element.get("value") or "").strip()
        placeholder_value = raw_value.casefold() in {
            "password", "passcode", "verification code", "security code"
        }
        if raw_value and not placeholder_value:
            continue
        signature = f"{pid}|{description.casefold() or 'secure-field'}"
        if signature in handled:
            continue
        verification = any(word in description.casefold() for word in (
            "code", "otp", "verification"
        ))
        return {
            "element_id": element_id,
            "pid": pid,
            "input_kind": "verification_code" if verification else "password",
            "title": "Verification code required" if verification else "Password required",
            "message": description or (
                f"The waiting app needs a verification code before {PRODUCT_NAME} can continue."
                if verification else
                f"The waiting app needs a password that {PRODUCT_NAME} does not have."
            ),
            "target_signature": signature,
        }
    return None


def decision_user_input_target(decision: dict[str, Any]) -> dict[str, Any]:
    request = decision.get("user_input")
    action = decision.get("action")
    if not isinstance(request, dict) or not isinstance(action, dict):
        raise RuntimeError("OpenClaw requested user input without a target field")
    element_id = str(action.get("element_id") or "")
    try:
        pid = int(action.get("pid") or 0)
    except (TypeError, ValueError):
        pid = 0
    if not element_id or pid <= 0:
        raise RuntimeError("The password request requires a visible field id and app pid")
    input_kind = str(request.get("kind") or "password")
    if input_kind not in {"password", "verification_code", "secret"}:
        input_kind = "secret"
    return {
        "element_id": element_id,
        "pid": pid,
        "input_kind": input_kind,
        "title": str(request.get("title") or "Secure input required")[:120],
        "message": str(request.get("message") or "Enter the requested secure value to continue.")[:400],
        "target_signature": str(request.get("target_signature") or f"{pid}|{element_id}"),
    }


def wait_for_user_input(request_id: str) -> str:
    while True:
        line = runtime_line()
        try:
            response = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(response, dict) or response.get("kind") != "user_input_response":
            continue
        if response.get("request_id") != request_id:
            continue
        if _task_generation_id is not None and response.get("task_generation_id") != _task_generation_id:
            continue
        value = response.get("value")
        if not isinstance(value, str) or not value:
            raise RuntimeError(f"{PRODUCT_NAME} did not receive the requested secure value")
        if len(value) > 4096:
            raise RuntimeError("The secure value is unexpectedly long")
        return value


def request_and_enter_user_input(
    target: dict[str, Any],
    display_id: int,
) -> dict[str, Any]:
    request_id = str(uuid.uuid4())
    emit(
        "user_input_required",
        request_id=request_id,
        title=target["title"],
        message=target["message"],
        input_kind=target["input_kind"],
    )
    secret = wait_for_user_input(request_id)
    try:
        delivery = bridge_call(
            "act", display_id,
            action={"type": "type_text", "element_id": target["element_id"], "pid": target["pid"], "text": secret},
            private_input=True,
        )
    finally:
        secret = ""
    return {
        "message": f"{PRODUCT_NAME} delivered private input to the intended focused field; its value was not read back.",
        "outcome": delivery.get("outcome", "delivered_unconfirmed"),
        "target_signature": target["target_signature"],
        "input_kind": target["input_kind"],
        "secret_retained": False,
    }


def complete_from_decision(decision: dict[str, Any], fallback: str, ledger: TaskEvidenceLedger) -> None:
    message = decision["output"] if isinstance(decision.get("output"), str) else str(fallback or "Task completed")
    if not ledger.can_complete(message):
        raise RuntimeError("TaskPilot cannot complete without evidence for every requested requirement")
    title = str(decision.get("output_title") or "OpenClaw result").strip()
    kind = str(decision.get("output_kind") or "result")
    if kind not in {"answer", "result", "completion"}:
        kind = "result"
    emit(
        "output", show_output=True, title=title, content=message,
        decided_by_agent=True, output_kind=kind,
    )
    emit("complete", message=message)


def compact_observation(observation: dict[str, Any], task: str = "") -> dict[str, Any]:
    compact = {
        key: value for key, value in observation.items()
        if key not in {"screenshot_path", "agent_cursor", "installed_applications", "elements", "text_recognition"}
    }
    text = prompt_text_recognition(observation)
    if text is not None: compact['text_recognition'] = text
    installed = observation.get("installed_applications")
    if isinstance(installed, list):
        compact["installed_application_count"] = len(installed)
        # App discovery needs the full name/bundle inventory, but usage dates
        # and other metadata duplicate system_context and add thousands of
        # tokens to every visible desktop step.
        compact["installed_applications"] = [
            {
                key: app[key]
                for key in ("name", "bundle_id", "platform")
                if isinstance(app, dict) and key in app
            }
            for app in installed
            if isinstance(app, dict)
        ]
    elements = observation.get("elements")
    if isinstance(elements, list):
        compact["visible_element_count"] = len(elements)
        compact["elements"] = select_elements(observation, task, MAX_COMPACT_ELEMENTS)
        compact["observation_completeness"] = prompt_coverage(observation, compact["elements"], MAX_COMPACT_ELEMENTS)
        if elements: compact["target_relationships_version"] = RELATIONSHIPS_VERSION
        if len(elements) > len(compact["elements"]):
            compact["element_selection"] = {"strategy": "active_window_task_and_labels", "partial": True}
    return compact


def action_history_context(decision: dict[str, Any], action: dict[str, Any],
                           observation: dict[str, Any]) -> dict[str, Any]:
    context = {key: decision[key] for key in ("intended_target", "expected_result") if key in decision}
    element = next((e for e in observation.get("elements", [])
                    if isinstance(e, dict) and e.get("id") == action.get("element_id")), None)
    if element:
        context["target"] = {key: element[key] for key in ("app", "window_title", "title", "role", "subrole") if key in element}
    elif action.get("app") or action.get("bundle_id"):
        context["target"] = {key: action[key] for key in ("app", "bundle_id") if key in action}
    return context


def compact_history(history: list[dict[str, Any]]) -> list[dict[str, Any]]:
    recent = history[-MAX_RECENT_ACTIONS:]
    compact: list[dict[str, Any]] = []
    for offset, entry in enumerate(recent):
        if not isinstance(entry, dict):
            continue
        allowed = {
            "step", "action", "result", "completed_requirements", "remaining_requirements",
            "target", "intended_target", "expected_result"
        }
        # Only the two newest actions retain prose evidence; the current fresh
        # screenshot and Accessibility tree are the authoritative state.
        if offset >= max(0, len(recent) - 2):
            allowed.add("visual_evidence")
        row = {key: entry[key] for key in allowed if key in entry}
        if isinstance(row.get("action"), dict) and row["action"].get("operation"):
            # Recipes reconstruct these fields locally. In particular, native
            # source snapshots belong to the proof ledger, not model context.
            row["action"] = {k: v for k, v in row["action"].items() if k not in {"argv", "checks"}}
            if isinstance(row.get("result"), dict):
                row["result"] = {k: v for k, v in row["result"].items() if k != "outcome_checks"}
        compact.append(row)
    return compact


def task_capability_context(task: str, observation: dict[str, Any]) -> dict[str, Any]:
    """Map ordinary user wording to TaskPilot's concrete capabilities.

    This is advisory rather than an executor: the model still checks the live
    screen and action results, while stable routing rules keep simple requests
    from depending on a lucky interpretation of tool names.
    """
    lowered = " ".join(task.casefold().split())
    path_signal = bool(
        re.search(r"(?:^|\s)(?:~?/|/users/|\.{0,2}/)", lowered)
        or re.search(r"\b[\w -]+\.[a-z0-9]{1,10}\b", lowered)
        or any(re.search(rf"\b{re.escape(name)}\b", lowered) for name in STANDARD_LOCATIONS)
        or re.search(r"\b(file|folder|directory|path|document|download)\b", lowered)
    )
    file_read = path_signal and bool(re.search(
        r"\b(read|show|display|inspect|summari[sz]e|what(?:'s| is) in|what does|tell me (?:what|about)|contents?|open)\b",
        lowered,
    ))
    file_write = path_signal and bool(re.search(
        r"\b(create|make|write|save|append|add to|update|edit|overwrite|put|export)\b",
        lowered,
    ))
    shell = bool(
        re.search(r"\b(shell|terminal|command line|command|zsh|bash|script)\b", lowered)
        or re.search(
            r"\brun\s+(?:`|ls\b|pwd\b|git\b|npm\b|npx\b|pnpm\b|yarn\b|python\b|python3\b|swift\b|xcodebuild\b|make\b|cargo\b|go\b|ruby\b|node\b|find\b|grep\b|rg\b|curl\b)",
            lowered,
        )
    )
    shell = shell or (path_signal and any(re.search(recipe['intent_pattern'], lowered)
                                         for recipe in CONTRACT['command_operations'].values())) or bool(
        re.search(CONTRACT['command_operations']['print_text']['intent_pattern'], lowered))
    browser = bool(
        re.search(r"https?://|\b(browser|website|web page|webpage|internet|online|url|current tab|this page)\b", lowered)
        or re.search(r"\b(search|google|look up|browse)\b.*\b(web|online|internet|google|site)\b", lowered)
    )

    installed = observation.get("installed_applications")
    installed_apps = [
        str(item.get("name") or "").strip()
        for item in installed if isinstance(item, dict)
    ] if isinstance(installed, list) else []
    explicitly_named_apps = sorted({
        name for name in installed_apps
        if len(name) >= 3 and re.search(rf"\b{re.escape(name.casefold())}\b", lowered)
    })
    common_app_names = {
        "finder", "safari", "chrome", "notes", "mail", "calendar", "reminders",
        "contacts", "photos", "maps", "music", "calculator", "dictionary",
        "preview", "textedit", "messages", "slack", "teams", "zoom",
    }
    mentioned_common_apps = {
        name.title() for name in common_app_names
        if re.search(rf"\b{re.escape(name)}\b", lowered)
    }
    explicitly_named_apps = sorted(set(explicitly_named_apps) | mentioned_common_apps)

    applications = observation.get("applications")
    visible_apps = [
        str(item.get("name") or item.get("app") or "").strip()
        for item in applications if isinstance(item, dict)
    ] if isinstance(applications, list) else []
    visible_apps = [name for name in visible_apps if name]

    capabilities: list[str] = []
    if file_read:
        capabilities.append("file_read")
    if file_write:
        capabilities.append("file_write")
    if shell:
        capabilities.append("shell")
    if browser:
        capabilities.append("browser")
    if explicitly_named_apps or (browser and len(explicitly_named_apps) > 1):
        capabilities.append("app_automation")
    if not capabilities:
        capabilities.append("app_automation")

    mentioned_locations = {
        name: path for name, path in STANDARD_LOCATIONS.items()
        if re.search(rf"\b{re.escape(name)}\b", lowered)
    }
    examples = [json.dumps(action_example(kind), separators=(',', ':'))
                for kind, capability in ACTION_CAPABILITIES.items()
                if capability in capabilities and capability != "app_automation"]
    if "app_automation" in capabilities and len(explicitly_named_apps) >= 2:
        examples.append(
            "Example: 'Copy the total from Safari into Notes' -> read the visible Safari value, "
            "launch/focus Notes, enter that exact value, and verify Notes on a fresh screen."
        )

    return {
        "recommended_capabilities": capabilities,
        "home_directory": str(Path.home()),
        "mentioned_standard_locations": mentioned_locations,
        "explicitly_named_apps": explicitly_named_apps,
        "currently_visible_apps": visible_apps[:20],
        "context_rules": [
            "Resolve Desktop, Documents, and Downloads to the standard paths shown here; do not ask for an absolute path when the user already named one of them.",
            "Use read_file/write_file for direct file contents. Use run_command for an explicitly requested command or filesystem operation not covered by the file tools.",
            "Use navigate_browser for a URL or web search, then inspect and control the rendered page with Accessibility actions.",
            "For multi-app work, carry exact values forward in validated action history and verify the destination app before finishing.",
            "Words like 'this page', 'current tab', 'selected file', or 'that value' refer to the live observation and recent validated results; inspect them instead of guessing.",
            "If a filename is omitted but one visible/mentioned candidate clearly fits, inspect it. If multiple candidates fit, search or list them before choosing.",
        ],
        "relevant_examples": examples,
    }


def image_mime_type(path: Path) -> str:
    return "image/png" if path.suffix.lower() == ".png" else "image/jpeg"


def is_largest_downloads_file_task(task: str) -> bool:
    """Only a complete, supported request can take the native shortcut."""
    return re.fullmatch(LARGEST_PATTERN, task, re.I) is not None


def largest_top_level_file(directory: Path) -> dict[str, Any]:
    """Return an exact, non-recursive largest-file result for a user-named folder."""
    try:
        entries = list(os.scandir(directory))
    except OSError as error:
        raise RuntimeError(
            f"{PRODUCT_NAME} could not read {directory.name}. Check its macOS Files and Folders permission."
        ) from error
    largest: dict[str, Any] | None = None
    for entry in entries:
        try:
            if not entry.is_file(follow_symlinks=False):
                continue
            size = entry.stat(follow_symlinks=False).st_size
        except OSError:
            continue
        if largest is None or (size, entry.name.casefold()) > (
            int(largest["bytes"]), str(largest["name"]).casefold()
        ):
            largest = {"name": entry.name, "bytes": size}
    if largest is None:
        raise RuntimeError(f"No top-level files were found in {directory.name}.")
    return largest


def formatted_file_size(byte_count: int) -> str:
    units = ((1_000_000_000_000, "TB"), (1_000_000_000, "GB"),
             (1_000_000, "MB"), (1_000, "KB"))
    for threshold, suffix in units:
        if byte_count >= threshold:
            return f"{byte_count / threshold:.2f} {suffix}"
    return f"{byte_count} bytes"


def largest_downloads_guidance(task: str) -> str:
    if not is_largest_downloads_file_task(task):
        return ""
    return (
        "SPECIAL FINDER ACCURACY RULE: Answer this Downloads largest-file question only from a Finder "
        "window titled Downloads in list view. The Size column must visibly be sorted descending: a down "
        "sort arrow must be inside the Size column, not Date Added, Name, or another column. Clicking Size "
        "is not proof that sorting changed; inspect the next fresh observation. If the arrow is under another "
        "column or Size is ascending, click Size again. If a Size-header click does not move the arrow, use "
        "Finder's View > Sort By > Size menu, then recheck the arrow. If Downloads is not open yet, navigate "
        "there with Finder's visible sidebar (or launch Finder first); that is an act step, not a blocker. Skip "
        "Folder rows whose size is '--'. Only choose done "
        "when the first visible non-folder row after that proven descending sort shows both its filename and size."
    )


def _element_text(element: dict[str, Any]) -> str:
    for key in ("value", "title"):
        value = element.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def _frame_number(element: dict[str, Any], key: str) -> float | None:
    frame = element.get("frame")
    if not isinstance(frame, dict):
        return None
    value = frame.get(key)
    return float(value) if isinstance(value, (int, float)) else None


def _downloads_window_elements(observation: dict[str, Any]) -> list[dict[str, Any]]:
    elements = observation.get("elements")
    if not isinstance(elements, list):
        return []
    candidates = [element for element in elements if isinstance(element, dict)]
    for index, element in enumerate(candidates):
        if element.get("role") != "AXWindow" or _element_text(element).casefold() != "downloads":
            continue
        window_depth = element.get("depth")
        if not isinstance(window_depth, int):
            window_depth = 1
        end = len(candidates)
        for next_index in range(index + 1, len(candidates)):
            next_element = candidates[next_index]
            next_depth = next_element.get("depth")
            if next_element.get("role") == "AXWindow" and isinstance(next_depth, int) and next_depth <= window_depth:
                end = next_index
                break
        return candidates[index:end]
    return []


def _finder_size_sort_direction(elements: list[dict[str, Any]]) -> str:
    """Return descending/ascending/other from Finder's visible column geometry."""
    headers: dict[str, dict[str, Any]] = {}
    for element in elements:
        text = _element_text(element).casefold()
        if text in {"name", "size", "kind", "date added", "date modified"}:
            headers.setdefault(text, element)
    size_header = headers.get("size")
    if size_header is None:
        return "unavailable"

    explicit_direction = str(size_header.get("sort_direction") or "").casefold()
    if "descending" in explicit_direction:
        return "descending"
    if "ascending" in explicit_direction:
        return "ascending"

    size_x = _frame_number(size_header, "x")
    if size_x is None:
        return "unavailable"
    right_edges = [
        x for name, header in headers.items()
        if name != "size" and (x := _frame_number(header, "x")) is not None and x > size_x
    ]
    size_right = min(right_edges) if right_edges else size_x + 160
    size_y = _frame_number(size_header, "y")
    for element in elements:
        if element.get("role") != "AXImage":
            continue
        title = _element_text(element).casefold()
        if title not in {"go down", "go up", "descending", "ascending"}:
            continue
        indicator_x = _frame_number(element, "x")
        indicator_y = _frame_number(element, "y")
        if indicator_x is None or not size_x <= indicator_x < size_right:
            continue
        if size_y is not None and indicator_y is not None and abs(indicator_y - size_y) > 24:
            continue
        return "descending" if title in {"go down", "descending"} else "ascending"
    return "other"


_VISIBLE_FILE_SIZE = re.compile(r"^\s*[\d,.]+\s*(?:bytes?|[kmgt]b)\s*$", re.IGNORECASE)


def visible_largest_downloads_file(observation: dict[str, Any]) -> dict[str, str] | None:
    """Extract a largest file only after Finder visibly proves descending Size order."""
    elements = _downloads_window_elements(observation)
    if not elements or _finder_size_sort_direction(elements) != "descending":
        return None

    for index, element in enumerate(elements):
        if element.get("role") != "AXRow":
            continue
        row_depth = element.get("depth")
        if not isinstance(row_depth, int):
            continue
        end = len(elements)
        for next_index in range(index + 1, len(elements)):
            next_element = elements[next_index]
            next_depth = next_element.get("depth")
            if next_element.get("role") == "AXRow" and isinstance(next_depth, int) and next_depth <= row_depth:
                end = next_index
                break
        children = elements[index + 1:end]
        filename = next(
            (
                _element_text(child) for child in children
                if child.get("role") == "AXTextField" and _element_text(child)
            ),
            "",
        )
        values = [_element_text(child) for child in children if child.get("role") == "AXStaticText"]
        if not filename or any(value.casefold() == "folder" for value in values):
            continue
        size = next((value for value in values if _VISIBLE_FILE_SIZE.fullmatch(value)), "")
        if size:
            return {"name": filename, "size": size}
    return None


def largest_downloads_next_action(
    observation: dict[str, Any],
    history: list[dict[str, Any]],
) -> dict[str, Any] | None:
    """Return the next visible Finder action for the accuracy-critical workflow."""
    window_elements = _downloads_window_elements(observation)
    if not window_elements:
        elements = observation.get("elements")
        if not isinstance(elements, list):
            return None
        for element in elements:
            if not isinstance(element, dict) or element.get("app") != "Finder":
                continue
            if _element_text(element).casefold() != "downloads" or not element.get("id"):
                continue
            return {"type": "press", "element_id": str(element["id"])}
        return None

    sort_state = _finder_size_sort_direction(window_elements)
    if sort_state == "descending":
        return None
    size_header = next(
        (
            element for element in window_elements
            if _element_text(element).casefold() == "size" and element.get("id")
        ),
        None,
    )
    if size_header is None:
        return None
    if sort_state == "ascending":
        return {"type": "press", "element_id": str(size_header["id"])}

    prior_sort_attempts = sum(
        1 for entry in history
        if isinstance(entry, dict) and entry.get("accuracy_action") == "sort_downloads_by_size"
    )
    if prior_sort_attempts >= 1:
        pid = size_header.get("pid")
        if isinstance(pid, int) and pid > 0:
            # Finder's built-in Sort by Size shortcut avoids repeatedly
            # clicking a text-only column header that rejected AXPress.
            return {
                "type": "key",
                "key": "6",
                "modifiers": ["control", "command"],
                "pid": pid,
            }
    return {"type": "press", "element_id": str(size_header["id"])}


class ACPClient:
    def __init__(self, openclaw_path: str) -> None:
        global _active_acp_process
        environment = dict(os.environ)
        environment["OPENCLAW_HIDE_BANNER"] = "1"
        environment["OPENCLAW_SUPPRESS_NOTES"] = "1"
        # Disable silence-based retries: wait for the called model to finish.
        environment["OPENCLAW_GOOGLE_GEMINI_FIRST_RESPONSE_RETRY_MS"] = "0"
        self.process = subprocess.Popen(
            [openclaw_path, "acp", "--no-prefix-cwd"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=environment,
        )
        _active_acp_process = self.process
        self.messages: queue.Queue[dict[str, Any]] = queue.Queue()
        self.stderr_tail: deque[str] = deque(maxlen=12)
        self.next_request_id = 1
        self.accepting_prompt_updates = False
        self.agent_chunks: list[str] = []
        self.turn_errors: list[Any] = []
        self.openclaw_path = openclaw_path
        self.selected_model: str | None = None
        self.stdout_finished = threading.Event()
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        try:
            initialized = self.request(
                "initialize",
                {
                    "protocolVersion": 1,
                    "clientCapabilities": {
                        "fs": {"readTextFile": False, "writeTextFile": False},
                        "terminal": False,
                    },
                    "clientInfo": {"name": PRODUCT_NAME, "version": "2.0"},
                },
                timeout=30,
            )
            protocol_version = initialized.get("protocolVersion")
            if protocol_version not in (1, "1"):
                raise RuntimeError(f"OpenClaw negotiated an unsupported ACP version: {protocol_version}")
            self.session_key = f"agent:main:taskpilot:{uuid.uuid4()}"
            session = self.request(
                "session/new",
                {
                    "cwd": str(Path.home()),
                    "mcpServers": [],
                    "_meta": {"sessionKey": self.session_key},
                },
                timeout=30,
            )
            session_id = session.get("sessionId")
            if not isinstance(session_id, str) or not session_id:
                raise RuntimeError(f"OpenClaw ACP did not create a {PRODUCT_NAME} session")
            self.session_id = session_id
            self.config_options = session.get("configOptions") or []
            thought = next((o for o in self.config_options if o.get("category") == "thought_level" or o.get("id") == "thought_level"), None)
            if thought and any(o.get("value") == "off" for o in thought.get("options", [])):
                result = self.request("session/set_config_option", {"sessionId": self.session_id, "configId": thought["id"], "value": "off"}, timeout=30)
                options = result.get("configOptions") or []
                if not any(o.get("id") == thought["id"] and o.get("currentValue") == "off" for o in options):
                    raise RuntimeError("OpenClaw did not acknowledge the thinking setting")
                self.config_options = options
            self.prompt_calls = 0
            self.successful_provider_retries: int | None = None
            self.model_switches = 0
            self.reconnects = 0
            self.openclaw_path = openclaw_path
        except Exception:
            self.close()
            raise


    def _read_stdout(self) -> None:
        try:
            assert self.process.stdout is not None
            for line in self.process.stdout:
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(message, dict):
                    self.messages.put(message)
        finally:
            self.stdout_finished.set()

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            cleaned = line.strip()
            if cleaned:
                self.stderr_tail.append(cleaned)

    def _send(self, message: dict[str, Any]) -> None:
        if self.process.poll() is not None:
            detail = self.stderr_tail[-1] if self.stderr_tail else "Process ended"
            raise RuntimeError(f"OpenClaw ACP stopped: {detail}")
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def _handle_server_message(self, message: dict[str, Any]) -> None:
        method = message.get("method")
        if method == "session/update":
            params = message.get("params") or {}
            if params.get("sessionId") and params["sessionId"] != getattr(self, "session_id", params["sessionId"]):
                return
            request_id = params.get("requestId")
            if request_id is not None and request_id != getattr(self, "pending_prompt_request_id", request_id):
                return
            update = params.get("update") or {}
            update_kind = update.get("sessionUpdate")
            if update_kind in {"agent_message_chunk", "agent_message", "message", "error", "session_error", "agent_error"} and not getattr(self, "accepting_prompt_updates", True):
                return
            content = update.get("content") or {}
            if update_kind in {"agent_message_chunk", "agent_message", "message"}:
                contents = content if isinstance(content, list) else [content]
                for part in contents:
                    if isinstance(part, dict):
                        text = part.get("text")
                        if isinstance(text, str):
                            if update_kind == "agent_message_chunk":
                                self.agent_chunks.append(text)
                            else:
                                self.agent_chunks = [text]
            elif update_kind in {"error", "session_error", "agent_error"}:
                if update.get("message") or update.get("error") or update.get("code"):
                    self.turn_errors.append(update)
            elif update_kind == "tool_call":
                title = update.get("title") or "OpenClaw tool"
                emit("status", message=f"OpenClaw is checking {title}…")
            return

        if "id" in message and isinstance(method, str):
            # TaskPilot does not grant OpenClaw a hidden mutation path. The only
            # action route is the visible, validated JSON decision below.
            if method == "session/request_permission":
                self._send({
                    "jsonrpc": "2.0",
                    "id": message["id"],
                    "result": {"outcome": {"outcome": "cancelled"}},
                })
            else:
                self._send({
                    "jsonrpc": "2.0",
                    "id": message["id"],
                    "error": {"code": -32601, "message": f"{PRODUCT_NAME} does not expose that client method"},
                })

    def request(self, method: str, params: dict[str, Any], timeout: float | None) -> dict[str, Any]:
        request_id = self.next_request_id
        self.next_request_id += 1
        if method == "session/prompt":
            self.pending_prompt_request_id = request_id
        self._send({
            "jsonrpc": "2.0", "id": request_id, "method": method, "params": params,
        })
        deadline = None if timeout is None else time.monotonic() + timeout
        while deadline is None or time.monotonic() < deadline:
            if self.process.poll() is not None and self.messages.empty() and (not hasattr(self, "stdout_finished") or self.stdout_finished.is_set()):
                detail = self.stderr_tail[-1] if self.stderr_tail else "Process ended"
                raise RuntimeError(f"OpenClaw ACP exited: {detail}")
            try:
                message = self.messages.get(
                    timeout=0.25 if deadline is None else min(0.25, max(0.01, deadline - time.monotonic()))
                )
            except queue.Empty:
                continue
            if message.get("id") == request_id and ("result" in message or "error" in message):
                if "error" in message:
                    error = message.get("error") or {}
                    raise ProviderRequestError(error, getattr(self, "selected_model", None), "OpenClaw ACP request failed")
                result = message.get("result")
                return result if isinstance(result, dict) else {}
            self._handle_server_message(message)
        raise RuntimeError(f"OpenClaw timed out while handling {method}")

    def _run_prompt(self, prompt: list[dict[str, Any]], timeout: float | None) -> tuple[dict[str, Any], str]:
        # ACP notifications carry session identity; request responses carry the
        # JSON-RPC request id. Drain earlier-turn updates before admitting a
        # new prompt, and only collect output while its response is pending.
        self.accepting_prompt_updates = False
        while not self.messages.empty():
            self._handle_server_message(self.messages.get_nowait())
        self.agent_chunks = []
        self.turn_errors = []
        self.accepting_prompt_updates = True
        started_at = time.time() * 1000
        cursor = session_transcript_cursor(self.session_id)
        try:
            result = self.request(
                "session/prompt",
                {
                    "sessionId": self.session_id,
                    "prompt": prompt,
                },
                timeout=timeout,
            )
        finally:
            self.accepting_prompt_updates = False
        stop_reason = str(result.get("stopReason") or "")
        selected = getattr(self, "selected_model", None)
        if stop_reason in {"cancelled", "error"}:
            if stop_reason == "cancelled":
                raise RuntimeError(f"OpenClaw cancelled the {PRODUCT_NAME} turn")
            detail = result if any(result.get(k) for k in ("error", "code", "data", "errorMessage", "errorDetails")) else self.turn_errors[-1] if self.turn_errors else openclaw_session_error(
                self.session_id, after_cursor=cursor, structured=True, started_at=started_at)
            if detail:
                raise ProviderRequestError(detail, selected)
            raise RuntimeError(
                "OpenClaw could not complete the Gemini request. Open Settings and click Reconfigure Gemini."
            )
        response = "".join(self.agent_chunks).strip()
        if not response and hasattr(self, "session_key"):
            recovered = self.gateway_configuration("sessions.get", {"key": self.session_key, "limit": 8})
            for item in reversed(recovered.get("messages") or []):
                message = item.get("message", item) if isinstance(item, dict) else {}
                if not current_transcript_message(message, item, started_at) or message.get("role") != "assistant":
                    continue
                if message.get("stopReason") == "error":
                    raise ProviderRequestError(message, selected, "OpenClaw recovery exhausted")
                content = message.get("content") or []
                if isinstance(content, list):
                    response = "".join(str(part.get("text") or "") for part in content if isinstance(part, dict)).strip()
                break
        if not response:
            response = str(result.get("message") or result.get("text") or "").strip()
        if not response:
            detail = self.turn_errors[-1] if self.turn_errors else openclaw_session_error(
                self.session_id, after_cursor=cursor, structured=True, started_at=started_at)
            if detail:
                raise ProviderRequestError(detail, selected)
        elif self.turn_errors:
            # A complete response can follow successful internal recovery. Partial
            # output plus an explicit provider error must not trigger format repair.
            try: extract_json_object(response)
            except ResponseValidationError:
                raise ProviderRequestError(self.turn_errors[-1], selected)
        return result, response

    def select_model(self, model: str) -> None:
        if model == self.selected_model:
            return
        option = next((o for o in self.config_options if o.get("category") == "model" or "model" in str(o.get("id", "")).lower()), None)
        if option is None:
            # OpenClaw 2026.9.5 bridge mode advertises thinking controls but no
            # model control. Use the acknowledged session configuration RPC
            # backing ACP controls; never send a prompt-based slash command.
            result = self.gateway_configuration("sessions.patch", {"key": self.session_key, "model": model})
            resolved = result.get("resolved") or {}
            accepted = f"{resolved.get('modelProvider', '')}/{resolved.get('model', '')}"
            if result.get("ok") is not True or accepted != model:
                raise RuntimeError(f"OpenClaw could not select {model}: session configuration was not acknowledged")
            self.selected_model = model
            self.model_switches += 1
            return
        result = self.request("session/set_config_option", {
            "sessionId": self.session_id, "configId": option["id"], "value": model,
        }, timeout=30)
        options = result.get("configOptions") or []
        acknowledged = next((o for o in options if o.get("id") == option["id"]), None)
        if acknowledged is None or acknowledged.get("currentValue") != model:
            raise RuntimeError(f"OpenClaw could not select {model}: model control was not acknowledged")
        self.config_options = options
        self.selected_model = model
        self.model_switches += 1

    def gateway_configuration(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        result = subprocess.run([self.openclaw_path, "gateway", "call", method, "--params", json.dumps(params), "--json"],
                                capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise ProviderRequestError(result.stdout.strip() or result.stderr.strip(), getattr(self, "selected_model", None), "OpenClaw session configuration failed")
        try:
            value = json.loads(result.stdout)
            if response_error(value):
                raise ProviderRequestError(value, getattr(self, "selected_model", None))
            return value
        except ValueError as error:
            raise RuntimeError("OpenClaw returned invalid session configuration") from error

    def reconnect(self) -> None:
        if self.reconnects >= 1:
            raise RuntimeError("OpenClaw disconnected again after reconnecting. Check Gateway health in Settings.")
        prompt_calls, switches = self.prompt_calls, self.model_switches
        provider_retries = getattr(self, "successful_provider_retries", None)
        path = self.openclaw_path
        session_key = self.session_key
        self.close()  # First stop and wait for the disconnected ACP child.
        # The Gateway owns inference independently of the stdio child. Its
        # abort RPC waits for terminal persistence before acknowledging.
        ended = self.gateway_configuration("sessions.abort", {"key": session_key})
        if ended.get("ok") is not True or ended.get("status") not in {"aborted", "no-active-run"}:
            raise RuntimeError("TaskPilot could not confirm the previous OpenClaw request ended. Repair the Gateway before retrying.")
        self.__init__(path)
        self.reconnects = 1
        self.prompt_calls = prompt_calls
        self.model_switches = switches
        self.successful_provider_retries = provider_retries

    def prompt(self, instruction: str, screenshot_path: Path, *, detail_images: list[dict] | None = None) -> str:
        self.prompt_calls = getattr(self, "prompt_calls", 0) + 1
        image_data = base64.b64encode(screenshot_path.read_bytes()).decode("ascii")
        mime_type = image_mime_type(screenshot_path)
        content = [
                {"type": "text", "text": instruction},
                {"type": "image", "data": image_data, "mimeType": mime_type},
            ]
        for index, crop in enumerate(detail_images or []):
            # Crops are already bounded/validated, from the accepted screenshot.
            # Standard ACP image blocks, in this same request and format repair.
            content.extend([{'type': 'text', 'text': f'Detail crop {index + 1}; use its image_to_global mapping in the observation.'},
                            {'type': 'image', 'data': crop['data'], 'mimeType': 'image/png'}])
        result, response = self._run_prompt(
            content,
            timeout=PROMPT_TIMEOUT_SECONDS,
        )
        # _run_prompt has reached a terminal result and already surfaced any
        # provider error. Empty terminal output belongs to format recovery.
        retries = provider_error_facts(result).get("provider_retries")
        self.last_prompt_provider_retries = retries
        if retries is not None:
            self.successful_provider_retries = (getattr(self, "successful_provider_retries", None) or 0) + retries
        return response

    def close(self) -> None:
        global _active_acp_process
        if self.process.poll() is None:
            try:
                self._send({
                    "jsonrpc": "2.0",
                    "method": "session/cancel",
                    "params": {"sessionId": getattr(self, "session_id", "")},
                })
            except Exception:
                pass
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                stream.close()
        if _active_acp_process is self.process:
            _active_acp_process = None


def prompt_capability_context(context: dict[str, Any]) -> dict[str, Any]:
    # Rules and examples belong in one prompt section, not duplicated here.
    return {key: value for key, value in context.items()
            if key not in {"context_rules", "relevant_examples"}}


def prompt_observation(observation: dict[str, Any], task: str = "") -> dict[str, Any]:
    compact = compact_observation(observation, task)
    compact.pop("agent_tools", None)
    return compact


def relevant_action_examples(context: dict[str, Any], observation: dict[str, Any],
                             history: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Illustrations only: never select or construct an action to execute."""
    capabilities = set(context["recommended_capabilities"])
    families = ACTION_CAPABILITIES
    recent = [entry.get("action") for entry in history[-3:] if isinstance(entry, dict)]
    capabilities.update(families[action["type"]] for action in recent
                        if isinstance(action, dict) and action.get("type") in families)
    examples = []
    if "file_read" in capabilities:
        examples.append(action_example("read_file"))
    if "file_write" in capabilities:
        examples.append(action_example("write_file"))
    if "shell" in capabilities:
        examples.append(action_example("run_command"))
    if "browser" in capabilities:
        examples.append(action_example("navigate_browser"))
    elements = [e for e in observation.get("elements", []) if isinstance(e, dict)]
    apps = observation.get("applications", [])
    desktop = bool(apps or elements or capabilities & {"app_automation", "browser"})
    if desktop:
        if elements:
            examples.append(action_example("press"))
        if any(e.get("role") in {"AXRow", "AXOutline", "AXTable"} for e in elements):
            examples.append(action_example("double_click"))
        fields = [e for e in elements if e.get("role") in {"AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"}]
        if fields:
            examples.append(action_example("set_value"))
            examples.append(action_example("type_text"))
        if apps and (not elements or any(app.get("accessibility_available") is False for app in apps if isinstance(app, dict))):
            examples.append(action_example("click"))
        if "browser" in capabilities or any(e.get("role") in {"AXScrollArea", "AXTable", "AXOutline"} for e in elements):
            examples.append(action_example("scroll"))
        visible = {str(app.get("name") or "").casefold() for app in apps if isinstance(app, dict)}
        if not apps or any(name.casefold() not in visible for name in context["explicitly_named_apps"]):
            examples.append(action_example("launch_app"))
        if observation.get("system_context", {}).get("task_routes"):
            examples.append(action_example("open_route"))
    examples.append(action_example("wait"))
    return examples


def desktop_instruction(
    task: str,
    observation: dict[str, Any],
    history: list[dict[str, Any]],
    ledger: TaskEvidenceLedger | None = None,
) -> str:
    context = task_capability_context(task, observation)
    examples = relevant_action_examples(context, observation, history)
    operation_kind = next((kind for kind, recipe in CONTRACT['command_operations'].items()
                           if re.search(recipe['intent_pattern'], task, re.I)), None)
    if operation_kind and ('shell' in context['recommended_capabilities'] or 'file_write' in context['recommended_capabilities']):
        template = operation_example(operation_kind)
        index = next((i for i, example in enumerate(examples) if example['type'] == 'run_command'), None)
        if index is None: examples.insert(0, template)
        else: examples[index] = template
        if not re.search(r'\b(?:write|append|overwrite|contents|containing)\b', task, re.I):
            examples = [example for example in examples if example['type'] != 'write_file']
    types = {example["type"] for example in examples}
    illustrated = [{"status": "act", "intended_target": "<target>",
                    "expected_result": "<effect>", "action": examples[0]}, *examples[1:]]
    first = examples[0]
    if first['type'] == 'write_file':
        illustrated[0]['expected_result'] = {'type': 'file_contents', 'path': first['path'], 'content': first['content']}
    elif first['type'] == 'press' and observation.get('applications'):
        illustrated[0]['expected_result'] = {'type': 'dialog_appeared', 'pid': 1, 'title': 'Example dialog'}
    for index, example in enumerate(examples[1:], 1):
        if example['type'] == 'set_value' and any(e.get('role') in {'AXTextField', 'AXTextArea', 'AXComboBox', 'AXSearchField'}
                and 'secure' not in str(e.get('subrole', '')).casefold() for e in observation.get('elements', [])):
            illustrated[index] = {'status': 'act', 'intended_target': '<field>', 'action': example,
                                  'expected_result': {'type': 'field_value', 'element_id': '<current field_id>', 'value': example['text']}}
    if ledger is not None and not ledger.requirements:
        first = examples[0]
        if first["type"] in {"read_file", "write_file"}:
            check = {"type": "file_read" if first["type"] == "read_file" else "file_contents",
                     **{key: first[key] for key in ("path", "content") if key in first}}
        elif first["type"] == "run_command":
            check = ({'type': 'command_operation', 'operation': first['operation']} if 'operation' in first else
                     {"type": "command_executed", **{key: first[key] for key in ("argv", "command") if key in first}})
        else:
            check = {"type": "visual", "expected": "<outcome>"}
        illustrated[0]["requirements"] = [{"source": "<quote>", "description": "<goal>", "check": check}]
    fields = [e for e in observation.get("elements", []) if isinstance(e, dict)
              and e.get("role") in {"AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"}]
    if fields and (any(e.get("role") == "AXSecureTextField" for e in fields) or
                   re.search(r"sign in|log ?in|password|verification code|secret", task, re.I)):
        illustrated.append({"status": "needs_user", "user_input": {"kind": "password"},
                            "action": {**action_example("focus"), "pid": 1}})
    recent = compact_history(history)
    condition = recovery_condition(history)
    if condition:
        # Classify against the complete owned result, then use the same safe
        # history projection as the evidence section (no native snapshots).
        condition = {**condition, "failed_action": recent[-1].get("action"), "result": recent[-1].get("result")}
    rules = decision_rules(bool(observation.get("elements")), condition,
                           bool(observation.get('text_recognition', {}).get('targets')))
    bounds = [PROMPT_BOUNDS["wait"]]
    if observation.get('elements'):
        bounds.append('Expected checks: dialog_appeared(pid,title[,window_title]); field_value(element_id,value[,pid]); '
                      'file_contents(path,content[,encoding]); file_exists/directory_exists/path_absent(path). Unknown checks remain unconfirmed.')
    if fields:
        bounds.append("set_value replaces a field; type_text inserts at its selection. Use the intended field ID and confirm focus before typing.")
    if types & {"press", "set_value", "double_click", "click", "scroll"}:
        bounds.append(PROMPT_BOUNDS["desktop"])
    for kind in ("read_file", "write_file", "run_command", "navigate_browser"):
        if kind in types:
            bounds.append(PROMPT_BOUNDS['command_operation' if kind == 'run_command' and operation_kind else kind])
    if types & {"read_file", "write_file"}:
        bounds.append("Paths: absolute or ~/.")
    if types & {"write_file", "run_command"}:
        bounds.append("finish_after_action:true requests completion verification after this native action.")
    if 'run_command' in types and operation_kind:
        bounds.append('operation types: ' + COMMAND_OPERATION_REFERENCE + '.')
    reference = ACTION_REFERENCE
    if not observation.get('applications') and not observation.get('elements'):
        reference = reference.split(' Keys:', 1)[0] + '\n'
    guidance = largest_downloads_guidance(task)
    progress = historical_progress(history, MAX_RECENT_ACTIONS, command_outcome_verified, task)
    return compile_prompt("recovery" if condition else "planning",
        instructions=rules + (checklist_instruction(ledger) if ledger else "") + (guidance + "\n" if guidance else ""),
        examples="Illustrations: replace IDs/PID 1. Do not copy example IDs, paths, commands or text.\n"
                 + "\n".join(json_data(example) for example in illustrated) + "\n" + " ".join(bounds) + "\n" + reference,
        task=task, context=prompt_capability_context(context), observation=prompt_observation(observation, task),
        history=recent, progress=progress, checklist=ledger.prompt_state() if ledger else None, condition=condition)


def verification_instruction(
    task: str,
    candidate: dict[str, Any],
    observation: dict[str, Any],
    history: list[dict[str, Any]],
    ledger: TaskEvidenceLedger | None = None,
) -> str:
    task_guidance = largest_downloads_guidance(task)
    progress = historical_progress(history, MAX_RECENT_ACTIONS, command_outcome_verified, task)
    examples = 'Examples illustrate shape, not evidence. Optional message/title are strings; kind is answer, result, or completion.\n'
    if not ledger:
        examples += 'Successful response example: {"verified":true,"message":"Verified result","kind":"completion"}.\n'
    examples += 'Unproven response example: {"verified":false,"missing":["Unproven requirement"]}.\n'
    if ledger:
        examples += ('Successful shape: {"verified":true,"coverage_complete":true,"message":"<exact requested result>",'
                     '"proofs":[{"requirement_id":"r1","evidence_ids":["e1"],"rationale":"<what the evidence proves>"}]}. '
                     'These IDs are illustrations; use supplied IDs.\n')
    return compile_prompt("completion",
        instructions=COMPLETION_RULES + (verification_checklist_instruction(ledger) if ledger else "")
                     + ("Vision labels/crops are provisional text, not proof of control role, enabled state, focus or successful execution.\n"
                        if observation.get('text_recognition', {}).get('targets') else "")
                     + (task_guidance + "\n" if task_guidance else ""), examples=examples,
        task=task, context=prompt_capability_context(task_capability_context(task, observation)),
        observation=prompt_observation(observation, task), history=compact_history(history), progress=progress,
        checklist=ledger.prompt_state() if ledger else None, candidate=candidate)


class ResponseRepairBudget:
    def __init__(self) -> None:
        self.used = False


def checklist_instruction(ledger: TaskEvidenceLedger) -> str:
    contract = (
        "\nCHECKLIST: First decision: list ALL requirements with task quotes. "
        "Checks: visual/answer(expected); file_read/file_exists/directory_exists/path_absent(path); "
        "file_contents(path,content[,encoding]); file_written(path,content[,encoding,mode]); stdout_equals(text); "
        "command_executed(argv or command[,working_directory]); command_operation(operation). "
        "file_contents: final; file_written: historical. "

    ) if not ledger.requirements else "\nCHECKLIST: Fulfill every requirement; pending/invalidated entries need evidence, not repeated uncertain mutations. "
    return contract


def verification_checklist_instruction(ledger: TaskEvidenceLedger) -> str:
    return (
        "\nAudit the checklist against the COMPLETE ORIGINAL TASK, including destinations, contents, constraints, "
        "ordering, and requested returned output. If anything was omitted, return verified:false and "
        "uncovered_requirements in the planning checklist shape. Cite proof for EACH requirement using runtime IDs. "
        "Native facts prove only their stated scope; "
        "a file existence check cannot prove contents, and delivery/focus cannot prove a save/send. "
        "Visual proof must cite the fresh observation; explain the visible outcome. An answer needs relevant "
        "evidence and its requested output, never an unsupported result. For file_read/stdout_equals include "
        "the full verified output verbatim OR output_evidence_ids to have TaskPilot return it exactly. "
        "Excerpts cannot substitute for full contents.\n"
    )


def verify_task_completion(task: str, candidate: dict[str, Any], display_id: int,
                           history: list[dict[str, Any]], router: TaskModelRouter,
                           client: ACPClient, ledger: TaskEvidenceLedger) -> bool:
    emit("status", message="Checking evidence for every requested requirement…")
    rechecks = ledger.recheck_actions()
    effect_checks = ledger.recheck_effects()
    ledger.invalidate(lambda e: e["mutable"])
    for action in rechecks:
        try:
            result = bridge_call("recheck", display_id, action=action)
        except ActionRejected as error:
            if error.code in {"cancelled", "permission_denied", "protected_target", "secure_input"}: raise
            # A failed readback leaves its requirements unproven. No mutation
            # or command is repeated to obtain proof.
            continue
        ledger.record_action(action, result, recheck=True)
    for check in effect_checks:
        effect = ExpectedEffect(check, {})
        checked = effect.wait_file(lambda value: bridge_call('check_effect', display_id, check=value), timeout=0)
        router.metrics['effect_checks'] = router.metrics.get('effect_checks', 0) + 1
        if checked['outcome'] == 'verified': ledger.record_effect(check, checked['evidence'])
    observation = bridge_call("observe", display_id)
    path = Path(str(observation.get("screenshot_path") or ""))
    try:
        if not path.is_file(): raise RuntimeError(f"{PRODUCT_NAME} could not capture the completion check")
        ledger.observe(observation)
        verification = routed_json_prompt(router, client,
            verification_instruction(task, candidate, observation, history, ledger), path,
            purpose="verification", observation=observation, ledger=ledger)
    finally:
        path.unlink(missing_ok=True)
    if not ledger.audit(verification):
        missing = verification.get("missing") or []
        missing += [r["description"] for r in ledger.requirements.values() if r["state"] != "proven"]
        history.append({"action": "completion_rejected", "result": missing or ["Whole-request coverage is not proven"]})
        emit("status", message="The evidence check found more work — continuing…")
        return False
    message = verification.get("message") or candidate.get("output") or "Task completed"
    for ref in verification.get("output_evidence_ids", []):
        fact = ledger.evidence[ref]["fact"]
        exact = (("[Binary file; base64 encoded]\n" if fact["encoding"] == "base64" else "") + fact["content"]
                 if fact["type"] == "file_read" else fact["text"])
        if exact not in message: message += "\n\n" + exact
    publish_task_metrics(router, client, ledger)
    complete_from_decision({"output": message, "output_title": verification.get("title") or candidate.get("output_title") or "OpenClaw result",
                            "output_kind": verification.get("kind") or candidate.get("output_kind") or "result"}, message, ledger)
    return True


def publish_task_metrics(router: TaskModelRouter, client: ACPClient, ledger: TaskEvidenceLedger) -> None:
    # Terminal events revoke the native lease. Publish aggregate diagnostics
    # before completion so the originating invocation can still accept them.
    router.metrics.update(evidence_checks=ledger.checks, coverage_rejections=ledger.rejections,
        requirements_proven=sum(r["state"] == "proven" for r in ledger.requirements.values()), **_receipt_metrics)
    router.metrics.update(prompt_calls=client.prompt_calls, model_switches=client.model_switches)
    emit("request_metrics", **router.metrics)


def validated_prompt(client: ACPClient, instruction: str, screenshot_path: Path,
                     purpose: str, budget: ResponseRepairBudget,
                     observation: dict[str, Any] | None = None,
                     metrics: dict[str, Any] | None = None,
                     ledger: TaskEvidenceLedger | None = None) -> dict[str, Any]:
    images = detail_images(observation)
    def request(text: str) -> str:
        return client.prompt(text, screenshot_path, detail_images=images) if images else client.prompt(text, screenshot_path)
    def prompt(text: str) -> str:
        before = getattr(client, "successful_provider_retries", None)
        try:
            return request(text)
        except Exception as error:
            if classify_failure(error, time.time()).kind != "transport" or getattr(client, "reconnects", 0) >= 1:
                raise
            selected = client.selected_model
            client.reconnect()
            if metrics is not None:
                metrics["reconnects"] += 1
                metrics[purpose] += 1
            client.select_model(selected)
            return request(text)
        finally:
            after = getattr(client, "successful_provider_retries", None)
            if metrics is not None and type(after) is int:
                metrics["provider_retries"] = (metrics["provider_retries"] or 0) + after - (before if type(before) is int else 0)

    def validate(response: str) -> dict[str, Any]:
        try:
            value = extract_json_object(response)
        except ResponseValidationError:
            # Only non-JSON provider errors use provider recovery. Invalid
            # decision fields containing words like "quota" are still repaired.
            if response.lstrip().startswith(("{", "[", "```")):
                raise
            failure = classify_failure(RuntimeError(response), time.time())
            details = {
                "credentials": "OpenClaw rejected an invalid API key; repair credentials in Settings.",
                "quota": "OpenClaw reported exhausted quota; wait for the reported reset.",
                "temporary": "OpenClaw reported temporary capacity limits; retry after cooldown.",
                "unavailable": "OpenClaw reported the selected model unavailable.",
                "transport": "OpenClaw reported a transport failure.",
                "cancelled": "OpenClaw cancelled the TaskPilot turn.",
            }
            if failure.kind in details:
                raise ModelAttemptError.from_failure(failure)
            raise
        envelope = response_error(value)
        if envelope is not None:
            failure = classify_failure(ProviderRequestError(envelope, getattr(client, "selected_model", None)), time.time())
            failure.provider_retries_counted = metrics is not None and type(getattr(client, "last_prompt_provider_retries", None)) is int
            raise ModelAttemptError.from_failure(failure)
        return validate_response(value, purpose, observation, ledger)

    response = prompt(instruction)
    try:
        return validate(response)
    except ResponseValidationError as error:
        if budget.used:
            raise ModelAttemptError(str(error)) from error
        budget.used = True
        if metrics is not None:
            metrics["repairs"] += 1
            metrics[purpose] += 1
        emit("status", message="Correcting the response format before changing models…")
        repair = compile_repair(instruction, response, str(error), purpose)
        repaired = prompt(repair)
        try:
            return validate(repaired)
        except ResponseValidationError as error:
            raise ModelAttemptError(str(error)) from error


def routed_json_prompt(
    router: TaskModelRouter,
    client: ACPClient,
    instruction: str,
    screenshot_path: Path,
    purpose: str = "planning",
    observation: dict[str, Any] | None = None,
    ledger: TaskEvidenceLedger | None = None,
) -> dict[str, Any]:
    key = hashlib.sha256(json.dumps([VALIDATION_VERSION, CONTRACT_HASH, CHECKLIST_VERSION, EXPECTED_EFFECT_VERSION, PROMPT_COMPILER_VERSION, COORDINATE_MAPPING_VERSION, OBSERVATION_COMPLETENESS_VERSION, TEXT_RECOGNITION_VERSION, ledger.fingerprint() if ledger else None, purpose, instruction, coverage_cache_input(observation)], sort_keys=True).encode() + screenshot_path.read_bytes()).hexdigest()
    cached = getattr(client, "decision_cache", {})
    if cached.get("key") == key:
        value = validate_response(json.loads(json.dumps(cached["decision"])), purpose, observation, ledger)
        router.metrics["cache_hits"] += 1
        return value
    budget = ResponseRepairBudget()
    def request_with_model(model: str) -> dict[str, Any]:
        client.select_model(model)
        return validated_prompt(client, instruction, screenshot_path, purpose, budget, observation, router.metrics, ledger)

    result = router.execute(request_with_model, purpose=purpose)
    action = result.get("action") or {}
    if not action or action.get("type") in {"none", "wait"}:
        client.decision_cache = {"key": key, "decision": result}
    else:
        client.decision_cache = {}
    router.metrics["model_switches"] = getattr(client, "model_switches", 0)
    emit("request_metrics", **router.metrics)
    return result


def run_task(task: str, display_id: int, openclaw_path: str | None, api_key: str) -> None:
    global _observation_keywords
    _observation_keywords = []
    _receipt_metrics.update(receipt_queries=0, receipt_recoveries=0, receipt_unresolved=0)
    ledger = TaskEvidenceLedger(task, _task_generation_id)
    resolved_openclaw = find_openclaw(openclaw_path)
    state = prepare_runtime(resolved_openclaw, api_key)
    api_key = ""
    if is_largest_downloads_file_task(task):
        # This is an objective local filesystem fact, not a visual judgment.
        # Answer it from exact metadata after the user explicitly names
        # Downloads, avoiding Gemini quota use and Finder sort/group ambiguity.
        emit("status", message=f"{PRODUCT_NAME} is checking exact file sizes in Downloads…")
        largest = largest_top_level_file(Path.home() / "Downloads")
        readable_size = formatted_file_size(int(largest["bytes"]))
        message = (
            f"The largest file in your Downloads folder is '{largest['name']}', "
            f"which is {readable_size} ({int(largest['bytes']):,} bytes)."
        )
        ledger.local_answer(message)
        emit("request_metrics", planning=0, verification=0, retries=0, model_switches=0, cache_hits=0, reconnects=0, provider_retries=None, **_receipt_metrics)
        complete_from_decision({"output": message, "output_title": "Largest File in Downloads", "output_kind": "answer"}, message, ledger)
        return
    if ledger.local_complete_grammar:
        check = next(iter(ledger.requirements.values()))["check"]
        action = {"type": "read_file", "path": check["path"], "max_bytes": action_default("read_file", "max_bytes")}
        result = bridge_call("act", display_id, action=action)
        ledger.record_action(action, result)
        if result.get("truncated") is not False:
            raise RuntimeError("The requested full file contents exceed the bounded 128 KiB read limit; the task is incomplete")
        output = ledger.exact_output(check, next(iter(ledger.requirements.values()))["evidence_ids"])
        if output is None:
            raise RuntimeError("TaskPilot could not verify the requested file contents; the task is incomplete")
        emit("request_metrics", planning=0, verification=0, retries=0, model_switches=0, cache_hits=0, reconnects=0, provider_retries=None, **_receipt_metrics)
        complete_from_decision({"output": output, "output_title": "File contents", "output_kind": "result"}, str(result.get("message") or "Read file"), ledger)
        return

    _observation_keywords = sorted(w for w in words(task) if len(w) <= 64 and w.isalnum())[:48]
    try:
        client = ACPClient(resolved_openclaw)
    except Exception as error:
        _observation_keywords = []
        state.record_failure(PRIMARY_MODELS[0], classify_failure(error, time.time()))
        emit("model_health", model=PRIMARY_MODELS[0], state="repair", detail=str(error))
        raise
    model_router = TaskModelRouter(state=state)
    history: list[dict[str, Any]] = []
    last_action_signature = ""
    last_screen_digest = ""
    identical_action_count = 0
    consecutive_action_failures = 0
    blocked_recoveries = 0
    pending_observation: dict[str, Any] | None = None
    recovery = ActionRecovery()
    loading_pid: int | None = None
    loading_waits = 0
    try:
        emit("status", message=f"OpenClaw is connecting to the {PRODUCT_NAME} screen…")
        for step in range(1, MAX_STEPS + 1):
            observation = pending_observation if pending_observation is not None else bridge_call("observe", display_id)
            pending_observation = None
            screenshot_path = Path(str(observation.get("screenshot_path") or ""))
            if not screenshot_path.is_file():
                raise RuntimeError(f"{PRODUCT_NAME} did not provide a readable screen image")
            ledger.observe(observation)

            # Passwords and verification codes stay entirely on the private
            # TaskPilot runtime pipe. Detect a visible secure field before the
            # screenshot or observation reaches OpenClaw, pause, and let the
            # native app collect the value locally.
            automatic_input_target = secure_input_target(observation, history)
            if automatic_input_target is not None:
                screenshot_path.unlink(missing_ok=True)
                emit("status", message=f"{PRODUCT_NAME} paused because the waiting app needs secure input…")
                ledger.before_action({"type": "type_text"})
                secure_result = request_and_enter_user_input(
                    automatic_input_target, display_id
                )
                history.append({
                    "step": step,
                    "action": "user_input_entered",
                    "result": secure_result,
                    "completed_requirements": [],
                    "remaining_requirements": [],
                })
                pending_observation, _ = wait_for_screen_change(
                    display_id, observation, {"type": "type_text", "pid": automatic_input_target["pid"]})
                loading_pid, loading_waits = None, 0
                continue

            if loading_pid is not None:
                if observation_is_loading(observation, loading_pid):
                    if loading_waits >= 2:
                        discard_observation_image(observation)
                        raise RuntimeError("The target app is still loading after bounded local recovery; no action was repeated while it was busy.")
                    loading_waits += 1
                    try:
                        pending_observation, settling = wait_for_screen_change(
                            display_id, observation, {"type": "wait", "pid": loading_pid}, timeout=5.0)
                    finally:
                        discard_observation_image(observation)
                    history.append({"step": step, "action": {"type": "wait", "seconds": 5},
                                    "result": {"message": "Waited locally for the loading app", "recovery": "wait_for_loading", "settling": settling}})
                    continue
                loading_pid, loading_waits = None, 0

            try:
                screenshot_bytes = screenshot_path.read_bytes()
                screenshot_digest = hashlib.blake2b(screenshot_bytes, digest_size=16).hexdigest()
                emit("status", message=f"OpenClaw is planning visible step {step}…")
                decision = routed_json_prompt(
                    model_router,
                    client,
                    desktop_instruction(task, observation, history, ledger),
                    screenshot_path,
                    observation=observation, ledger=ledger,
                )
            finally:
                screenshot_path.unlink(missing_ok=True)

            ledger.accept_plan(decision)
            status = effective_decision_status(decision)
            summary = str(decision.get("summary") or "OpenClaw inspected the screen")
            emit("status", message=summary)

            if status == "needs_user":
                input_target = decision_user_input_target(decision)
                emit("status", message=f"{PRODUCT_NAME} paused because the waiting app needs secure input…")
                ledger.before_action({"type": "type_text"})
                secure_result = request_and_enter_user_input(input_target, display_id)
                history.append({
                    "step": step,
                    "action": "user_input_entered",
                    "result": secure_result,
                    "completed_requirements": decision.get("completed_requirements") or [],
                    "remaining_requirements": decision.get("remaining_requirements") or [],
                })
                pending_observation, _ = wait_for_screen_change(
                    display_id, observation, {"type": "type_text", "pid": input_target["pid"]})
                continue

            if status == "blocked":
                reason = str(decision.get("reason") or summary or "OpenClaw is blocked")
                if re.search(r"credential|password|verification code|permission denied|not authorized|cancelled|destructive|irreversible", reason, re.I):
                    raise RuntimeError(reason)
                launch_recovery = blocked_recovery_action(task, observation, history)
                if launch_recovery:
                    decision = {"status": "act", "action": launch_recovery, "summary": "Opening the requested installed app"}
                    status = "act"
                elif blocked_recoveries < 1:
                    blocked_recoveries += 1
                    history.append({"step": step, "action": "blocked_recovery", "result": {
                        "message": "Reconsider on a fresh screen: check app launch, visible coordinate targets, menus, and prior rejection codes before declaring this task blocked.",
                        "previous_reason": reason}})
                    continue
                else:
                    raise RuntimeError(reason)

            if status == "done":
                if verify_task_completion(task, decision, display_id, history, model_router, client, ledger):
                    return
                continue

            if status != "act":
                raise RuntimeError("OpenClaw returned neither an action, completion, nor a blocker")

            action = normalized_action(decision.get("action"))
            action_type = str(action["type"])
            action_signature = action_identity(action, observation)
            recovered_result = recovery.check(action, observation)
            if recovered_result and recovered_result["outcome"] == "suppressed":
                history.append({"step": step, "action": "repeat_suppressed", "result": recovered_result})
                continue
            target_pid = action_target_pid(action, observation)
            if action_type in {"press", "focus", "set_value", "type_text", "click", "double_click", "key", "scroll"} \
                    and target_pid is not None and observation_is_loading(observation, target_pid):
                # The decision was made while its target was busy. Discard it;
                # never deliver its old target after local polling changes IDs.
                loading_pid, loading_waits = target_pid, 1
                pending_observation, settling = wait_for_screen_change(
                    display_id, observation, action, screenshot_digest, timeout=5.0, target_pid=target_pid)
                history.append({"step": step, "action": {"type": "wait", "seconds": 5},
                                "result": {"message": "Discarded the busy-target action and waited locally; select a fresh target",
                                           "recovery": "wait_for_loading", "settling": settling}})
                continue
            if action_type == "wait":
                identical_action_count = 0
            elif action_signature == last_action_signature and screenshot_digest == last_screen_digest:
                identical_action_count += 1
            else:
                identical_action_count = 1
            last_action_signature = action_signature
            last_screen_digest = screenshot_digest
            if identical_action_count > MAX_IDENTICAL_ACTIONS:
                    raise RuntimeError(
                        f"OpenClaw repeated the same desktop action on an unchanged screen; {PRODUCT_NAME} stopped the loop safely"
                    )

            if recovered_result:
                result_message = recovered_result
                consecutive_action_failures = 0
            elif action_type == "wait":
                seconds = float(action.get("seconds", action_default("wait", "seconds")))
                pending_observation, settling = wait_for_screen_change(
                    display_id, observation, action, screenshot_digest, timeout=seconds)
                result_message = {"message": "Observed locally while waiting", "settling": settling}
            elif action_type == "none":
                result_message = "No action was performed"
            else:
                try:
                    ledger.before_action(action)
                    result = bridge_call("act", display_id, action=action)
                except RuntimeError as action_error:
                    # Receipt lookup has already tried to recover a lost reply.
                    # An unresolved operation must stop, without another action.
                    if not isinstance(action_error, ActionRejected):
                        raise
                    code = getattr(action_error, "code", "action_rejected")
                    if code in {"cancelled", "permission_denied", "protected_target", "secure_input"}:
                        raise
                    consecutive_action_failures += 1
                    model_router.metrics["action_rejections"] += 1
                    failure_result = {"message": str(action_error),
                                      "outcome": "delivered_unconfirmed" if code == "delivery_uncertain" else "rejected",
                                      "error_code": code, "recovery": action_failure_recovery(code)}
                    recovery.rejected(action, observation, code)
                    record_action_diagnostic(action, failure_result)
                    if code == "delivery_uncertain":
                        model_router.metrics["unconfirmed_actions"] += 1
                    history.append({
                        "step": step,
                        "visual_evidence": str(decision.get("visual_evidence") or ""),
                        "action": action,
                        "result": failure_result,
                        **action_history_context(decision, action, observation),
                        "completed_requirements": decision.get("completed_requirements") or [],
                        "remaining_requirements": decision.get("remaining_requirements") or [],
                    })
                    if consecutive_action_failures >= 3:
                        raise RuntimeError(
                            "OpenClaw could not produce a valid action after three fresh screen checks"
                        ) from action_error
                    pending_observation = bridge_call("observe", display_id)
                    if target_pid is not None and (code == "delivery_uncertain" or observation_is_loading(pending_observation, target_pid)):
                        fresh = pending_observation
                        pending_observation = None
                        try:
                            pending_observation, settling = wait_for_screen_change(
                                display_id, fresh, action, timeout=5.0 if observation_is_loading(fresh, target_pid) else 2.0,
                                target_pid=target_pid)
                            failure_result["settling"] = settling
                        finally:
                            discard_observation_image(fresh)
                        if observation_is_loading(pending_observation, target_pid):
                            loading_pid, loading_waits = target_pid, 1
                    emit("status", message="Checking fresh evidence and the action failure before continuing…")
                    continue
                consecutive_action_failures = 0
                action = bind_command_outcomes(action, result)
                result_message = result
                model_router.metrics["action_deliveries"] += 1
                pending_observation, result_message = verify_expected_effect(
                    display_id, observation, action, result, decision.get('expected_result'), screenshot_digest, model_router.metrics)
                if result_message.get("outcome") == "verified":
                    recovery.succeeded(action, observation)
                if result_message.get("outcome") == "delivered_unconfirmed":
                    model_router.metrics["unconfirmed_actions"] += 1
                    recovery.unconfirmed(action, observation)
                    result_message = {**result_message, "recovery": "inspect_effect"}
                record_action_diagnostic(action, result_message)

            history.append({
                "step": step,
                "visual_evidence": str(decision.get("visual_evidence") or ""),
                "action": action,
                "result": result_message,
                **action_history_context(decision, action, observation),
                "completed_requirements": decision.get("completed_requirements") or [],
                "remaining_requirements": decision.get("remaining_requirements") or [],
            })
            if isinstance(result_message, dict):
                ledger.record_action(action, result_message)
                effect_proof = result_message.get('expected_effect', {})
                if effect_proof.get('outcome') == 'verified' and effect_proof.get('check') in FILE_EFFECTS:
                    ledger.record_effect(decision['expected_result'], effect_proof['evidence'], action)
            if (decision.get("finish_after_action") is True and action_type in {"write_file", "run_command"}
                    and isinstance(result_message, dict) and result_message.get('verification_scope') != 'expected_effect_unconfirmed'):
                discard_observation_image(pending_observation)
                pending_observation = None
                if verify_task_completion(task, decision, display_id, history, model_router, client, ledger):
                    return
        raise RuntimeError(f"{PRODUCT_NAME} reached its {MAX_STEPS}-step safety limit")
    except Exception:
        state.invalidate()
        raise
    finally:
        discard_observation_image(pending_observation)
        _observation_keywords = []
        publish_task_metrics(model_router, client, ledger)
        client.close()


def _stop_handler(_signal_number: int, _frame: Any) -> None:
    if _active_acp_process is not None and _active_acp_process.poll() is None:
        _active_acp_process.terminate()
    raise SystemExit(143)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=f"{PRODUCT_NAME} OpenClaw runtime")
    parser.add_argument("--task")
    parser.add_argument("--display-id", type=int)
    parser.add_argument("--openclaw-path")
    parser.add_argument("--check-models", action="store_true")
    parser.add_argument("--read-readiness", action="store_true")
    return parser.parse_args()


def read_runtime_configuration(require_generation: bool = False) -> str:
    global _task_generation_id, _bridge_observation_revision, _observation_keywords
    _task_generation_id = None
    _bridge_observation_revision = None
    _observation_keywords = []
    raw_line = runtime_line()
    try:
        configuration = json.loads(raw_line)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{PRODUCT_NAME} did not provide the secure runtime configuration") from error
    if not isinstance(configuration, dict) or configuration.get("kind") != "runtime_configuration":
        raise RuntimeError(f"{PRODUCT_NAME} did not provide the secure runtime configuration")
    if configuration.get("action_contract_hash") != CONTRACT_HASH or type(configuration.get("action_contract_version")) is not int or configuration.get("action_contract_version") != CONTRACT_VERSION:
        raise RuntimeError("TaskPilot backend action contracts do not match; rebuild the bundled app and runtime together")
    generation = configuration.get("task_generation_id")
    if require_generation:
        try:
            if not isinstance(generation, str) or str(uuid.UUID(generation)).lower() != generation.lower():
                raise ValueError("Invalid generation")
        except (ValueError, AttributeError):
            raise RuntimeError("TaskPilot did not provide a valid task generation ID")
        _task_generation_id = generation
        if type(configuration.get("task_protocol_version")) is not int or configuration["task_protocol_version"] != TASK_PROTOCOL_VERSION:
            raise RuntimeError("TaskPilot task ownership protocol does not match; rebuild the bundled components together")
        if type(configuration.get("coordinate_mapping_version")) is not int or configuration["coordinate_mapping_version"] != COORDINATE_MAPPING_VERSION:
            raise RuntimeError("TaskPilot screen coordinate mapping versions do not match; rebuild the bundled components together")
        if type(configuration.get("observation_completeness_version")) is not int or configuration["observation_completeness_version"] != OBSERVATION_COMPLETENESS_VERSION:
            raise RuntimeError("TaskPilot observation completeness versions do not match; rebuild the bundled components together")
        if type(configuration.get("text_recognition_version")) is not int or configuration["text_recognition_version"] != TEXT_RECOGNITION_VERSION:
            raise RuntimeError("TaskPilot text recognition versions do not match; rebuild the bundled components together")
    api_key = configuration.get("gemini_api_key")
    if not isinstance(api_key, str):
        raise RuntimeError(f"{PRODUCT_NAME} did not provide the secure runtime configuration")
    if api_key.strip() and len(api_key.strip()) < 20:
        raise RuntimeError(
            f"Add and save a complete Gemini API key in {PRODUCT_NAME} Settings before running a task."
        )
    return api_key.strip()


def main() -> int:
    try:
        os.setpgrp()
    except OSError:
        pass
    signal.signal(signal.SIGTERM, _stop_handler)
    signal.signal(signal.SIGINT, _stop_handler)
    args = parse_args()
    try:
        api_key = read_runtime_configuration(require_generation=args.task is not None)
        if args.check_models or args.read_readiness:
            return 0 if check_models(find_openclaw(args.openclaw_path), api_key, read_only=args.read_readiness) else 1
        if args.task is None or args.display_id is None:
            raise RuntimeError("TaskPilot requires a task and target display")
        run_task(args.task, args.display_id, args.openclaw_path, api_key)
        return 0
    except KeyboardInterrupt:
        return 130
    except Exception as error:
        failure = classify_failure(error, time.time())
        fields = failure.metadata()
        if isinstance(error, RecoveryExhaustedError):
            fields["model_failures"] = [{"model": model, **f.metadata()} for model, f in error.failures]
        message = failure.summary() if isinstance(error, ProviderRequestError) else str(error)
        emit("error", message=message, **fields)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
