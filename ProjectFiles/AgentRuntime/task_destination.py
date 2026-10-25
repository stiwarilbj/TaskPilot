"""Task-scoped, non-authoritative destination details for the status card."""
from __future__ import annotations

import os
import re
from typing import Any

DESTINATION_PRESENTATION_VERSION = 1
_MAX_PATH_BYTES = 2048
_MAX_TEXT_BYTES = 240


def _safe_text(value: Any, limit: int = _MAX_TEXT_BYTES) -> str | None:
    if not isinstance(value, str):
        return None
    value = " ".join(re.sub(r"[\x00-\x1f\x7f]+", " ", value).split()).strip()
    if not value or len(value.encode("utf-8")) > limit:
        return None
    return value


def _exact_text(value: Any, limit: int = _MAX_TEXT_BYTES) -> str | None:
    """Bound display literals without changing whitespace inside paths/names."""
    if not isinstance(value, str) or any(ord(char) < 32 or ord(char) == 127 for char in value):
        return None
    if not value or len(value.encode("utf-8")) > limit:
        return None
    return value


def explicit_destination_instruction(task: str, exact_references: Any = ()) -> str | None:
    # Quoted text and concrete references are data, not overwrite policy.
    if isinstance(exact_references, (list, tuple)):
        encoded = task.encode("utf-8")
        characters = list(task)
        for reference in exact_references:
            if not isinstance(reference, (list, tuple)) or len(reference) != 4:
                continue
            _, start, length, _ = reference
            if type(start) is not int or type(length) is not int or start < 0 or length <= 0:
                continue
            try:
                character_start = len(encoded[:start].decode("utf-8"))
                character_end = len(encoded[:start + length].decode("utf-8"))
            except UnicodeDecodeError:
                continue
            if character_end <= len(characters):
                characters[character_start:character_end] = [" "] * (character_end - character_start)
        task = "".join(characters)
    task = re.sub(r'"[^"\n]*"|(?<![\w])\'[^\'\n]+\'(?![\w])|“[^”\n]*”|‘[^’\n]*’', " ", task)
    task = re.sub(r"(?:~/|/)[^\s\"'`<>]+|https?://[^\s\"'`<>]+", " ", task, flags=re.I)
    matches = []
    if re.search(r"\bcreate\s+(?:a\s+)?(?:new\s+)?copy\b", task, re.I) and not re.search(
            r"\b(?:do\s+not|don['’]t|never|without|no\s+need\s+to)\s+create\s+"
            r"(?:a\s+)?(?:new\s+)?copy\b", task, re.I):
        matches.append("Create a new copy")
    if re.search(r"\b(?:replace|overwrite)\s+(?:the\s+)?(?:existing\s+)?(?:file|copy|destination)\b|\boverwrite\b", task, re.I):
        if re.search(r"\b(?:do\s+not|don['’]t|never|without)\s+(?:replace|overwrite)\b", task, re.I):
            pass
        else:
            matches.append("Replace existing file")
    if re.search(r"\bappend\b", task, re.I):
        if not re.search(r"\b(?:do\s+not|don['’]t|never|without)\s+append\b", task, re.I):
            matches.append("Append")
    unique = list(dict.fromkeys(matches))
    return unique[0] if len(unique) == 1 else None


_OUTPUT_PATH = re.compile(
    r"\b(?:save|export|write|put|store|create|generate|download)\b[^.!?;\n]{0,180}"
    r"\b(?:to|in|into|under|at|as)\s+(?P<path>(?:~/|/)[^\s\"'`<>]+)", re.I)
_CONNECTED_PATH = re.compile(r"^\s*[.,;:]?\s*(?:,|and|or)\s+(?P<path>(?:~/|/)[^\s\"'`<>]+)", re.I)


def _trim_path_punctuation(value: str) -> str:
    return value.rstrip(".,;:!?)]}")


def _has_additional_connected_path(task: str, end: int) -> bool:
    match = _CONNECTED_PATH.match(task[end:])
    return bool(match and _trim_path_punctuation(match.group("path")))


def planned_destination(ledger: Any) -> tuple[str | None, str | None]:
    """Use one explicitly output-scoped resource reference; never join guesses."""
    if ledger is None or not getattr(ledger, "inputs", None):
        return None, None
    from task_evidence import is_output_destination

    candidates = [entry for entry in ledger.inputs.resource_inputs
                  if (ledger.has_input_role(entry.value, "destination") or
                      (not ledger.has_role_assignment(entry.value) and
                       is_output_destination(ledger.task, entry)))]
    values = list(dict.fromkeys(entry.value for entry in candidates))
    direct_matches = list(_OUTPUT_PATH.finditer(ledger.task))
    direct_values = list(dict.fromkeys(_trim_path_punctuation(match.group("path"))
                                       for match in direct_matches
                                       if (not ledger.has_role_assignment(_trim_path_punctuation(match.group("path"))) or
                                           ledger.has_input_role(_trim_path_punctuation(match.group("path")), "destination"))))
    if len(values) > 1 or len(direct_values) > 1:
        return None, None
    if values and direct_values and values[0] != direct_values[0]:
        return None, None
    if not values:
        values = direct_values
    if len(values) == 1:
        entry = next((item for item in candidates if item.value == values[0]), None)
        source_ends = [end for _, end in entry.sources] if entry else []
        if not source_ends:
            source_ends = [match.end("path") for match in direct_matches if
                           _trim_path_punctuation(match.group("path")) == values[0]]
        if any(_has_additional_connected_path(ledger.task, end) for end in source_ends):
            return None, None
    if len(values) != 1:
        return None, None
    value = values[0]
    entry = next((item for item in candidates if item.value == value), None)
    kind = entry.resource_kind if entry else "path"
    if kind in {"path", "file", "folder"} and value.startswith(("/", "~/")):
        path = os.path.expanduser(value)
        filename = os.path.basename(path.rstrip(os.sep))
        source = next((span for item in candidates if item.value == value for span in item.sources), None)
        as_filename = bool(source and re.search(r"\bas\s+$", ledger.task[max(0, source[0] - 16):source[0]], re.I))
        requested_name = None if kind == "folder" else (filename if kind == "file" or "." in filename or as_filename else None)
        return value, requested_name
    if kind == "filename" and "/" not in value:
        return None, value
    return None, None


class TaskDestinationPublisher:
    """Deduplicated and bounded UI projection; never participates in execution."""

    def __init__(self, generation_id: str) -> None:
        self.generation_id = generation_id
        self.revision = 0
        self.operation_id = 0
        self.operation_key: str | None = None
        self._fingerprint: tuple[Any, ...] | None = None
        self.current: dict[str, Any] | None = None

    def update(self, *, state: str, operation_key: str, planned_path: Any = None,
               actual_path: Any = None, requested_filename: Any = None,
               selected_filename: Any = None, destination_exists: Any = None,
               instruction: Any = None, observation_revision: Any = None) -> dict[str, Any] | None:
        if state not in {"planned", "selected", "selected_unconfirmed", "preparing", "checking", "cleared"}:
            state = "selected_unconfirmed"
        if not isinstance(operation_key, str) or not operation_key or len(operation_key) > 160:
            operation_key = "destination"

        def path(value: Any) -> str | None:
            result = _exact_text(value, _MAX_PATH_BYTES)
            if result is None or not os.path.isabs(os.path.expanduser(result)):
                return None
            return result

        planned = path(planned_path)
        actual = path(actual_path)
        requested = _exact_text(requested_filename)
        selected = _exact_text(selected_filename)
        policy = instruction if instruction in {"Create a new copy", "Replace existing file", "Append"} else None
        exists = destination_exists if type(destination_exists) is bool else None
        observed = _safe_text(observation_revision, 128)
        if state == "cleared":
            planned = actual = requested = selected = policy = observed = None
            exists = None
        if state in {"selected", "preparing", "checking"} and actual is None:
            state = "selected_unconfirmed"
        fingerprint = (state, operation_key, planned, actual, requested, selected, exists, policy, observed)
        if fingerprint == self._fingerprint:
            return None
        if operation_key != self.operation_key:
            self.operation_id += 1
            self.operation_key = operation_key
        elif self.operation_id == 0:
            self.operation_id = 1
        self._fingerprint = fingerprint
        self.revision += 1
        snapshot = {
            "kind": "task_destination",
            "version": DESTINATION_PRESENTATION_VERSION,
            "revision": self.revision,
            "operation_id": self.operation_id,
            "state": state,
            "planned_path": planned,
            "actual_path": actual,
            "requested_filename": requested,
            "selected_filename": selected,
            "destination_exists": exists,
            "instruction": policy,
            "observation_revision": observed,
        }
        self.current = snapshot if state != "cleared" else None
        return snapshot
