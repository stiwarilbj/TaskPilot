"""TaskPilot's bounded model policy and private readiness cache."""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
from datetime import datetime
from email.utils import parsedate_to_datetime
import json
import os
from pathlib import Path
import re
import time
from typing import Any, Callable

PRIMARY_MODELS = ("google/gemini-3.5-flash-lite", "google/gemini-3.1-flash-lite")
FALLBACK_MODELS = (
    "google/gemini-2.5-flash-lite", "google/gemini-3.8-flash",
    "google/gemini-3-flash-preview", "google/gemini-2.5-flash",
)
ALL_MODELS = PRIMARY_MODELS + FALLBACK_MODELS
CONFIG_VERSION = 5


@dataclass
class Failure:
    kind: str
    detail: str
    retry_at: float = 0
    recovered_upstream: bool = False


class ModelAttemptError(RuntimeError):
    def __init__(self, detail: str, kind: str = "invalid_output") -> None:
        super().__init__(detail)
        self.kind = kind


def classify_failure(error: BaseException, now: float) -> Failure:
    message = str(error)
    lowered = message.lower()
    if isinstance(error, ModelAttemptError):
        return Failure(error.kind, message)
    upstream = any(s in lowered for s in ("all models failed", "recovery exhausted", "retry budget exhausted"))
    if any(s in lowered for s in ("invalid api key", "api key not valid", "api_key_invalid", "api key expired", "invalid credential", "unauthorized", "http 401")):
        return Failure("credentials", message)
    if any(s in lowered for s in ("cancelled the", "canceled the", "lost contact with the native", "task cancelled")):
        return Failure("cancelled", message)
    if any(s in lowered for s in ("acp exited", "acp stopped", "broken pipe", "gateway disconnected", "connection closed", "connection refused", "econnreset", "econnrefused", "socket closed", "transport closed")):
        return Failure("transport", message)
    if any(s in lowered for s in ("unknown model", "model not found", "model_not_found", "model is unavailable", "model unavailable", "unsupported model", "not allowed", "could not select", "no such model", "permission denied", "forbidden", "http 403", "http 404")):
        return Failure("unavailable", message)
    retry = re.search(r"(?:retry[- _]?after[\"\']?\s*[:=]?\s*[\"\']?|retrydelay[\"\']?\s*[:=]?\s*[\"\']?|retry in\s+|ready in\s*~?)(\d+(?:\.\d+)?)", lowered)
    delay = float(retry.group(1)) if retry else 30.0
    has_delay = retry is not None
    if retry is None:
        date_header = re.search(r"retry-after\s*:\s*([^\n]+)", message, re.IGNORECASE)
        if date_header:
            try:
                delay = max(0, parsedate_to_datetime(date_header.group(1).strip()).timestamp() - now)
                has_delay = True
            except (ValueError, TypeError, OverflowError):
                pass
    reset = re.search(r"(?:reset(?:s)?(?:[ _]?at)?\s*[:=]?\s*)(\d{10}(?:\.\d+)?)", lowered)
    reset_at = float(reset.group(1)) if reset else None
    if reset_at is None:
        iso_reset = re.search(r"reset(?:s)?(?:[ _]?at)?[\"\']?\s*[:=]?\s*[\"\']?(\d{4}-\d{2}-\d{2}T[\d:.]+(?:Z|[+-]\d{2}:?\d{2}))", message, re.IGNORECASE)
        if iso_reset:
            try:
                reset_at = datetime.fromisoformat(iso_reset.group(1).replace("Z", "+00:00")).timestamp()
            except ValueError:
                pass
    periodic = any(s in lowered for s in ("daily", "weekly", "monthly", "billing", "insufficient credits", "quota exhausted"))
    if periodic and any(s in lowered for s in ("quota", "limit", "credits", "billing")):
        return Failure("quota", message, reset_at if reset_at is not None else (now + delay if has_delay else float("inf")), upstream)
    if any(s in lowered for s in ("429", "503", "rate limit", "rate-limit", "rate_limit", "resource_exhausted", "resource exhausted", "overloaded", "temporarily unavailable", "high demand", "quota", "model request timed out", "model timed out")):
        return Failure("temporary", message, now + delay, upstream)
    if any(s in lowered for s in ("empty response", "incomplete desktop decision", "returned no desktop decision")):
        return Failure("invalid_output", message)
    return Failure("configuration", message, recovered_upstream=upstream)


class AdaptiveModelRouter:
    """One attempt per candidate plus at most two recoverable Lite retries."""
    def __init__(self, emit: Callable[..., None], state: RuntimeState | None = None,
                 clock: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep) -> None:
        self.emit, self.cache, self.clock, self.sleep = emit, state, clock, sleep
        self.active_model: str | None = None
        self.unavailable: set[str] = set()
        self.cooldowns: dict[str, float] = {}
        if state:
            for model in ALL_MODELS:
                health = state.health(model)
                if health.get("state") == "temporary":
                    self.cooldowns[model] = health.get("retry_at") or float("inf")
        self.metrics = {"planning": 0, "verification": 0, "retries": 0, "model_switches": 0,
                        "cache_hits": 0, "reconnects": 0, "provider_retries": None}

    def execute(self, operation: Callable[[str], Any], purpose: str = "planning") -> Any:
        order = ([self.active_model] if self.active_model else []) + [m for m in ALL_MODELS if m != self.active_model]
        delayed: list[tuple[str, Failure]] = []
        for model in PRIMARY_MODELS:
            reset = self.cooldowns.get(model, 0)
            health = self.cache.health(model) if self.cache else {}
            if self.clock() < reset < float("inf") and not health.get("recovered_upstream"):
                delayed.append((model, Failure("temporary", "Provider cooldown is still active", reset)))
        failures: list[tuple[str, Failure]] = []
        retries = 0

        def attempt(model: str, retry: bool = False) -> Any:
            self.metrics[purpose] += 1
            if retry:
                self.metrics["retries"] += 1
            self.emit("status", message=f"Waiting for {model.split('/', 1)[-1]} to finish…")
            return operation(model)

        for model in order:
            if model in self.unavailable or self.cooldowns.get(model, 0) > self.clock():
                continue
            try:
                result = attempt(model)
            except Exception as error:
                failure = classify_failure(error, self.clock())
                if self.cache:
                    self.cache.record_failure(model, failure)
                if failure.kind in {"credentials", "cancelled", "transport", "configuration"}:
                    for other in ALL_MODELS:
                        if other != model:
                            self.emit("model_health", model=other, state="configured", detail="Runtime verification invalidated")
                    self.emit("model_health", model=model, state="repair", detail=failure.detail)
                    raise
                failures.append((model, failure))
                if failure.kind == "unavailable":
                    self.unavailable.add(model)
                elif failure.kind in {"quota", "temporary"}:
                    self.cooldowns[model] = failure.retry_at
                if model in PRIMARY_MODELS and (failure.kind in {"temporary", "invalid_output"} or (failure.kind == "quota" and failure.retry_at != float("inf"))) and not failure.recovered_upstream:
                    delayed.append((model, failure))
                self.emit("model_health", model=model,
                          state="temporary" if failure.kind in {"quota", "temporary"} else "repair",
                          detail=failure.detail, retry_at=failure.retry_at if failure.retry_at != float("inf") else None)
                continue
            self.active_model = model
            self.cooldowns.pop(model, None)
            if self.cache:
                self.cache.verify(model)
            self.emit("model_health", model=model, state="verified", detail="Verified through TaskPilot")
            return result

        # Only retry primaries after other eligible candidates have been tried.
        for model, failure in delayed:
            if retries >= 2:
                break
            delay = max(0, failure.retry_at - self.clock())
            if delay:
                self.emit("status", message=f"Waiting {delay:g}s for {model.split('/', 1)[-1]} capacity…")
                self.sleep(delay)
            retries += 1
            try:
                result = attempt(model, retry=True)
            except Exception as error:
                next_failure = classify_failure(error, self.clock())
                if self.cache:
                    self.cache.record_failure(model, next_failure)
                self.emit("model_health", model=model, state="temporary" if next_failure.kind in {"quota", "temporary"} else "repair", detail=next_failure.detail)
                if next_failure.kind in {"credentials", "cancelled", "transport", "configuration"}:
                    raise
                failures.append((model, next_failure))
                if next_failure.kind in {"quota", "temporary"}:
                    self.cooldowns[model] = next_failure.retry_at
                elif next_failure.kind == "unavailable":
                    self.unavailable.add(model)
                continue
            self.active_model = model
            self.cooldowns.pop(model, None)
            if self.cache:
                self.cache.verify(model)
            self.emit("model_health", model=model, state="verified", detail="Verified through TaskPilot")
            return result
        details = "; ".join(f"{m.split('/', 1)[-1]}: {f.detail[:180]}" for m, f in failures)
        if not details:
            details = "Models are still in cooldown or unavailable for this task. Wait for capacity or use Check in Settings."
        raise RuntimeError(f"No eligible Gemini model completed this decision. {details}")


class RuntimeState:
    """No plaintext credentials, screenshots or user requests are persisted."""
    def __init__(self, fingerprint: str, version: str, root: Path | None = None, configuration: str = "") -> None:
        self.root = root or Path(os.environ.get("ORBIT_RUNTIME_STATE_DIRECTORY", str(Path.home() / "Library/Application Support/Orbit Agent")))
        self.path = self.root / "runtime-readiness.json"
        self.identity = hashlib.sha256(json.dumps([fingerprint, version, CONFIG_VERSION, ALL_MODELS, configuration]).encode()).hexdigest()
        try:
            value = json.loads(self.path.read_text())
            self.value = value if isinstance(value, dict) and value.get("identity") == self.identity else ({"config_version": value.get("config_version")} if isinstance(value, dict) else {})
            for field in ("verified", "health"):
                if not isinstance(self.value.get(field, {}), dict):
                    self.value[field] = {}
        except (OSError, ValueError, AttributeError):
            self.value = {}

    def save(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.value["identity"] = self.identity
        temporary = self.path.with_name(f".{self.path.name}.{os.getpid()}.tmp")
        temporary.write_text(json.dumps(self.value, allow_nan=False))
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.path)

    def verify(self, model: str) -> None:
        self.value.setdefault("health", {}).pop(model, None)
        self.value.setdefault("verified", {})[model] = time.time()
        self.save()

    def invalidate(self, model: str | None = None) -> None:
        if model:
            self.value.setdefault("verified", {}).pop(model, None)
        else:
            self.value["verified"] = {}
        self.save()

    def record_failure(self, model: str, failure: Failure) -> None:
        if failure.kind in {"credentials", "transport", "configuration"}:
            self.value["verified"] = {}
        else:
            self.value.setdefault("verified", {}).pop(model, None)
        self.value.setdefault("health", {})[model] = {
            "state": "temporary" if failure.kind in {"quota", "temporary"} else "repair",
            "detail": failure.detail[:500],
            "retry_at": failure.retry_at if failure.retry_at != float("inf") else None,
            "recovered_upstream": failure.recovered_upstream,
        }
        self.save()

    def health(self, model: str) -> dict[str, Any]:
        result = self.value.get("health", {}).get(model, {})
        if not isinstance(result, dict):
            return {}
        if result.get("state") == "temporary" and result.get("retry_at") and result["retry_at"] <= time.time():
            return {}
        return result

    def verified_model(self) -> str | None:
        now = time.time()
        return next((m for m in ALL_MODELS if isinstance(self.value.get("verified", {}).get(m), (int, float)) and 0 <= now - self.value["verified"][m] < 600), None)
