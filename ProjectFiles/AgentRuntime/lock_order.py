"""Operation-local ordering for TaskPilot's advisory locks; no payload logging."""
from collections import deque
from enum import IntEnum
import os
import threading
import time
from contextlib import contextmanager


class LockCategory(IntEnum):
    SINGLE_FLIGHT = 10
    CONFIGURATION = 20
    INSTALLATION = 30
    STATE = 40


class LockOrderError(RuntimeError):
    code = "internal_lock_order"

    def __init__(self):
        super().__init__(self.code)


_local = threading.local()
_sample_lock = threading.Lock()
_samples = deque(maxlen=128)


def wait_samples():
    """Bounded in-memory diagnostics: fixed category and wait duration only."""
    with _sample_lock:
        return tuple(dict(category=category, wait_ms=duration / 1_000_000)
                     for category, duration in _samples)


class LockReservation:
    def __init__(self, category):
        if not isinstance(category, LockCategory):
            raise LockOrderError()
        # A fork must not inherit another process's operation bookkeeping.
        if getattr(_local, "pid", None) != os.getpid():
            _local.pid, _local.held = os.getpid(), {}
        self._held = _local.held
        if any(category < held for held in self._held.values()):
            raise LockOrderError()
        self._token, self.category = object(), category
        self._held[self._token] = category

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self._held.pop(self._token, None)

    @contextmanager
    def waiting(self):
        started = time.monotonic_ns()
        try:
            yield
        finally:
            duration = max(0, time.monotonic_ns() - started)
            with _sample_lock:
                _samples.append((self.category.name.lower(), duration))


def reserve(category):
    # Reserve before filesystem setup or flock, so inversion never waits.
    return LockReservation(category)
