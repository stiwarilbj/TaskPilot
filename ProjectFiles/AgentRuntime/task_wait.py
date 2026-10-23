"""Bounded, task-owned descriptions for the native status disclosure."""
from __future__ import annotations

import re
from typing import Any

WAIT_PRESENTATION_VERSION = 1
PHASES = {
    "starting", "observing", "planning", "model_response", "executing",
    "reconciling", "verifying", "provider_cooldown", "secure_input", "paused", "draining",
}
ATTENTION = {"none", "secure_input", "resume", "permission"}


def safe_status_text(value: Any, fallback: str, limit: int = 240) -> str:
    if not isinstance(value, str):
        return fallback
    value = re.sub(r"[\x00-\x1f\x7f]+", " ", value)
    value = " ".join(value.split()).strip()
    if not value:
        return fallback
    encoded = value.encode("utf-8")[:limit]
    value = encoded.decode("utf-8", "ignore").rstrip()
    return value or fallback


class TaskWaitPublisher:
    """Deduplicates snapshots while keeping a revision and operation identity."""

    def __init__(self, generation_id: str) -> None:
        self.generation_id = generation_id
        self.revision = 0
        self.operation_id = 0
        self.operation_key: str | None = None
        self.phase = "starting"
        self.last_confirmed = "No confirmed result yet."
        self.waiting_for = "Connecting to the app"
        self.attention = "none"
        self._fingerprint: tuple[Any, ...] | None = None

    def update(
        self,
        phase: str,
        last_confirmed: Any,
        waiting_for: Any,
        attention: str = "none",
        *,
        operation_key: str | None = None,
    ) -> dict[str, Any] | None:
        if phase not in PHASES:
            phase = "reconciling"
        if attention not in ATTENTION:
            attention = "none"
        last = safe_status_text(last_confirmed, "No confirmed result yet.")
        waiting = safe_status_text(waiting_for, "Waiting for the next task step")
        if operation_key is not None and operation_key != self.operation_key:
            self.operation_id += 1
            self.operation_key = operation_key
        elif self.operation_id == 0:
            self.operation_id = 1
        fingerprint = (self.operation_id, phase, last, waiting, attention)
        self.phase, self.last_confirmed, self.waiting_for, self.attention = phase, last, waiting, attention
        if fingerprint == self._fingerprint:
            return None
        self._fingerprint = fingerprint
        self.revision += 1
        return {
            "kind": "task_wait",
            "version": WAIT_PRESENTATION_VERSION,
            "revision": self.revision,
            "operation_id": self.operation_id,
            "phase": phase,
            "last_confirmed": last,
            "waiting_for": waiting,
            "attention": attention,
        }
