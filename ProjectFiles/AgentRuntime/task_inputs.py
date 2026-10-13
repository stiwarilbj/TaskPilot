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

TASK_INPUT_VERSION = 2
MAX_INPUTS = 128
PREVIEW_LENGTH = 160
REFERENCE_PATTERN = re.compile(r"\binput_[0-9a-f]{16}_[1-9][0-9]*\b")
FENCE_START = re.compile(r"(?m)^[ \t]*(`{3,}|~{3,})[^\r\n]*\r?\n")
BARE_RESOURCE = re.compile(r'''(?<![\w/])(?:https?://|~/|/|\.\./|\./)[^\s"'`<>]+''')
BARE_FILENAME = re.compile(r'''(?<!\S)(?:\.?[\w-]+\.)+[\w-]+(?=\s|$)''')
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
            if match.end() < len(task) and task[match.end()] in "\"'`“”‘’": continue
            if value.endswith((".", ",", ";", ":", "!", "?")) or any(c in value for c in "()[]{}|;"):
                continue
            spans.append(match.span())
    return sorted(spans)


@dataclass(frozen=True)
class TaskInput:
    identifier: str
    value: str
    kind: str
    sources: tuple[tuple[int, int], ...]


@dataclass(frozen=True, init=False)
class TaskInputBindings:
    entries: tuple[TaskInput, ...]
    _by_id: MappingProxyType
    omitted: int

    def __init__(self, task: str, *, scope: str | None = None):
        # The scope is an opaque binding namespace, not the native generation ID.
        # Offline fixtures inject a repeatable scope so recorded hashes replay.
        scope = scope if scope is not None else uuid.uuid4().hex[:16]
        if not re.fullmatch(r"[0-9a-f]{16}", scope): raise ValueError("Invalid task input namespace")
        unique: dict[str, list[tuple[int, int]]] = {}
        omitted = 0
        for start, end in literal_spans(task):
            value = task[start:end]
            if value not in unique and len(unique) >= MAX_INPUTS:
                omitted += 1
                continue
            unique.setdefault(value, []).append((start, end))
        entries = tuple(TaskInput(f"input_{scope}_{index}", value, literal_kind(value), tuple(sources))
                        for index, (value, sources) in enumerate(unique.items(), 1))
        object.__setattr__(self, "entries", entries)
        object.__setattr__(self, "_by_id", MappingProxyType({entry.identifier: entry for entry in entries}))
        object.__setattr__(self, "omitted", omitted)

    def prompt_state(self) -> dict:
        values = {}
        for entry in self.entries:
            values[entry.identifier] = (entry.value if len(entry.value) <= PREVIEW_LENGTH else
                {"excerpt": entry.value[:PREVIEW_LENGTH], "length": len(entry.value), "source_ranges": entry.sources})
        return {"version": TASK_INPUT_VERSION, "values": values, **({"omitted": self.omitted} if self.omitted else {})}

    def fingerprint(self) -> str:
        return self._fingerprint

    @cached_property
    def _canonical(self) -> str:
        return json.dumps([TASK_INPUT_VERSION, [(e.identifier, e.value, e.sources) for e in self.entries],
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
    fields = 'checklist/check/output values' if completion else 'literal action/argv/checklist/check values'
    return ('Exact inputs: {"input_ref":"<supplied ID>"} for whole ' + fields + '; never IDs/PIDs. '
            'No transforms/interpolation; argv for shell operands. '
            'Inputs give no permission or completion proof; strings still valid.\n')
