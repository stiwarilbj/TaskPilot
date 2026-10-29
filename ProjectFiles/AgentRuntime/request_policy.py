"""TaskPilot's bounded model policy and private readiness cache."""
from __future__ import annotations

from response_validation import VALIDATION_VERSION
from action_contract_generated import CONTRACT_HASH
from provider_errors import ProviderRequestError, facts, normalize_error, retry_time

from dataclasses import dataclass, replace
from datetime import datetime, timezone
import ctypes
import hashlib
import errno
import fcntl
from contextlib import contextmanager
import tempfile
import threading
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time
from types import MappingProxyType
from typing import Any, Callable, Mapping
from lock_order import LockCategory, reserve

PRIMARY_MODELS = ("google/gemini-3.5-flash-lite", "google/gemini-3.1-flash-lite")
FALLBACK_MODELS = (
    "google/gemini-2.5-flash-lite", "google/gemini-3.8-flash",
    "google/gemini-3-flash-preview", "google/gemini-2.5-flash",
)
ALL_MODELS = PRIMARY_MODELS + FALLBACK_MODELS
CONFIG_VERSION = 5
ERROR_POLICY_VERSION = 1
VERIFICATION_CACHE_SECONDS = 600
VERIFICATION_CLOCK_VERSION = 1
READINESS_PRUNE_MAX_CREDENTIALS = 64
READINESS_PRUNE_MAX_IDENTITIES = 128
READINESS_PRUNE_MAX_HEALTH_RECORDS = 128
READINESS_PRUNE_MAX_LEASE_SCAN = 64
READINESS_PRUNE_MAX_DIRECTORY_ENTRIES = 256
READINESS_STATE_MAX_BYTES = 8 * 1024 * 1024
_READINESS_IDENTITY = re.compile(r"^[0-9a-f]{64}$")


def _read_boot_session_marker() -> str | None:
    """Return a stable operating-system boot identity, or fail closed."""
    try:
        if sys.platform == "darwin":
            libc = ctypes.CDLL(None, use_errno=True)
            sysctlbyname = libc.sysctlbyname
            sysctlbyname.argtypes = (ctypes.c_char_p, ctypes.c_void_p,
                                     ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p,
                                     ctypes.c_size_t)
            sysctlbyname.restype = ctypes.c_int
            size = ctypes.c_size_t(0)
            if sysctlbyname(b"kern.bootsessionuuid", None, ctypes.byref(size), None, 0) != 0:
                return None
            if size.value < 2 or size.value > 128:
                return None
            buffer = ctypes.create_string_buffer(size.value)
            if sysctlbyname(b"kern.bootsessionuuid", buffer, ctypes.byref(size), None, 0) != 0:
                return None
            value = buffer.value.decode("ascii")
            return value.lower() if re.fullmatch(r"[0-9a-fA-F-]{36}", value) else None
        if sys.platform.startswith("linux"):
            value = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
            return value.lower() if re.fullmatch(r"[0-9a-fA-F-]{36}", value) else None
    except Exception:
        return None
    return None


_BOOT_SESSION_MARKER = _read_boot_session_marker()


def _boot_session_marker() -> str | None:
    return _BOOT_SESSION_MARKER


def _finite_number(value: Any) -> bool:
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except (OverflowError, ValueError):
        return False


@dataclass
class Failure:
    kind: str
    detail: str
    retry_at: float = 0
    recovered_upstream: bool = False
    code: str | int | None = None
    codes: tuple[str | int, ...] = ()
    http_status: int | None = None
    provider_status: str | None = None
    rpc_code: int | None = None
    reason: str | None = None
    provider: str | None = None
    model: str | None = None
    scope: str = "unknown"
    attempts: tuple[dict[str, Any], ...] = ()
    provider_retries: int | None = None
    provider_retries_counted: bool = False

    def metadata(self) -> dict[str, Any]:
        """Only machine identifiers and normalized policy facts may leave memory."""
        return {"failure_kind": self.kind, "error_code": self.code, "error_codes": list(self.codes),
                "http_status": self.http_status, "provider_status": self.provider_status,
                "rpc_code": self.rpc_code, "failure_reason": self.reason, "provider": self.provider,
                "provider_model": self.model, "failure_scope": self.scope, "upstream_attempts": list(self.attempts),
                "recovered_upstream": self.recovered_upstream, "provider_retries": self.provider_retries,
                "retry_at": self.retry_at if math.isfinite(self.retry_at) else None}

    def summary(self) -> str:
        explanation = {
            "credentials": "OpenClaw rejected an invalid API key or credential. Repair credentials in Settings.",
            "quota": "Provider quota is exhausted.",
            "temporary": "Provider capacity or service is temporarily unavailable.",
            "unavailable": "The selected model is unavailable or not permitted.",
            "transport": "The OpenClaw connection failed.",
            "cancelled": "OpenClaw cancelled the TaskPilot turn.",
            "invalid_output": "The response did not satisfy the required JSON contract.",
            "configuration": "OpenClaw or provider configuration needs repair.",
        }.get(self.kind, "Provider request failed.")
        codes = list(dict.fromkeys(str(c) for c in (*self.codes, self.code, self.provider_status, self.reason) if c is not None))
        if self.http_status is not None: codes.append(f"HTTP {self.http_status}")
        if self.rpc_code is not None: codes.append(f"ACP {self.rpc_code}")
        if codes: explanation += " [" + ", ".join(codes) + "]"
        if self.scope == "credential": explanation += " This failure affects models sharing this credential."
        elif self.scope == "model": explanation += " This failure is specific to this model."
        if self.kind in {"quota", "temporary"}:
            if math.isfinite(self.retry_at):
                try: reset = datetime.fromtimestamp(self.retry_at, timezone.utc).isoformat()
                except (ValueError, OverflowError, OSError): reset = str(self.retry_at)
                explanation += f" Retry after {reset}."
            else:
                explanation += " No reset was reported; use Check after provider quota or billing is repaired."
        return explanation

    @classmethod
    def from_health(cls, value: dict[str, Any]) -> Failure:
        return cls(value.get("failure_kind", "temporary"), value.get("detail", "Provider cooldown is active"),
                   value.get("retry_at") if isinstance(value.get("retry_at"), (float, int)) else float("inf"),
                   value.get("recovered_upstream") is True, code=value.get("error_code"),
                   codes=tuple(value.get("error_codes") or []), http_status=value.get("http_status"),
                   provider_status=value.get("provider_status"), rpc_code=value.get("rpc_code"),
                   reason=value.get("failure_reason"), provider=value.get("provider"), model=value.get("provider_model"),
                   scope=value.get("failure_scope", "unknown"), attempts=tuple(value.get("upstream_attempts") or []),
                   provider_retries=value.get("provider_retries"))


class ModelAttemptError(RuntimeError):
    def __init__(self, detail: str, kind: str = "invalid_output", retry_at: float = 0,
                 recovered_upstream: bool = False, *, failure: Failure | None = None) -> None:
        super().__init__(detail)
        self.failure = failure or Failure(kind, detail, retry_at, recovered_upstream)
        self.kind = self.failure.kind
        self.retry_at = self.failure.retry_at
        self.recovered_upstream = self.failure.recovered_upstream

    @classmethod
    def from_failure(cls, failure: Failure) -> ModelAttemptError:
        return cls(failure.summary(), failure=failure)


class RecoveryExhaustedError(ModelAttemptError):
    def __init__(self, failures: list[tuple[str, Failure]]) -> None:
        self.failures = tuple(failures)
        details = "; ".join(f"{m.split('/', 1)[-1]}: {f.summary()}" for m, f in failures)
        super().__init__("No eligible Gemini model completed this decision. " + (details or
                         "Models are unavailable for this task. Wait for capacity or use Check in Settings."),
                         failure=failures[-1][1] if failures else Failure("unavailable", "No eligible model"))


def model_route(failure: Failure, default: str) -> str:
    model = failure.model or default.split('/', 1)[-1]
    return model if '/' in model else f"{failure.provider or default.split('/', 1)[0]}/{model}"


def classify_failure(error: BaseException, now: float, model: str | None = None, *, _attempt: bool = False) -> Failure:
    if isinstance(error, ModelAttemptError):
        return replace(error.failure, provider=error.failure.provider or (model.split('/', 1)[0] if model else None),
                       model=error.failure.model or (model.split('/', 1)[-1] if model else None))
    message = str(error)
    lowered = message.lower()
    view = error.take_error_view() if isinstance(error, ProviderRequestError) else normalize_error(message)
    fields = facts(view, getattr(error, "model", None) or model)
    if str(getattr(error, 'code', '')).startswith(('transport_', 'local_resource_')):
        fields['code'] = error.code
    code, status, reason = fields.get("code"), fields.get("status"), fields.get("reason")
    tokens = {str(t).lower().replace('-', '_') for t in (*fields.get("codes", []), status, reason) if t is not None}
    http = fields.get("http_status")
    if http is None:
        match = re.search(r'\bHTTP\s*[:=]?\s*([45]\d\d)\b', message, re.I)
        if match:
            http = int(match.group(1))
    upstream = fields["recovered_upstream"] or any(s in lowered for s in ("all models failed", "recovery exhausted", "retry budget exhausted"))
    reset = retry_time(view, message, now)
    del view
    scope = fields["scope"]

    if str(code).startswith('local_resource_'):
        kind = "configuration"  # Local storage failure: no provider cooldown/fallback.
    elif http == 401 or tokens & {"auth", "auth_permanent", "authentication_error", "unauthenticated", "invalid_api_key", "api_key_invalid", "invalid_credentials", "authentication_failed"} or any(s in lowered for s in ("invalid api key", "api key not valid", "api_key_invalid", "api key expired", "invalid credential", "unauthorized", "http 401")):
        kind, scope = "credentials", "credential"
    elif "cancelled" in tokens or "canceled" in tokens or any(s in lowered for s in ("cancelled the", "canceled the", "lost contact with the native", "task cancelled")):
        kind = "cancelled"
    elif str(getattr(error, 'code', '')).startswith('transport_') or tokens & {"transport", "econnreset", "econnrefused", "epipe", "socket_closed"} or any(s in lowered for s in ("acp exited", "acp stopped", "broken pipe", "gateway disconnected", "connection closed", "connection refused", "econnreset", "econnrefused", "socket closed", "transport closed")):
        kind = "transport"
    elif tokens & {"model_not_found", "unknown_model", "unsupported_model", "model_not_allowed"} or any(s in lowered for s in ("unknown model", "model not found", "model_not_found", "model is unavailable", "model unavailable", "unsupported model", "no such model")):
        kind, scope = "unavailable", "model"
    elif tokens & {"format", "configuration", "invalid_request", "invalid_argument", "unsupported_parameter", "context_length_exceeded", "context_window_exceeded"}:
        kind = "configuration"
    elif http == 402 or fields.get("periodic_quota") or tokens & {"billing", "insufficient_quota", "insufficient_credits", "billing_hard_limit_reached", "quota_exhausted", "quota_exceeded", "daily_quota_exceeded"} or (any(s in lowered for s in ("daily", "weekly", "monthly", "billing", "insufficient credits", "quota exhausted")) and any(s in lowered for s in ("quota", "limit", "credits", "billing"))):
        kind = "quota"
        if (http == 402 or tokens & {"billing", "insufficient_quota", "insufficient_credits", "billing_hard_limit_reached"}) and scope != "model": scope = "credential"
    elif (http is not None and http >= 500) or http in {408, 429, 499} or tokens & {"rate_limit", "rate_limit_exceeded", "resource_exhausted", "overloaded", "capacity", "server_error", "timeout", "unavailable"} or any(s in lowered for s in ("429", "503", "rate limit", "rate-limit", "rate_limit", "resource_exhausted", "resource exhausted", "overloaded", "temporarily unavailable", "high demand", "quota", "model request timed out", "model timed out")):
        kind = "temporary"
    elif any(s in lowered for s in ("empty response", "incomplete desktop decision", "returned no desktop decision")):
        kind = "invalid_output"
    else:
        kind = "configuration"
    if reason is None and http is not None:
        if http in {503, 529}: reason = "overloaded"
        elif http in {408, 499, 504, 522, 524}: reason = "timeout"
        elif http >= 500: reason = "server_error"
        elif http == 429: reason = "rate_limit"
    deadline = 0
    if kind == "quota": deadline = reset if reset is not None else float("inf")
    elif kind == "temporary": deadline = reset if reset is not None else now + 30
    attempts = []
    if not _attempt:
        for item in fields["attempts"]:
            # Do not invent provider/model identity for upstream attempts.
            failure = classify_failure(ProviderRequestError(item), now, _attempt=True)
            attempts.append(failure.metadata())
    if kind == "configuration" and attempts and http is None and not tokens:
        kinds = {a["failure_kind"] for a in attempts}
        # A generic exhausted wrapper must not hide classified inner failures.
        kind = next((k for k in ("credentials", "cancelled", "transport", "configuration") if k in kinds),
                    "quota" if kinds == {"quota"} else "unavailable" if kinds == {"unavailable"} else "temporary")
        deadlines = [Failure.from_health(a).retry_at for a in attempts if a["failure_kind"] in {"quota", "temporary"}]
        deadline = min(deadlines) if deadlines else 0
    return Failure(kind, message, deadline, upstream, code=code, codes=tuple(fields.get("codes", [])),
                   http_status=http, provider_status=status, rpc_code=fields.get("rpc_code"), reason=reason,
                   provider=fields.get("provider"), model=fields.get("model"), scope=scope,
                   attempts=tuple(attempts), provider_retries=fields.get("provider_retries"))


class AdaptiveModelRouter:
    """One attempt per candidate plus at most two recoverable Lite retries."""
    def __init__(self, emit: Callable[..., None], state: RuntimeState | None = None,
                 clock: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep) -> None:
        self.emit, self.cache, self.clock, self.sleep = emit, state, clock, sleep
        self.active_model: str | None = None
        self.unavailable: set[str] = set()
        self.cooldowns: dict[str, float] = {}
        self.model_failures: dict[str, Failure] = {}
        self.credential_failures: dict[str, Failure] = {}
        self.refresh_shared_health()
        self.metrics = {"planning": 0, "verification": 0, "retries": 0, "model_switches": 0,
                        "cache_hits": 0, "reconnects": 0, "repairs": 0, "provider_retries": None,
                        "action_deliveries": 0, "action_rejections": 0, "unconfirmed_actions": 0}

    def refresh_shared_health(self) -> None:
        if not self.cache: return
        self.cooldowns.clear()
        self.model_failures.clear()
        self.credential_failures.clear()
        for model, health in self.cache.health_snapshot(now=self.clock()).items():
            if health.get("state") == "temporary":
                failure = Failure.from_health(health)
                if failure.scope == "credential":
                    self.credential_failures[model.split('/', 1)[0]] = failure
                else:
                    self.cooldowns[model] = failure.retry_at
                    self.model_failures[model] = failure

    def execute(self, operation: Callable[[str], Any], purpose: str = "planning") -> Any:
        self.refresh_shared_health()
        order = ([self.active_model] if self.active_model else []) + [m for m in ALL_MODELS if m != self.active_model]
        delayed: list[tuple[str, Failure]] = []
        failures: list[tuple[str, Failure]] = []
        attempted: set[str] = set()
        exhausted: set[str] = set()
        retries = 0
        started_revision = None

        def shared(model: str) -> Failure | None:
            failure = self.credential_failures.get(model.split('/', 1)[0])
            return failure if failure and failure.retry_at > self.clock() else None

        def recoverable(failure: Failure) -> bool:
            return failure.kind in {"quota", "temporary"} and math.isfinite(failure.retry_at) and not failure.recovered_upstream

        def schedule(model: str, failure: Failure) -> None:
            if model in PRIMARY_MODELS and recoverable(failure):
                delayed.append((model, failure))

        for model in PRIMARY_MODELS:
            failure = self.model_failures.get(model)
            if failure and failure.retry_at > self.clock(): schedule(model, failure)
        for provider, failure in self.credential_failures.items():
            if failure.retry_at > self.clock():
                owner = model_route(failure, PRIMARY_MODELS[0])
                failures.append((owner, failure))
                schedule(owner if owner in PRIMARY_MODELS else next((m for m in PRIMARY_MODELS if m.startswith(provider + '/')), owner), failure)

        def attempt(model: str, retry: bool = False) -> Any:
            self.metrics[purpose] += 1
            if retry:
                self.metrics["retries"] += 1
            self.emit("wait_phase", phase="model_response", waiting_for="The model’s response")
            self.emit("status", message=f"Waiting for {model.split('/', 1)[-1]} to finish…")
            return operation(model)

        def accept(model: str, result: Any) -> Any:
            self.active_model = model
            self.cooldowns.pop(model, None)
            self.model_failures.pop(model, None)
            # A terminal successful response proves this credential can run again.
            self.credential_failures.pop(model.split('/', 1)[0], None)
            if self.cache:
                if not self.cache.verify(model, started_revision, now=self.clock()):
                    health = self.cache.health(model, now=self.clock())
                    self.emit("model_health", model=model, **{k: v for k, v in health.items() if k != "model"})
                    return result
            self.emit("model_health", model=model, state="verified", detail="Verified through TaskPilot")
            return result

        def remember(model: str, failure: Failure, upstream: bool = False) -> None:
            if self.cache: self.cache.record_failure(model, failure)
            failures.append((model, failure))
            if upstream or failure.recovered_upstream: exhausted.add(model)
            if failure.kind == "unavailable": self.unavailable.add(model)
            if failure.kind in {"quota", "temporary"}:
                if failure.scope == "credential":
                    provider = failure.provider or model.split('/', 1)[0]
                    current = self.credential_failures.get(provider)
                    if not current or current.retry_at < failure.retry_at:
                        self.credential_failures[provider] = failure
                    # One retry of the owning Lite model can reopen this credential;
                    # sibling requests cannot bypass its shared limit.
                    delayed[:] = [(m, f) for m, f in delayed if not m.startswith(provider + '/')]
                else:
                    self.cooldowns[model] = failure.retry_at
                    self.model_failures[model] = failure
            if not upstream: schedule(model, failure)
            affected = [m for m in ALL_MODELS if m.startswith((failure.provider or model.split('/', 1)[0]) + '/')] if failure.scope == "credential" and failure.kind in {"quota", "temporary"} else [model]
            for other in affected:
                self.emit("model_health", model=other,
                          state="temporary" if failure.kind in {"quota", "temporary"} else "repair",
                          detail=failure.summary(), **failure.metadata())

        def run(model: str, retry: bool = False) -> tuple[bool, Any]:
            nonlocal started_revision
            if self.cache:
                health, started_revision = self.cache.attempt_snapshot(model, now=self.clock())
                if health.get("state") == "temporary":
                    failure = Failure.from_health(health)
                    remember(model, failure)
                    return False, None
                if health.get("failure_kind") == "credentials":
                    raise ModelAttemptError.from_failure(Failure.from_health(health))
            attempted.add(model)
            try:
                return True, accept(model, attempt(model, retry))
            except Exception as error:
                if getattr(error, "superseded_instructions", False):
                    # The current provider request reached its terminal state,
                    # but its decision is stale. Do not repair or query a sibling.
                    raise
                failure = classify_failure(error, self.clock(), model)
                if failure.provider_retries is not None and not failure.provider_retries_counted:
                    self.metrics["provider_retries"] = (self.metrics["provider_retries"] or 0) + failure.provider_retries
                if failure.kind in {"credentials", "cancelled", "transport", "configuration"}:
                    if self.cache: self.cache.record_failure(model, failure)
                    for other in ALL_MODELS:
                        if other != model: self.emit("model_health", model=other, state="configured", detail="Runtime verification invalidated")
                    self.emit("model_health", model=model, state="repair", detail=failure.summary(), **failure.metadata())
                    raise
                remember(model, failure)
                for item in failure.attempts:
                    prior = Failure.from_health(item)
                    prior.recovered_upstream = True
                    if not prior.model and not (prior.scope == "credential" and prior.provider == model.split('/', 1)[0]):
                        continue
                    route = model_route(prior, model)
                    if route in ALL_MODELS:
                        remember(route, prior, upstream=True)
                        if prior.kind in {"credentials", "cancelled", "transport", "configuration"}:
                            raise ModelAttemptError.from_failure(prior) from error
                return False, None

        def first_pass() -> tuple[bool, Any]:
            for model in order:
                if model in attempted or model in exhausted or model in self.unavailable or shared(model) or self.cooldowns.get(model, 0) > self.clock():
                    continue
                success, result = run(model)
                if success: return True, result
            return False, None

        success, result = first_pass()
        if success: return result
        # All eligible candidates get one attempt; two shared Lite retries remain.
        while delayed and retries < 2:
            model, failure = delayed.pop(0)
            if model in self.unavailable or model in exhausted: continue
            block = shared(model)
            if block and block is not failure: continue
            deadline = max(failure.retry_at, self.cooldowns.get(model, 0), block.retry_at if block else 0)
            if not math.isfinite(deadline): continue
            delay = max(0, deadline - self.clock())
            if delay:
                if failure.kind == "quota":
                    waiting_for = ("The provider account’s quota reset" if failure.scope == "credential"
                                   else "The selected model’s quota reset")
                else:
                    waiting_for = ("The provider account’s capacity cooldown" if failure.scope == "credential"
                                   else "The selected model’s capacity cooldown")
                self.emit("wait_phase", phase="provider_cooldown",
                          waiting_for=waiting_for)
                self.emit("status", message=f"Waiting {delay:g}s for the reported provider cooldown…")
                self.sleep(delay)
                if self.clock() < deadline: break  # An interrupted wait must not bypass the cooldown.
            retries += 1
            success, result = run(model, retry=True)
            if success: return result
            # A shared limit may have expired and become a model-specific error.
            # Try previously blocked siblings only after that shared block ends.
            success, result = first_pass()
            if success: return result
        for model in order:
            if not failures and self.cooldowns.get(model, 0) > self.clock():
                failures.append((model, self.model_failures.get(model, Failure("temporary", "Provider cooldown is active", self.cooldowns[model]))))
        raise RecoveryExhaustedError(failures)


# Stable lock files are never replaced. The data file is replaced only while
# holding the lock; readers and writers always reload inside that transaction.
_configuration_local = threading.local()


def runtime_state_root() -> Path:
    return Path(os.environ.get("ORBIT_RUNTIME_STATE_DIRECTORY", str(Path.home() / "Library/Application Support/Orbit Agent")))


class PrivateLockIdentityError(RuntimeError):
    code = "private_lock_identity_mismatch"

    def __init__(self):
        super().__init__(self.code)


def private_lock_identity(path: Path, descriptor: int) -> tuple[int, int, int]:
    try:
        opened = os.fstat(descriptor)
        named = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise PrivateLockIdentityError() from error
    if (not stat.S_ISREG(opened.st_mode) or not stat.S_ISREG(named.st_mode) or
            opened.st_uid != os.getuid() or named.st_uid != os.getuid() or
            opened.st_nlink != 1 or named.st_nlink != 1 or
            (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)):
        raise PrivateLockIdentityError()
    return opened.st_dev, opened.st_ino, opened.st_uid


def sync_state_directory(path: Path) -> None:
    """Persist a readiness-state rename without following a directory symlink."""
    flags = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
             getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        try:
            named = os.stat(path, follow_symlinks=False)
        except OSError as error:
            raise OSError(errno.EIO, "runtime state directory changed during persistence") from error
        if (not stat.S_ISDIR(opened.st_mode) or not stat.S_ISDIR(named.st_mode) or
                opened.st_uid != os.getuid() or named.st_uid != os.getuid() or
                (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)):
            raise OSError(errno.EIO, "runtime state directory changed during persistence")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class ReadinessStateError(RuntimeError):
    """Fixed, payload-free failure for damaged or replaced private cache state."""

    code = "local_resource_readiness_state"

    def __init__(self) -> None:
        super().__init__("TaskPilot local readiness state is invalid or unavailable.")


def _freeze_readiness_value(value: Any) -> Any:
    if isinstance(value, dict):
        return MappingProxyType({key: _freeze_readiness_value(item) for key, item in value.items()})
    if isinstance(value, (list, tuple)):
        return tuple(_freeze_readiness_value(item) for item in value)
    return value


def _thaw_readiness_value(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {key: _thaw_readiness_value(item) for key, item in value.items()}
    if isinstance(value, tuple):
        return [_thaw_readiness_value(item) for item in value]
    return value


@dataclass(frozen=True)
class ReadinessSnapshot:
    """Immutable view used for one candidate-selection decision."""

    revision: int
    verified_model: str | None
    model_failures: Mapping[str, Any]
    account_cooldowns: Mapping[str, Any]
    invalidated_revision: int
    invalidations: Mapping[str, Any]
    wall_now: float

    def credential_health(self, model: str) -> dict[str, Any]:
        provider = model.split('/', 1)[0]
        value = self.account_cooldowns.get(provider, {})
        return RuntimeState.current_health(_thaw_readiness_value(value), self.wall_now)

    def health(self, model: str) -> dict[str, Any]:
        account = self.credential_health(model)
        if account:
            return account
        value = self.model_failures.get(model, {})
        return RuntimeState.current_health(_thaw_readiness_value(value), self.wall_now)

    def attempt_snapshot(self, model: str) -> tuple[dict[str, Any], int]:
        return self.health(model), self.revision


def _readiness_file_signature(info: os.stat_result) -> tuple[int, ...]:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def _finite_json_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError("non-finite JSON number")
    return parsed


def _reject_json_constant(_value: str) -> None:
    raise ValueError("non-standard JSON constant")


def _validate_readiness_shape(document: Any) -> dict[str, Any]:
    """Reject malformed cache structure rather than normalizing away cooldowns."""
    if not isinstance(document, dict):
        raise ValueError("readiness root must be an object")
    revision = document.get("revision")
    if "revision" in document and (type(revision) is not int or revision < 0):
        raise ValueError("invalid readiness revision")
    configurations = document.get("configurations")
    if "configurations" in document and not isinstance(configurations, dict):
        raise ValueError("invalid configuration versions")

    if "credentials" not in document:
        # Legacy top-level state remains readable, but its structures must be
        # intact before a migration can preserve them.
        for field in ("health", "credential_health", "verified"):
            value = document.get(field)
            if field in document and not isinstance(value, dict):
                raise ValueError("invalid legacy readiness structure")
        return document
    credentials = document["credentials"]
    if not isinstance(credentials, dict):
        raise ValueError("invalid credential namespaces")

    def require_mapping(owner: dict[str, Any], field: str) -> dict[str, Any] | None:
        value = owner.get(field)
        if field in owner and not isinstance(value, dict):
            raise ValueError("invalid readiness mapping")
        return value

    for bucket in credentials.values():
        if not isinstance(bucket, dict):
            raise ValueError("invalid credential record")
        for field in ("health", "credential_health", "records", "managed_health"):
            require_mapping(bucket, field)
        for field in ("health", "credential_health"):
            entries = bucket.get(field, {})
            if isinstance(entries, dict) and any(not isinstance(item, dict) for item in entries.values()):
                raise ValueError("invalid cooldown record")
        managed = bucket.get("managed_health", {})
        if isinstance(managed, dict):
            for health in managed.values():
                if not isinstance(health, dict) or any(not isinstance(item, dict) for item in health.values()):
                    raise ValueError("invalid managed cooldown record")
        records = bucket.get("records", {})
        if isinstance(records, dict):
            for record in records.values():
                if not isinstance(record, dict):
                    raise ValueError("invalid verification record")
                for field in ("verified", "verification_clocks", "invalidations"):
                    require_mapping(record, field)
    return document


def _read_readiness_state(path: Path) -> tuple[dict[str, Any], tuple[int, ...] | None]:
    """Read one stable, bounded regular file without following a replacement symlink."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        try:
            os.stat(path, follow_symlinks=False)
        except FileNotFoundError:
            return {}, None
        except OSError:
            raise ReadinessStateError() from None
        raise ReadinessStateError() from None
    except OSError:
        raise ReadinessStateError() from None

    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or
                before.st_nlink != 1 or before.st_size < 0 or
                before.st_size > READINESS_STATE_MAX_BYTES):
            raise ReadinessStateError()

        chunks: list[bytes] = []
        total = 0
        while total <= READINESS_STATE_MAX_BYTES:
            chunk = os.read(descriptor, min(64 * 1024, READINESS_STATE_MAX_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > READINESS_STATE_MAX_BYTES:
            raise ReadinessStateError()

        after = os.fstat(descriptor)
        try:
            named = os.stat(path, follow_symlinks=False)
        except OSError:
            raise ReadinessStateError() from None
        signature = _readiness_file_signature(before)
        if (_readiness_file_signature(after) != signature or
                _readiness_file_signature(named) != signature or total != after.st_size or
                not stat.S_ISREG(named.st_mode)):
            raise ReadinessStateError()

        try:
            raw = b"".join(chunks).decode("utf-8")
            document = json.loads(raw, object_pairs_hook=_unique_json_object,
                                  parse_float=_finite_json_float, parse_constant=_reject_json_constant)
            return _validate_readiness_shape(document), signature
        except (UnicodeError, ValueError, TypeError, RecursionError, OverflowError):
            raise ReadinessStateError() from None
    except ReadinessStateError:
        raise
    except (OSError, ValueError, TypeError, OverflowError):
        raise ReadinessStateError() from None
    finally:
        os.close(descriptor)


def _verify_readiness_path(path: Path, expected: tuple[int, ...] | None) -> None:
    """Ensure a transaction has not been redirected to a different state file."""
    try:
        named = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        if expected is None:
            return
        raise ReadinessStateError() from None
    except OSError:
        raise ReadinessStateError() from None
    if (expected is None or not stat.S_ISREG(named.st_mode) or named.st_uid != os.getuid() or
            named.st_nlink != 1 or _readiness_file_signature(named) != expected):
        raise ReadinessStateError()


def _check_lease_state(root: Path, identity: str) -> bool | None:
    """Return False only when no active lease is established; uncertainty retains state."""
    if not isinstance(identity, str) or not _READINESS_IDENTITY.fullmatch(identity):
        return None
    path = root / ("readiness-" + identity + ".lock")
    flags = (os.O_RDWR | os.O_CLOEXEC | os.O_NONBLOCK |
             getattr(os, "O_NOFOLLOW", 0))
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        return False
    except OSError:
        return None
    try:
        try:
            opened_identity = private_lock_identity(path, descriptor)
        except (OSError, PrivateLockIdentityError):
            return None
        try:
            # This is a nonblocking lease probe while the state lock is held;
            # it never waits on the lower-ranked single-flight lock.
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        except OSError:
            return None
        try:
            if private_lock_identity(path, descriptor) != opened_identity:
                return None
            return False
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def _any_active_check_lease(root: Path) -> bool:
    """Bounded conservative scan used before pruning installation health namespaces."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(root, flags | getattr(os, "O_DIRECTORY", 0))
    except OSError:
        return True
    try:
        with os.scandir(descriptor) as entries:
            inspected = scanned = 0
            for entry in entries:
                scanned += 1
                if scanned > READINESS_PRUNE_MAX_DIRECTORY_ENTRIES:
                    return True
                if not entry.name.startswith("readiness-") or not entry.name.endswith(".lock"):
                    continue
                inspected += 1
                if inspected > READINESS_PRUNE_MAX_LEASE_SCAN:
                    return True
                identity = entry.name[len("readiness-"):-len(".lock")]
                state = _check_lease_state(root, identity)
                if state is not False:
                    return True
        return False
    except OSError:
        return True
    finally:
        os.close(descriptor)


def _rollback_readiness_protection(root: Path, cache: dict | None = None) -> tuple[set[str], set[str], set[str], bool]:
    """Return rollback credential, record, and managed-health keys plus uncertainty.

    This reads only the one known TaskPilot descriptor and its two referenced
    metadata files. It never scans profiles. If any identity cannot be proved,
    the caller retains all candidate records rather than guessing.
    """
    descriptor_path = root / "ManagedOpenClaw" / "previous-runtime.json"

    def signature(path: Path):
        try:
            info = os.stat(path, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1):
            raise OSError("rollback metadata identity is uncertain")
        return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
                info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

    if cache is not None and cache.get("paths"):
        try:
            signatures = tuple(signature(path) for path in cache["paths"])
            if signatures == cache.get("signatures"):
                return cache["values"]
        except (OSError, TypeError):
            pass
        cache.clear()

    try:
        descriptor_signature = signature(descriptor_path)
    except FileNotFoundError:
        descriptor_signature = None
    except OSError:
        return set(), set(), set(), True
    if descriptor_signature is None:
        values = (set(), set(), set(), False)
        if cache is not None:
            cache.update(paths=(descriptor_path,), signatures=(None,), values=values)
        return values
    try:
        import private_runtime_metadata as private_metadata
        import runtime_descriptor_generated as descriptor_contract

        descriptor = descriptor_contract.parse_descriptor(
            private_metadata.read_bytes(descriptor_path, private_metadata.DESCRIPTOR_BYTES),
            descriptor_path.parent)
        managed = ":".join((descriptor["instance_id"], descriptor["installation_fingerprint"],
                            descriptor["configuration_fingerprint"]))
        managed_key = hashlib.sha256(managed.encode()).hexdigest()
        state_path = Path(descriptor["state"])
        key_path = state_path / "credential-fingerprint.json"
        config_path = Path(descriptor["config"])
        paths = (descriptor_path, key_path, config_path)
        before = tuple(signature(path) for path in paths)
        if before[0] != descriptor_signature:
            return set(), set(), set(), True
        key_record = private_metadata.read(key_path, 4096)
        source_fingerprint = key_record.get("fingerprint")
        if not isinstance(source_fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", source_fingerprint):
            return set(), set(), {managed_key}, True
        credential = hashlib.sha256(source_fingerprint.encode()).hexdigest()
        config = private_metadata.read(config_path, private_metadata.CONFIGURATION_BYTES)
        defaults = config.get("agents", {}).get("defaults", {})
        if not isinstance(defaults, dict):
            return {credential}, set(), {managed_key}, True
        settings = {key: defaults.get(key) for key in ("model", "modelPolicy", "imageModel", "models")}
        model_configuration = hashlib.sha256(json.dumps(settings, sort_keys=True).encode()).hexdigest()
        runtime_version = "OpenClaw " + descriptor["openclaw_version"]
        record_identity = hashlib.sha256(json.dumps([
            source_fingerprint, runtime_version, CONFIG_VERSION, ALL_MODELS,
            model_configuration, VALIDATION_VERSION, CONTRACT_HASH, ERROR_POLICY_VERSION, managed,
        ]).encode()).hexdigest()
        after = tuple(signature(path) for path in paths)
        if before != after:
            return set(), set(), set(), True
        values = ({credential}, {record_identity}, {managed_key}, False)
        if cache is not None:
            cache.update(paths=paths, signatures=after, values=values)
        return values
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError):
        # On any path, parse, or identity uncertainty, retain every candidate.
        return set(), set(), set(), True


def _expired_verification(value: Any, now: float) -> bool:
    # Booleans, malformed values, future timestamps, and clock anomalies are
    # retained. Only a finite, non-boolean timestamp past the known TTL expires.
    try:
        return (type(value) in (int, float) and math.isfinite(now) and math.isfinite(value) and
                value <= now and now - value >= VERIFICATION_CACHE_SECONDS)
    except (OverflowError, ValueError):
        return False


def _verification_cache_status(value: Any, clock: Any, *, wall_now: float,
                               monotonic_now: float, boot_session: str | None) -> str:
    """Classify a success stamp without letting wall-clock changes extend it.

    Wall time is retained for compatibility and diagnostics. A cache hit is
    authorized only when the stamp is complete, belongs to this boot session,
    and its monotonic age is within the cache TTL. Unknown or discontinuous
    clocks require a fresh verification but are retained by pruning.
    """
    if not all(_finite_number(item) for item in (value, wall_now, monotonic_now)):
        return "uncertain"
    if (not isinstance(clock, dict) or type(clock.get("version")) is not int or
            clock.get("version") != VERIFICATION_CLOCK_VERSION):
        return "uncertain"
    stamp_boot = clock.get("boot_session")
    stamp_wall = clock.get("wall")
    stamp_monotonic = clock.get("monotonic")
    if (not isinstance(boot_session, str) or not boot_session or len(boot_session) > 128 or
            stamp_boot != boot_session or type(stamp_wall) not in (int, float) or
            not _finite_number(stamp_wall) or not _finite_number(stamp_monotonic) or
            stamp_monotonic < 0 or stamp_wall != value):
        return "uncertain"
    elapsed = monotonic_now - stamp_monotonic
    if not math.isfinite(elapsed) or elapsed < 0:
        return "uncertain"
    if elapsed >= VERIFICATION_CACHE_SECONDS:
        return "expired"
    return "fresh"


def _expired_temporary_failure(value: Any, now: float) -> bool:
    if not isinstance(value, dict) or value.get("state") != "temporary":
        return False
    retry_at = value.get("retry_at")
    # Null means no reset was supplied and is an indefinite restriction.
    try:
        return (type(retry_at) in (int, float) and math.isfinite(now) and
                math.isfinite(retry_at) and retry_at <= now)
    except (OverflowError, ValueError):
        return False


def _bounded_items(mapping: dict, limit: int):
    """Copy at most limit entries so mutation never requires an unbounded key list."""
    if limit <= 0:
        return []
    result = []
    for item in mapping.items():
        result.append(item)
        if len(result) >= limit:
            break
    return result


def _rotate_items(mapping: dict, items: list[tuple[Any, Any]]) -> None:
    """Move visited entries behind unvisited entries without scanning the map."""
    for key, value in items:
        if key in mapping:
            mapping.pop(key)
            mapping[key] = value


def _prune_readiness_document(document: dict[str, Any], state: "RuntimeState", now: float,
                             monotonic_now: float, boot_session: str | None) -> None:
    """Bounded, conservative cleanup performed only while the state write lock is held."""
    credentials = document.get("credentials")
    if not isinstance(credentials, dict):
        return
    rollback_credentials, rollback_records, rollback_managed, rollback_unknown = \
        _rollback_readiness_protection(state.root, state._rollback_protection_cache)
    any_active_lease = _any_active_check_lease(state.root)
    current_managed = hashlib.sha256(state.managed_configuration.encode()).hexdigest() if state.managed_configuration else None

    (examined_records, examined_verification, examined_health,
     examined_managed_namespaces, examined_managed_health) = (0, 0, 0, 0, 0)
    credential_slice = _bounded_items(credentials, READINESS_PRUNE_MAX_CREDENTIALS)
    for credential, bucket in credential_slice:
        if not isinstance(bucket, dict):
            continue
        current_credential = credential == state.credential

        # Verification records are scoped by the complete runtime identity. A
        # current or rollback installation is never pruned, even if its cache
        # timestamp is old. Active/uncertain check leases also retain records.
        records = bucket.get("records")
        if isinstance(records, dict) and not rollback_unknown:
            remaining = READINESS_PRUNE_MAX_IDENTITIES - examined_records
            if remaining > 0:
                record_slice = _bounded_items(records, remaining)
                examined_records += len(record_slice)
            else:
                record_slice = []
            for identity, record in record_slice:
                if identity == state.identity or identity in rollback_records or not isinstance(record, dict):
                    continue
                if _check_lease_state(state.root, identity) is not False:
                    continue
                verified = record.get("verified")
                if isinstance(verified, dict) and examined_verification < READINESS_PRUNE_MAX_HEALTH_RECORDS:
                    remaining_health = READINESS_PRUNE_MAX_HEALTH_RECORDS - examined_verification
                    verification_slice = _bounded_items(verified, remaining_health)
                    clocks = record.get("verification_clocks")
                    for model, timestamp in verification_slice:
                        examined_verification += 1
                        if isinstance(clocks, dict) and model in clocks:
                            expired = _verification_cache_status(
                                timestamp, clocks[model], wall_now=now,
                                monotonic_now=monotonic_now, boot_session=boot_session) == "expired"
                        elif "verification_clocks" not in record or isinstance(clocks, dict):
                            # Legacy entries are never accepted as cache hits;
                            # their wall time is used only to reclaim clearly old data.
                            expired = _expired_verification(timestamp, now)
                        else:
                            expired = False
                        if expired:
                            verified.pop(model, None)
                            if isinstance(clocks, dict):
                                clocks.pop(model, None)
                    _rotate_items(verified, verification_slice)
                    if not verified:
                        record.pop("verified", None)
                    if isinstance(clocks, dict) and not clocks:
                        record.pop("verification_clocks", None)
                # Keep invalidation markers, single-flight results, and any
                # unknown future fields. Delete only a cache-only empty shell.
                if not record:
                    records.pop(identity, None)
            _rotate_items(records, record_slice)

        # Account-wide health is intentionally never pruned here. In particular,
        # retry_at:null encodes an indefinite quota restriction. Model health is
        # trimmed only after its explicit finite cooldown has expired.
        if not any_active_lease:
            health = bucket.get("health")
            if isinstance(health, dict) and examined_health < READINESS_PRUNE_MAX_HEALTH_RECORDS:
                remaining_health = READINESS_PRUNE_MAX_HEALTH_RECORDS - examined_health
                health_slice = _bounded_items(health, remaining_health)
                for model, failure in health_slice:
                    examined_health += 1
                    if _expired_temporary_failure(failure, now):
                        health.pop(model, None)
                _rotate_items(health, health_slice)
            managed_health = bucket.get("managed_health")
            if (isinstance(managed_health, dict) and not rollback_unknown and
                    examined_managed_namespaces < READINESS_PRUNE_MAX_HEALTH_RECORDS):
                remaining_namespaces = READINESS_PRUNE_MAX_HEALTH_RECORDS - examined_managed_namespaces
                managed_slice = _bounded_items(managed_health, remaining_namespaces)
                examined_managed_namespaces += len(managed_slice)
                for managed_key, health_records in managed_slice:
                    if examined_managed_health >= READINESS_PRUNE_MAX_HEALTH_RECORDS:
                        break
                    if managed_key == current_managed or managed_key in rollback_managed:
                        continue
                    if not isinstance(health_records, dict):
                        continue
                    if examined_managed_health >= READINESS_PRUNE_MAX_HEALTH_RECORDS:
                        continue
                    remaining_health = READINESS_PRUNE_MAX_HEALTH_RECORDS - examined_managed_health
                    health_slice = _bounded_items(health_records, remaining_health)
                    for model, failure in health_slice:
                        examined_managed_health += 1
                        if _expired_temporary_failure(failure, now):
                            health_records.pop(model, None)
                    if not health_records:
                        managed_health.pop(managed_key, None)
                    _rotate_items(health_records, health_slice)
                _rotate_items(managed_health, managed_slice)

        # Remove only an entirely empty obsolete bucket. Unknown fields,
        # invalidation markers, credential health, and cooldowns keep it alive.
        if not current_credential and credential not in rollback_credentials:
            for field in ("records", "managed_health", "health", "credential_health"):
                value = bucket.get(field)
                if isinstance(value, dict) and not value:
                    bucket.pop(field, None)
            if not bucket:
                credentials.pop(credential, None)
    _rotate_items(credentials, credential_slice)


@contextmanager
def private_lock(path: Path, *, blocking=True, category=LockCategory.STATE):
    with reserve(category) as rank:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC |
                                 getattr(os, "O_NOFOLLOW", 0), 0o600)
        except OSError as error:
            if error.errno == errno.ELOOP:
                raise PrivateLockIdentityError() from error
            raise
        try:
            identity = private_lock_identity(path, descriptor)
            os.fchmod(descriptor, 0o600)
            with rank.waiting():
                fcntl.flock(descriptor, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            if private_lock_identity(path, descriptor) != identity:
                raise PrivateLockIdentityError()
            try:
                yield descriptor
            finally:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


@contextmanager
def configuration_transaction(*, blocking=True):
    """Shared with the native setup/probe coordinator; nested calls are local."""
    if getattr(_configuration_local, "owned", False):
        yield _configuration_local.descriptor
        return
    with private_lock(runtime_state_root() / "openclaw-configuration.lock", blocking=blocking,
                      category=LockCategory.CONFIGURATION) as descriptor:
        _configuration_local.owned = True
        _configuration_local.descriptor = descriptor
        try:
            yield descriptor
        finally:
            _configuration_local.owned = False
            _configuration_local.descriptor = None


class RuntimeState:
    """Short cross-process transactions; no plaintext user/provider data."""
    def __init__(self, fingerprint: str, version: str, root: Path | None = None, configuration: str = "") -> None:
        self.source_fingerprint = fingerprint
        self.root = root or runtime_state_root()
        self.path = self.root / "runtime-readiness.json"
        self.credential = hashlib.sha256(fingerprint.encode()).hexdigest()
        self.managed_configuration = os.environ.get("TASKPILOT_MANAGED_FINGERPRINT", "")
        self.identity = hashlib.sha256(json.dumps([fingerprint, version, CONFIG_VERSION, ALL_MODELS, configuration, VALIDATION_VERSION, CONTRACT_HASH, ERROR_POLICY_VERSION, os.environ.get("TASKPILOT_MANAGED_FINGERPRINT", "")]).encode()).hexdigest()
        configuration_path = os.path.abspath(os.path.expanduser(os.environ.get("OPENCLAW_CONFIG_PATH", "~/.openclaw/openclaw.json")))
        self.configuration_key = hashlib.sha256(configuration_path.encode()).hexdigest()
        self.value: dict[str, Any] = {}
        self._rollback_protection_cache: dict[str, Any] = {}
        self.refresh()

    def rebind_managed(self, version: str, configuration: str) -> None:
        if self.managed_configuration != os.environ.get("TASKPILOT_MANAGED_FINGERPRINT", ""):
            # Retain the credential namespace/cooldowns, but never verify a new
            # installation under the previous descriptor's cache identity.
            self.__init__(self.source_fingerprint, version, root=self.root, configuration=configuration)

    def model_health_records(self, bucket):
        # Local catalog/config faults from another managed installation must
        # not label untested models unavailable after a configuration repair.
        # Credential-wide cooldowns retain their shared account namespace.
        if self.managed_configuration:
            key = hashlib.sha256(self.managed_configuration.encode()).hexdigest()
            return bucket.setdefault("managed_health", {}).setdefault(key, {})
        return bucket["health"]

    @contextmanager
    def transaction(self, *, write: bool = False):
        with private_lock(self.root / "runtime-readiness.lock"):
            document, state_identity = _read_readiness_state(self.path)
            # Migrate only the matching old verification identity. Old cooldowns
            # had no credential namespace and cannot safely transfer to a new key.
            if "credentials" not in document:
                old = document
                document = {"revision": 0, "config_version": old.get("config_version"), "credentials": {}}
                if old.get("identity") == self.identity:
                    document["credentials"][self.credential] = {
                        "health": old.get("health", {}), "credential_health": old.get("credential_health", {}),
                        "records": {self.identity: {"verified": old.get("verified", {})}}}
            bucket = document.setdefault("credentials", {}).setdefault(self.credential, {})
            for field in ("health", "credential_health", "records"):
                if not isinstance(bucket.get(field), dict): bucket[field] = {}
            record = bucket["records"].setdefault(self.identity, {})
            if not isinstance(record.get("verified"), dict): record["verified"] = {}
            self.value = {**record, "health": self.model_health_records(bucket), "credential_health": bucket["credential_health"],
                          "config_version": document.get("configurations", {}).get(self.configuration_key), "revision": document.get("revision", 0)}
            yield document, bucket, record
            if write:
                # Best-effort and strictly bounded. Any uncertain descriptor,
                # lease, timestamp, or quota state is retained by the pruner.
                _prune_readiness_document(document, self, time.time(), time.monotonic(),
                                          _boot_session_marker())
                document["revision"] = int(document.get("revision", 0)) + 1
                self.value["revision"] = document["revision"]
                fd, name = tempfile.mkstemp(prefix=".runtime-readiness-", dir=self.root)
                try:
                    with os.fdopen(fd, "w") as output:
                        json.dump(document, output, allow_nan=False)
                        output.flush()
                        os.fsync(output.fileno())
                    _verify_readiness_path(self.path, state_identity)
                    os.replace(name, self.path)
                    sync_state_directory(self.root)
                finally:
                    if os.path.exists(name): os.unlink(name)

    def refresh(self) -> int:
        with self.transaction():
            return self.value["revision"]

    def configuration_version(self) -> Any:
        with self.transaction():
            return self.value.get("config_version")

    def configuration_updated(self) -> None:
        with self.transaction(write=True) as (document, _, __):
            document.setdefault("configurations", {})[self.configuration_key] = CONFIG_VERSION
            for bucket in document["credentials"].values():
                for record in bucket.get("records", {}).values():
                    record["verified"] = {}
                    record["verification_clocks"] = {}
                    record.setdefault("invalidations", {})["*"] = document.get("revision", 0) + 1

    def _verify(self, model: str, started_revision: int | None = None, *, now: float | None = None,
                monotonic_now: float | None = None, boot_session: str | None = None,
                include_snapshot: bool = False) -> bool | tuple[bool, ReadinessSnapshot]:
        with self.transaction(write=True) as (document, bucket, record):
            wall_now = time.time() if now is None else now
            monotonic_stamp = time.monotonic() if monotonic_now is None else monotonic_now
            boot_stamp = _boot_session_marker() if boot_session is None else boot_session
            # An old success must never erase a failure observed after it began.
            boundary = document.get("revision", 0) if started_revision is None else started_revision
            invalidations = record.get("invalidations", {})
            blocked = max(bucket.get("invalidated_revision", 0), invalidations.get("*", 0),
                          invalidations.get(model, 0)) > boundary
            if not blocked:
                for field, key in (("health", model), ("credential_health", model.split('/', 1)[0])):
                    failure = (self.model_health_records(bucket) if field == "health" else bucket[field]).get(key, {})
                    if failure and (failure.get("revision", 0) > boundary or
                        (failure.get("state") == "temporary" and failure.get("retry_at") is not None and failure["retry_at"] > wall_now)):
                        blocked = True
                        break
            if not blocked:
                self.model_health_records(bucket).pop(model, None)
                bucket["credential_health"].pop(model.split('/', 1)[0], None)
                clocks = record.setdefault("verification_clocks", {})
                if not isinstance(clocks, dict):
                    clocks = record["verification_clocks"] = {}
                valid_clock = (_finite_number(wall_now) and _finite_number(monotonic_stamp) and
                               monotonic_stamp >= 0 and isinstance(boot_stamp, str) and
                               0 < len(boot_stamp) <= 128)
                if valid_clock:
                    record["verified"][model] = wall_now
                    clocks[model] = {"version": VERIFICATION_CLOCK_VERSION, "boot_session": boot_stamp,
                                     "wall": wall_now, "monotonic": monotonic_stamp}
                else:
                    # The provider result is successful, but an uncertain local clock
                    # must not authorize a cache hit on a later readiness request.
                    record["verified"].pop(model, None)
                    clocks.pop(model, None)
            accepted = not blocked
        if include_snapshot:
            return accepted, self._snapshot_from_state(
                document, bucket, record, now=wall_now, monotonic_now=monotonic_stamp,
                boot_session=boot_stamp)
        return accepted

    def verify(self, model: str, started_revision: int | None = None, *, now: float | None = None,
               monotonic_now: float | None = None, boot_session: str | None = None) -> bool:
        return bool(self._verify(model, started_revision, now=now, monotonic_now=monotonic_now,
                                 boot_session=boot_session))

    def verify_with_snapshot(self, model: str, started_revision: int | None = None, *, now: float | None = None,
                             monotonic_now: float | None = None,
                             boot_session: str | None = None) -> tuple[bool, ReadinessSnapshot]:
        result = self._verify(model, started_revision, now=now, monotonic_now=monotonic_now,
                              boot_session=boot_session, include_snapshot=True)
        assert isinstance(result, tuple)
        return result

    def invalidate(self, model: str | None = None) -> None:
        with self.transaction(write=True) as (document, _, record):
            record.setdefault("invalidations", {})[model or "*"] = document.get("revision", 0) + 1
            if model:
                record["verified"].pop(model, None)
                clocks = record.get("verification_clocks")
                if isinstance(clocks, dict):
                    clocks.pop(model, None)
                    if not clocks:
                        record.pop("verification_clocks", None)
            else:
                record["verified"].clear()
                record.pop("verification_clocks", None)

    def record_failure(self, model: str, failure: Failure) -> dict[str, Any]:
        with self.transaction(write=True) as (document, bucket, record):
            health = {"state": "temporary" if failure.kind in {"quota", "temporary"} else "repair",
                      "detail": failure.summary(), **failure.metadata(), "revision": document.get("revision", 0) + 1}
            shared = failure.kind == "credentials" or (failure.scope == "credential" and failure.kind in {"quota", "temporary"})
            if failure.kind in {"credentials", "transport", "configuration"}:
                bucket["invalidated_revision"] = health["revision"]
            field, key = ("credential_health", failure.provider or model.split('/', 1)[0]) if shared else ("health", model)
            health_records = self.model_health_records(bucket) if field == "health" else bucket[field]
            current = health_records.get(key, {})
            # Shorter concurrent cooldowns cannot erase a longer applicable one.
            if current.get("state") == "temporary" and health["state"] == "temporary" and Failure.from_health(current).retry_at > failure.retry_at:
                health = {**current, "revision": health["revision"]}
            health_records[key] = health
            for other_record in bucket["records"].values():
                verified = other_record.setdefault("verified", {})
                clocks = other_record.get("verification_clocks")
                if failure.kind in {"credentials", "transport", "configuration"}:
                    verified.clear()
                    other_record.pop("verification_clocks", None)
                elif shared:
                    for other in list(verified):
                        if other.startswith(key + '/'):
                            verified.pop(other, None)
                            if isinstance(clocks, dict):
                                clocks.pop(other, None)
                    if isinstance(clocks, dict) and not clocks:
                        other_record.pop("verification_clocks", None)
                else:
                    verified.pop(model, None)
                    if isinstance(clocks, dict):
                        clocks.pop(model, None)
                        if not clocks:
                            other_record.pop("verification_clocks", None)
            return dict(health_records[key])

    @staticmethod
    def current_health(result: Any, now: float | None = None) -> dict[str, Any]:
        if not isinstance(result, dict): return {}
        if result.get("state") == "temporary" and result.get("retry_at") and result["retry_at"] <= (time.time() if now is None else now): return {}
        return result

    def credential_health(self, model: str, *, now: float | None = None) -> dict[str, Any]:
        with self.transaction():
            return self.current_health(self.value.get("credential_health", {}).get(model.split('/', 1)[0], {}), now)

    def attempt_snapshot(self, model: str, *, now: float | None = None) -> tuple[dict[str, Any], int]:
        with self.transaction():
            provider = model.split('/', 1)[0]
            health = self.current_health(self.value["credential_health"].get(provider, {}), now) or self.current_health(self.value["health"].get(model, {}), now)
            return health, self.value["revision"]

    def health_snapshot(self, *, now: float | None = None) -> dict[str, dict[str, Any]]:
        with self.transaction():
            return {model: self.current_health(self.value["credential_health"].get(model.split('/', 1)[0], {}), now) or
                           self.current_health(self.value["health"].get(model, {}), now) for model in ALL_MODELS}

    def health(self, model: str, *, now: float | None = None) -> dict[str, Any]:
        return self.attempt_snapshot(model, now=now)[0]

    def _snapshot_from_state(self, document: dict[str, Any], bucket: dict[str, Any], record: dict[str, Any], *,
                             now: float, monotonic_now: float, boot_session: str | None) -> ReadinessSnapshot:
        models = self.model_health_records(bucket)
        account = bucket.get("credential_health", {})
        verified = record.get("verified", {})
        clocks = record.get("verification_clocks", {})
        model_failures = {model: models.get(model, {}) for model in ALL_MODELS}
        providers = {model.split('/', 1)[0] for model in ALL_MODELS}
        account_cooldowns = {provider: account.get(provider, {}) for provider in providers}

        cached_model = None
        if isinstance(verified, dict):
            for model in ALL_MODELS:
                provider = model.split('/', 1)[0]
                if (self.current_health(account_cooldowns.get(provider, {}), now) or
                        self.current_health(model_failures.get(model, {}), now)):
                    continue
                clock = clocks.get(model) if isinstance(clocks, dict) else None
                if _verification_cache_status(
                        verified.get(model), clock, wall_now=now,
                        monotonic_now=monotonic_now, boot_session=boot_session) == "fresh":
                    cached_model = model
                    break

        revision = document.get("revision", 0)
        invalidated_revision = bucket.get("invalidated_revision", 0)
        if type(revision) is not int:
            revision = 0
        if type(invalidated_revision) is not int:
            invalidated_revision = -1
        invalidations = record.get("invalidations", {})
        if not isinstance(invalidations, dict):
            invalidations = {"malformed": True}
        return ReadinessSnapshot(
            revision=revision,
            verified_model=cached_model,
            model_failures=_freeze_readiness_value(model_failures),
            account_cooldowns=_freeze_readiness_value(account_cooldowns),
            invalidated_revision=invalidated_revision,
            invalidations=_freeze_readiness_value(invalidations),
            wall_now=now,
        )

    def readiness_snapshot(self, *, now: float | None = None, monotonic_now: float | None = None,
                           boot_session: str | None = None) -> ReadinessSnapshot:
        """Read cache and failure policy once for a consistent readiness decision."""
        with self.transaction() as (document, bucket, record):
            wall_now = time.time() if now is None else now
            monotonic_stamp = time.monotonic() if monotonic_now is None else monotonic_now
            boot_stamp = _boot_session_marker() if boot_session is None else boot_session
            return self._snapshot_from_state(document, bucket, record, now=wall_now,
                                             monotonic_now=monotonic_stamp, boot_session=boot_stamp)

    def verified_model(self, *, now: float | None = None, monotonic_now: float | None = None,
                       boot_session: str | None = None) -> str | None:
        return self.readiness_snapshot(now=now, monotonic_now=monotonic_now,
                                       boot_session=boot_session).verified_model

    def check_revision(self) -> int:
        with self.transaction():
            return self.value.get("check_revision", 0)

    @contextmanager
    def explicit_check(self):
        # Followers reuse the leader's terminal result, including a failure.
        observed = self.check_revision()
        with private_lock(self.root / ("readiness-" + self.identity + ".lock"),
                          category=LockCategory.SINGLE_FLIGHT):
            yield self.check_revision() != observed

    def finish_check(self, success: bool) -> None:
        with self.transaction(write=True) as (document, _, record):
            record["check_revision"] = document.get("revision", 0) + 1
            record["check_success"] = success
