"""Immutable literals from the original task; references are data, never templates.

Bindings live only in the originating task's memory. Resolution precedes the
existing validators and does not infer targets, join paths, decode escapes,
interpolate shell source, or grant permission to execute anything.
"""
from __future__ import annotations

from dataclasses import dataclass
from functools import cached_property
import hashlib
import json
import re
from types import MappingProxyType
import uuid

from action_contract_generated import CONTRACT

TASK_INPUT_VERSION = 5
EXACT_INPUT_REFERENCE_VERSION = 3
LEGACY_EXACT_INPUT_REFERENCE_VERSION = 1
PREVIOUS_EXACT_INPUT_REFERENCE_VERSION = 2
MAX_INPUTS = 128
PREVIEW_LENGTH = 160
REFERENCE_PATTERN = re.compile(r"\binput_[0-9a-f]{16}_[1-9][0-9]*\b")
FENCE_START = re.compile(r"(?m)^[ \t]*(`{3,}|~{3,})[^\r\n]*\r?\n")
BARE_RESOURCE = re.compile(r'''(?<![\w/])(?:https?://|~/|/|\.\./|\./)[^\s"'`<>]+''')
BARE_FILENAME = re.compile(r'''(?<!\S)(?:\.?[\w-]+\.)+[\w-]+(?=\s|$|[.,;:!?])''')
EXPLICIT_TEXT = (
    re.compile(r"\s*(?:type|enter|paste|print literal text)[ \t](?P<text>[^\r\n]+)", re.I),
    re.compile(r"\s*(?:create|write|append)\b[^\r\n]*?\b(?:saying|containing|with (?:the )?text)[ \t](?P<text>[^\r\n]+)", re.I),
    re.compile(r"\s*(?:use (?:this|the following) )?text:[ \t]?(?:\r?\n)?(?P<text>.+)", re.I | re.S),
)
TEXT_INSTRUCTIONS = re.compile(r"\b(?:and|then|before|after|into|exactly|once|followed)\b", re.I)
LITERAL_FIELDS = {"path", "content", "text", "url", "query", "command", "working_directory"}


class InputReferenceError(ValueError):
    pass


def fail(path: str, message: str) -> None:
    raise InputReferenceError(path + " " + message)


def literal_kind(value: str) -> str:
    if value.startswith(("http://", "https://")): return "url"
    if value.startswith(("/", "~/", "./", "../")): return "path"
    if re.fullmatch(r"(?:\.?[\w-]+\.)+[\w-]+", value): return "filename"
    return "text"


def literal_spans(task: str) -> list[tuple[int, int]]:
    """Conservative source spans. Ambiguous bare punctuation is left unbound."""
    spans, covered = [], []
    index = 0
    while index < len(task):
        fence = FENCE_START.match(task, index)
        if fence:
            end = re.search(r"(?m)^[ \t]*" + re.escape(fence[1]) + r"[ \t]*\r?(?:\n|$)", task[fence.end():])
            stop = fence.end() + end.end() if end else len(task)
            covered.append((index, stop))
            if end: spans.append((fence.end(), fence.end() + end.start()))
            index = stop
            continue
        opening = task[index]
        closing = {"\"": "\"", "'": "'", "“": "”", "‘": "’"}.get(opening)
        if opening == "`":
            run = re.match(r"`+", task[index:])[0]
            closing = run
        else:
            run = opening
        # Apostrophes and quotes embedded in words are not literal delimiters.
        if closing and (index == 0 or not task[index - 1].isalnum()):
            cursor = index + len(run)
            while (stop := task.find(closing, cursor)) >= 0:
                escaped = 0
                while stop > escaped and task[stop - escaped - 1] == "\\": escaped += 1
                after = stop + len(closing)
                exact_run = opening != "`" or ((stop == 0 or task[stop - 1] != "`") and
                                               (after == len(task) or task[after] != "`"))
                if exact_run and escaped % 2 == 0 and (opening != "'" or after == len(task) or not task[after].isalnum()):
                    break
                cursor = after
            if stop >= 0:
                spans.append((index + len(run), stop))
                covered.append((index, after))
                index = after
                continue
            # Do not extract a misleading smaller token from an unfinished quote.
            covered.append((index, len(task)))
            break
        index += 1
    for pattern in EXPLICIT_TEXT:
        match = pattern.fullmatch(task)
        if not match: continue
        start, end = match.span("text")
        value = task[start:end]
        # A complete explicit suffix can be retained, but not compound tasks,
        # sentence punctuation or a second interpretation of quoted content.
        if (value.rstrip().endswith((".", ",", ";", ":", "!", "?")) or TEXT_INSTRUCTIONS.search(value)
                or any(start < right and end > left for left, right in covered)):
            continue
        spans.append((start, end))
        break
    for pattern in (BARE_RESOURCE, BARE_FILENAME):
        for match in pattern.finditer(task):
            if any(match.start() < end and match.end() > start for start, end in covered + spans): continue
            value = match[0]
            if pattern is BARE_RESOURCE and not value.startswith(("http://", "https://")):
                value = value.rstrip(",")
                if not value: continue
            if match.end() < len(task) and task[match.end()] in "\"'`“”‘’": continue
            if value.endswith((".", ",", ";", ":", "!", "?")) or any(c in value for c in "()[]{}|;"):
                continue
            spans.append((match.start(), match.start() + len(value)))
    return sorted(spans)


@dataclass(frozen=True)
class TaskInput:
    identifier: str
    value: str
    kind: str
    sources: tuple[tuple[int, int], ...]
    resource_kind: str | None = None


@dataclass(frozen=True, init=False)
class TaskInputBindings:
    entries: tuple[TaskInput, ...]
    exact_references: tuple[tuple[str, int, int, str], ...]
    reference_occurrences: tuple[tuple[str, str, int, int, str, str | None], ...]
    _by_id: MappingProxyType
    omitted: int

    def __init__(self, task: str, *, scope: str | None = None,
                 exact_input_references: list[dict] | None = None):
        # The scope is an opaque binding namespace, not the native generation ID.
        # Offline fixtures inject a repeatable scope so recorded hashes replay.
        scope = scope if scope is not None else uuid.uuid4().hex[:16]
        if not re.fullmatch(r"[0-9a-f]{16}", scope): raise ValueError("Invalid task input namespace")
        unique: dict[str, list[tuple[int, int]]] = {}
        explicit_resource_kinds: dict[str, set[str]] = {}
        exact_occurrences: list[tuple[str, int, int, str]] = []
        reference_occurrences: list[tuple[str, str, int, int, str, str | None]] = []
        omitted = 0
        explicit_spans: list[tuple[int, int]] = []
        encoded_task = task.encode("utf-8")
        if exact_input_references is not None:
            if type(exact_input_references) is not list or len(exact_input_references) > MAX_INPUTS:
                raise InputReferenceError("exact_input_references must be a list of at most 128 references")
            previous_end = 0
            for index, reference in enumerate(exact_input_references):
                field = f"exact_input_references[{index}]"
                base_keys = {"version", "kind", "utf8_start", "utf8_length", "value"}
                if type(reference) is not dict or not base_keys.issubset(reference) or set(reference) - base_keys - {"role_override"}:
                    fail(field, "must contain only version, kind, UTF-8 range, value, and optional role_override")
                if type(reference["version"]) is not int or reference["version"] not in {
                    LEGACY_EXACT_INPUT_REFERENCE_VERSION, PREVIOUS_EXACT_INPUT_REFERENCE_VERSION,
                    EXACT_INPUT_REFERENCE_VERSION
                }:
                    fail(field + ".version", "does not match the exact-input reference protocol")
                if "role_override" in reference:
                    if reference["version"] < EXACT_INPUT_REFERENCE_VERSION:
                        fail(field + ".role_override", "requires exact-input reference version 3")
                    if not isinstance(reference["role_override"], str) or reference["role_override"] not in {
                        "source", "destination", "reference_example"
                    }:
                        fail(field + ".role_override", "must be source, destination, or reference_example")
                role_override = reference.get("role_override")
                kind = reference["kind"]
                start, length, value = reference["utf8_start"], reference["utf8_length"], reference["value"]
                allowed_kinds = {"file", "folder", "url"}
                if reference["version"] >= PREVIOUS_EXACT_INPUT_REFERENCE_VERSION:
                    allowed_kinds.add("text")
                if not isinstance(kind, str) or kind not in allowed_kinds:
                    fail(field + ".kind", "must be file, folder, url, or text for reference version 2 or later")
                if type(start) is not int or start < 0:
                    fail(field + ".utf8_start", "must be a nonnegative integer")
                if type(length) is not int or length <= 0:
                    fail(field + ".utf8_length", "must be a positive integer")
                if not isinstance(value, str) or not value:
                    fail(field + ".value", "must be a nonempty string")
                end = start + length
                if start < previous_end or end > len(encoded_task):
                    fail(field, "must be an in-bounds, non-overlapping UTF-8 range")
                try:
                    exact = encoded_task[start:end].decode("utf-8")
                    # Both endpoints must be code point boundaries; decoding
                    # the selected bytes alone rejects a split multibyte value.
                    codepoint_start = len(encoded_task[:start].decode("utf-8"))
                    codepoint_end = len(encoded_task[:end].decode("utf-8"))
                except UnicodeDecodeError as error:
                    raise InputReferenceError(f"{field} must use UTF-8 character boundaries") from error
                if exact != value:
                    fail(field + ".value", "must exactly match the submitted request range")
                if kind == "url":
                    from urllib.parse import urlsplit
                    parsed = urlsplit(value)
                    if parsed.scheme.lower() not in {"http", "https"} or not parsed.netloc:
                        fail(field + ".value", "must be an absolute HTTP(S) URL")
                elif kind in {"file", "folder"} and not value.startswith("/"):
                    fail(field + ".value", "must be an absolute local path")
                if kind in {"file", "folder", "url"}:
                    explicit_resource_kinds.setdefault(value, set()).add(kind)
                explicit_spans.append((codepoint_start, codepoint_end))
                exact_occurrences.append((kind, start, length, value))
                occurrence_id = f"{start}:{length}:{kind}"
                reference_occurrences.append((occurrence_id, kind, start, length, value, role_override))
                unique.setdefault(value, []).append((codepoint_start, codepoint_end))
                previous_end = end
        for start, end in literal_spans(task):
            if any(start < right and end > left for left, right in explicit_spans):
                continue
            value = task[start:end]
            if value not in unique and len(unique) >= MAX_INPUTS:
                omitted += 1
                continue
            unique.setdefault(value, []).append((start, end))
        def resource_kind(value: str) -> str | None:
            explicit = explicit_resource_kinds.get(value, set())
            if len(explicit) == 1:
                return next(iter(explicit))
            if explicit:
                return "path"
            kind = literal_kind(value)
            return kind if kind in {"path", "filename", "url"} else None

        entries = tuple(TaskInput(f"input_{scope}_{index}", value, literal_kind(value), tuple(sources),
                                  resource_kind(value))
                        for index, (value, sources) in enumerate(unique.items(), 1))
        object.__setattr__(self, "entries", entries)
        object.__setattr__(self, "exact_references", tuple(exact_occurrences))
        object.__setattr__(self, "reference_occurrences", tuple(reference_occurrences))
        object.__setattr__(self, "_by_id", MappingProxyType({entry.identifier: entry for entry in entries}))
        object.__setattr__(self, "omitted", omitted)

    def prompt_state(self, *, include_resource_inputs: bool = True) -> dict:
        values = {}
        resource_inputs = []
        for entry in self.entries:
            values[entry.identifier] = (entry.value if len(entry.value) <= PREVIEW_LENGTH else
                {"excerpt": entry.value[:PREVIEW_LENGTH], "length": len(entry.value), "source_ranges": entry.sources})
            if entry.resource_kind is not None:
                resource_inputs.append({"input_id": entry.identifier, "kind": entry.resource_kind})
        state = {"version": TASK_INPUT_VERSION, "values": values,
                 **({"reference_occurrences": [{"occurrence_id": identifier, "input_id": next(
                     entry.identifier for entry in self.entries if entry.value == value),
                     "kind": kind, "user_role": role}
                     for identifier, kind, _start, _length, value, role in self.reference_occurrences]}
                    if self.reference_occurrences else {}),
                 **({"resource_inputs": resource_inputs} if include_resource_inputs and len(resource_inputs) >= 2 else {}),
                 **({"omitted": self.omitted} if self.omitted else {})}
        return state

    @property
    def resource_inputs(self) -> tuple[TaskInput, ...]:
        """Inputs that can name a file, folder, or web resource without probing it."""
        return tuple(entry for entry in self.entries if entry.resource_kind is not None)

    def fingerprint(self) -> str:
        return self._fingerprint

    @cached_property
    def _canonical(self) -> str:
        return json.dumps([TASK_INPUT_VERSION, EXACT_INPUT_REFERENCE_VERSION, self.exact_references,
                           self.reference_occurrences,
                           [(e.identifier, e.value, e.sources, e.resource_kind) for e in self.entries],
                           self.omitted], ensure_ascii=True)

    @cached_property
    def _fingerprint(self) -> str:
        return hashlib.sha256(self._canonical.encode()).hexdigest()

    def resolve(self, response: dict) -> dict:
        return self._transform(response, resolve=True)

    def project(self, response: dict) -> dict:
        """Compact only known literal slots; never alter native/evidence storage."""
        return self._transform(response, resolve=False)

    def _transform(self, response: dict, *, resolve: bool) -> dict:
        slots = literal_slots(response)
        by_value = {entry.value: entry.identifier for entry in self.entries}
        def visit(value, parts=(), path="response"):
            if isinstance(value, dict):
                if "input_ref" in value:
                    if not resolve: return dict(value)
                    if parts not in slots: fail(path, "cannot use an input reference here")
                    if set(value) != {"input_ref"}: fail(path, "requires only input_ref; transformations are not supported")
                    ref = value["input_ref"]
                    if not isinstance(ref, str) or not ref: fail(path + ".input_ref", "must be a nonempty string")
                    entry = self._by_id.get(ref)
                    if entry is None: fail(path + ".input_ref", "must reference an exact input from this task")
                    return entry.value
                return {key: visit(item, parts + (key,), key if not parts else path + "." + key)
                        for key, item in value.items()}
            if isinstance(value, list):
                return [visit(item, parts + (index,), path + f"[{index}]") for index, item in enumerate(value)]
            if isinstance(value, str) and parts in slots:
                if not resolve and value in by_value: return {"input_ref": by_value[value]}
                if resolve and REFERENCE_PATTERN.search(value) and value not in by_value:
                    fail(path, "must use a whole-value input_ref object; interpolation is not supported (use argv for literal command arguments)")
            return value
        return visit(response)


def reject_unbound_references(value, path="response") -> None:
    if isinstance(value, dict):
        if "input_ref" in value: fail(path + ".input_ref", "requires inputs from a current task")
        for key, item in value.items(): reject_unbound_references(item, key if path == "response" else path + "." + key)
    elif isinstance(value, list):
        for index, item in enumerate(value): reject_unbound_references(item, path + f"[{index}]")


def literal_slots(response: dict) -> set[tuple]:
    """Supported scalar-data positions, constrained by the generated contract."""
    slots = {("output",), ("message",)}
    def strings(value, parts, names):
        if isinstance(value, dict): slots.update(parts + (key,) for key in names if key in value)
    def operation(value, parts):
        if not isinstance(value, dict) or not isinstance(value.get("type"), str): return
        definition = CONTRACT["command_operations"].get(value["type"], {})
        strings(value, parts, [key for key, spec in definition.get("fields", {}).items() if spec.get("type") == "string"])
    def checks(value, parts):
        if isinstance(value, list):
            for index, check in enumerate(value): strings(check, parts + (index,), {"path", "content", "text"})
    def arguments(value, parts):
        if isinstance(value, list): slots.update(parts + (index,) for index in range(len(value)))
    def action(value, parts):
        if not isinstance(value, dict): return
        strings(value, parts, LITERAL_FIELDS & {key for key, spec in CONTRACT["fields"].items() if spec.get("type") == "string"})
        arguments(value.get("argv"), parts + ("argv",))
        operation(value.get("operation"), parts + ("operation",))
        checks(value.get("checks"), parts + ("checks",))
    action(response.get("action"), ("action",))
    strings(response.get("expected_result"), ("expected_result",), {"path", "content", "value", "title", "window_title"})
    for name in ("requirements", "uncovered_requirements"):
        if not isinstance(response.get(name), list): continue
        for index, requirement in enumerate(response[name]):
            parts = (name, index)
            strings(requirement, parts, {"source"})
            if isinstance(requirement, dict):
                action(requirement.get("check"), parts + ("check",))
                strings(requirement.get("check"), parts + ("check",), {"expected", "value", "title", "window_title"})
    return slots


def input_reference_rules(*, completion=False) -> str:
    return ('Exact inputs: use {"input_ref":"ID"} for supplied values. Never invent IDs/PIDs, transform or interpolate inputs. '
            'No permission or completion proof.\n')
