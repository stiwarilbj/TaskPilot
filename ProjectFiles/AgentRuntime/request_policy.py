"""TaskPilot's bounded model policy and private readiness cache."""
from __future__ import annotations

from response_validation import VALIDATION_VERSION
from action_contract_generated import CONTRACT_HASH
from provider_errors import ProviderRequestError, facts, retry_time

from dataclasses import dataclass, replace
from datetime import datetime, timezone
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
import time
from typing import Any, Callable
from lock_order import LockCategory, reserve

PRIMARY_MODELS = ("google/gemini-3.5-flash-lite", "google/gemini-3.1-flash-lite")
FALLBACK_MODELS = (
    "google/gemini-2.5-flash-lite", "google/gemini-3.8-flash",
    "google/gemini-3-flash-preview", "google/gemini-2.5-flash",
)
ALL_MODELS = PRIMARY_MODELS + FALLBACK_MODELS
CONFIG_VERSION = 5
ERROR_POLICY_VERSION = 1


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
    payload = error.payload if isinstance(error, ProviderRequestError) else message
    fields = facts(payload, getattr(error, "model", None) or model)
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
    reset = retry_time(payload, message, now)
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
            try:
                document = json.loads(self.path.read_text())
                if not isinstance(document, dict): document = {}
            except (OSError, ValueError):
                document = {}
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
                document["revision"] = int(document.get("revision", 0)) + 1
                self.value["revision"] = document["revision"]
                fd, name = tempfile.mkstemp(prefix=".runtime-readiness-", dir=self.root)
                try:
                    with os.fdopen(fd, "w") as output:
                        json.dump(document, output, allow_nan=False)
                        output.flush()
                        os.fsync(output.fileno())
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
                    record.setdefault("invalidations", {})["*"] = document.get("revision", 0) + 1

    def verify(self, model: str, started_revision: int | None = None, *, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        with self.transaction(write=True) as (document, bucket, record):
            # An old success must never erase a failure observed after it began.
            boundary = document.get("revision", 0) if started_revision is None else started_revision
            if max(bucket.get("invalidated_revision", 0), record.get("invalidations", {}).get("*", 0),
                   record.get("invalidations", {}).get(model, 0)) > boundary: return False
            for field, key in (("health", model), ("credential_health", model.split('/', 1)[0])):
                failure = (self.model_health_records(bucket) if field == "health" else bucket[field]).get(key, {})
                if failure and (failure.get("revision", 0) > boundary or
                    (failure.get("state") == "temporary" and failure.get("retry_at") is not None and failure["retry_at"] > now)):
                    return False
            self.model_health_records(bucket).pop(model, None)
            bucket["credential_health"].pop(model.split('/', 1)[0], None)
            record["verified"][model] = now
            return True

    def invalidate(self, model: str | None = None) -> None:
        with self.transaction(write=True) as (document, _, record):
            record.setdefault("invalidations", {})[model or "*"] = document.get("revision", 0) + 1
            if model: record["verified"].pop(model, None)
            else: record["verified"].clear()

    def record_failure(self, model: str, failure: Failure) -> None:
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
                if failure.kind in {"credentials", "transport", "configuration"}: verified.clear()
                elif shared:
                    for other in list(verified):
                        if other.startswith(key + '/'): verified.pop(other, None)
                else: verified.pop(model, None)

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

    def verified_model(self) -> str | None:
        with self.transaction():
            now = time.time()
            return next((m for m in ALL_MODELS if not self.current_health(self.value["credential_health"].get(m.split('/', 1)[0], {})) and not self.current_health(self.value["health"].get(m, {})) and isinstance(self.value["verified"].get(m), (int, float)) and 0 <= now - self.value["verified"][m] < 600), None)

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
