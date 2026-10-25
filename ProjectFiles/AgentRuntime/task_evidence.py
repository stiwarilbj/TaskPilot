"""Task-local proof ledger. Model claims never create native evidence.

Semantic coverage is audited in the existing verification request. Only a
full-request local grammar may bypass that audit. Nothing here is persisted.
"""
from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
import math
import os
import re
import threading
import unicodedata
from copy import deepcopy
from typing import Any

from action_contract_generated import (CONTRACT, ActionContractError, _field, validate_action, validate_outcome_check,
    validate_native_result, validate_check_batch, validate_native_readback, validate_native_payload, validate_native_evidence)
from task_inputs import TaskInputBindings
from expected_effects import ExpectedEffect, ExpectedEffectError, validate_expectation
from observation_context import coordinate_targets, observation_indexes

CHECKLIST_VERSION = 11
BATCH_PROGRESS_VERSION = 1
CONTINUATION_CHECKPOINT_VERSION = 1
RESULT_BROWSER_BUNDLE_IDS = frozenset({
    "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev",
    "org.chromium.Chromium", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
    "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
    "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
})
FILE_CHECKS = {"file_exists", "directory_exists", "path_absent", "file_contents"}
OBSERVATION_CHECKS = {"window_active", "field_value", "dialog_present"}
READ_PATTERN = r'\s*(?:read|show|print)\s+(?:the\s+)?(?:contents of\s+)?file\s+(["`\'])((?:/|~/)(?:(?!\1)[^\n])+)\1\s*[.!]?\s*'
LARGEST_PATTERN = (r"\s*(?:(?:what(?:['’]s| is)|which is) (?:the |my )?|(?:find|tell me|show me) (?:the )?)"
                   r"largest file (?:in|inside) (?:my |the |your )?downloads(?: folder)?\s*[?.!]?\s*")


class EvidenceValidationError(ValueError):
    pass


_PER_INPUT_TERMS = re.compile(
    r"\b(?:each|every|individually|separately|one\s+per|for\s+each|per[- ](?:file|document|input|item))\b",
    re.I,
)
_COMBINED_TERMS = re.compile(
    r"\b(?:merge|combine|compare|together|into\s+one|single\s+(?:report|summary|file|document|archive)|"
    r"one\s+(?:report|summary|file|document|archive))\b",
    re.I,
)
_ALL_RESOURCE_TERMS = re.compile(
    r"\ball\s+(?:\d+\s+)?(?:files?|documents?|spreadsheets?|workbooks?|images?|pdfs?)\b",
    re.I,
)


def requests_per_input_work(task: str) -> bool:
    # A strong combined-result instruction wins over the ambiguous words
    # "each" and "every" (for example, "compare each sheet in one report").
    # Explicitly separate outputs still establish a batch.
    if re.search(r"\b(?:separately|individually|one\s+per|for\s+each|per[- ](?:file|document|input|item)|separate\s+(?:files?|documents?|outputs?|reports?|summaries?)\s+for\s+each)\b", task, re.I):
        return True
    if _COMBINED_TERMS.search(task):
        return False
    return bool(_PER_INPUT_TERMS.search(task) or _ALL_RESOURCE_TERMS.search(task))


def is_output_destination(task: str, entry: Any) -> bool:
    """Recognize plainly phrased output locations without probing the filesystem."""
    destination_prefix = re.compile(
        r"\b(?:save|export|write|put|store|place|deliver|download|copy|move|create|output|convert|transform|process)\b"
        r"[^!?\n]{0,180}\b(?:to|in|into|under|beside|at|as)\s*$",
        re.I,
    )
    result_location = re.compile(
        r"\b(?:report|summary|result|output|copy|converted\s+(?:file|document))\b"
        r"[^!?\n]{0,80}\b(?:to|in|into|under|beside|at|as)\s*$", re.I)
    direct_output = re.compile(
        r"\b(?:save|export|write|store|create|generate|produce|make|download|output)"
        r"\s+(?:(?:the|a|an|new|final|result|output|converted)\s+){0,3}"
        r"(?:file|folder|document|spreadsheet|workbook|report|pdf|copy)?\s*$",
        re.I,
    )
    for start, _ in entry.sources:
        prefix = task[max(0, start - 180):start].rstrip("\"'`“‘")
        if destination_prefix.search(prefix) or result_location.search(prefix) or direct_output.search(prefix):
            return True
    return False


def validate_batch_declaration(value: Any, ledger: "TaskEvidenceLedger", proposed: dict,
                               path: str = "batch") -> dict:
    if not isinstance(value, dict) or set(value) != {
        "mode", "items", "source_input_ids", "excluded_inputs", "global_requirement_ids"
    }:
        fail(path, "must contain mode, items, source_input_ids, excluded_inputs, and global_requirement_ids only")
    mode = value.get("mode")
    if not isinstance(mode, str) or mode not in {"per_input", "combined", "none"}:
        fail(path + ".mode", "must be per_input, combined, or none")
    resources = ledger.inputs.resource_inputs
    by_id = {entry.identifier: entry for entry in resources}
    if len(resources) < 2:
        fail(path, "requires at least two explicit resource inputs")

    source_ids = value.get("source_input_ids")
    if (not isinstance(source_ids, list) or len(source_ids) > len(resources) or
            any(not isinstance(identifier, str) for identifier in source_ids) or
            len(set(source_ids)) != len(source_ids) or any(identifier not in by_id for identifier in source_ids)):
        fail(path + ".source_input_ids", "must list unique resource input IDs from this task")
    if any(is_output_destination(ledger.task, by_id[identifier]) for identifier in source_ids):
        fail(path + ".source_input_ids", "cannot include a stated output destination as a source input")
    excluded_values = value.get("excluded_inputs")
    if not isinstance(excluded_values, list) or len(excluded_values) > len(resources):
        fail(path + ".excluded_inputs", "must be a list of excluded resource inputs")
    excluded: list[dict] = []
    excluded_ids: list[str] = []
    for index, item in enumerate(excluded_values):
        field = f"{path}.excluded_inputs[{index}]"
        if not isinstance(item, dict) or set(item) != {"input_id", "reason"}:
            fail(field, "requires input_id and reason only")
        identifier, reason = item.get("input_id"), item.get("reason")
        if not isinstance(identifier, str) or identifier not in by_id:
            fail(field + ".input_id", "must reference an explicit resource input from this task")
        if identifier in excluded_ids:
            fail(field + ".input_id", "must be unique")
        if not isinstance(reason, str) or reason not in {"output_destination", "incidental"}:
            fail(field + ".reason", "must be output_destination or incidental")
        if reason == "output_destination" and not is_output_destination(ledger.task, by_id[identifier]):
            fail(field + ".reason", "may identify only an output destination stated in the request")
        if reason == "incidental" and requests_per_input_work(ledger.task):
            fail(field + ".reason", "cannot omit a supplied input from explicitly per-input work")
        excluded.append({"input_id": identifier, "reason": reason})
        excluded_ids.append(identifier)
    for identifier in excluded_ids:
        if is_output_destination(ledger.task, by_id[identifier]) and next(
                item["reason"] for item in excluded if item["input_id"] == identifier) != "output_destination":
            fail(path + ".excluded_inputs", "a stated output destination must use reason output_destination")
    if set(source_ids) & set(excluded_ids) or set(source_ids) | set(excluded_ids) != set(by_id):
        fail(path, "must account for every explicit resource input exactly once")

    item_values = value.get("items")
    if not isinstance(item_values, list) or len(item_values) > len(resources):
        fail(path + ".items", "must be a list of per-input outcome mappings")
    items: list[dict] = []
    item_ids: list[str] = []
    mapped_requirement_ids: list[str] = []
    if mode == "per_input":
        if len(source_ids) < 2:
            fail(path + ".source_input_ids", "must include at least two inputs for per_input work")
        for index, item in enumerate(item_values):
            field = f"{path}.items[{index}]"
            if not isinstance(item, dict) or set(item) != {"input_id", "requirement_ids"}:
                fail(field, "requires input_id and requirement_ids only")
            identifier = item.get("input_id")
            if not isinstance(identifier, str) or identifier not in by_id:
                fail(field + ".input_id", "must reference an explicit resource input from this task")
            if identifier in item_ids:
                fail(field + ".input_id", "must be unique; repeated references to one input form one item")
            requirement_ids = item.get("requirement_ids")
            requirement_refs(requirement_ids, field + ".requirement_ids")
            for requirement_id in requirement_ids:
                requirement = proposed.get(requirement_id)
                if (requirement is None or requirement.get("state") == "superseded" or
                        requirement.get("scope", "outcome") == "prerequisite"):
                    fail(field + ".requirement_ids", "must reference active outcome requirements from this task")
                if requirement_id in mapped_requirement_ids:
                    fail(field + ".requirement_ids", "cannot assign one requirement to multiple batch items")
                mapped_requirement_ids.append(requirement_id)
            items.append({"input_id": identifier, "requirement_ids": list(requirement_ids)})
            item_ids.append(identifier)
        if item_ids != source_ids:
            fail(path + ".items", "must map source inputs in request order and match source_input_ids")
    elif item_values:
        fail(path + ".items", "must be empty unless mode is per_input")
    elif mode == "combined" and len(source_ids) < 2:
        fail(path + ".source_input_ids", "must include at least two inputs for a combined result")

    if requests_per_input_work(ledger.task) and mode != "per_input":
        fail(path + ".mode", "must be per_input because the request asks for separate work on each input")

    global_ids = value.get("global_requirement_ids")
    requirement_refs(global_ids, path + ".global_requirement_ids", empty=True)
    active_outcomes = {identifier for identifier, requirement in proposed.items()
                       if requirement.get("state") != "superseded" and
                       requirement.get("scope", "outcome") != "prerequisite"}
    if mode == "per_input":
        if len(set(global_ids) & set(mapped_requirement_ids)):
            fail(path + ".global_requirement_ids", "cannot repeat requirements already assigned to batch items")
        if set(global_ids) | set(mapped_requirement_ids) != active_outcomes:
            fail(path + ".global_requirement_ids", "must complete the requirement mapping for every active outcome")
        for index, item in enumerate(items):
            if not item["requirement_ids"]:
                fail(f"{path}.items[{index}].requirement_ids", "must identify every requested outcome for this input")
    elif set(global_ids) != active_outcomes:
        fail(path + ".global_requirement_ids", "must list every active outcome requirement outside a per-input batch")

    resource_order = [entry.identifier for entry in resources]
    if [identifier for identifier in resource_order if identifier in set(source_ids)] != source_ids:
        fail(path + ".source_input_ids", "must preserve the supplied input order")
    return {"mode": mode, "items": items, "source_input_ids": list(source_ids),
            "excluded_inputs": excluded, "global_requirement_ids": list(global_ids)}


def fail(path: str, reason: str) -> None:
    raise EvidenceValidationError(f"{path} {reason}")


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                    ensure_ascii=True).encode()).hexdigest()


def same_json_state(first: Any, second: Any) -> bool:
    """Compare without encoding, including distinctions Python equality hides."""
    if first is second: return True
    if type(first) is not type(second): return False
    if isinstance(first, dict):
        return first.keys() == second.keys() and all(same_json_state(value, second[key]) for key, value in first.items())
    if isinstance(first, (list, tuple)):
        return len(first) == len(second) and all(same_json_state(a, b) for a, b in zip(first, second))
    if isinstance(first, float) and first == second == 0:
        return math.copysign(1, first) == math.copysign(1, second)
    return first == second


class RevisionedJSONState:
    """In-memory representations of one state revision, never a result cache."""
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self.revision = 0
        self._snapshot: Any = None
        self._values: dict[Any, Any] = {}

    def update(self, value: Any) -> None:
        with self._lock:
            if not self.revision or not same_json_state(value, self._snapshot):
                self._snapshot = deepcopy(value)
                self.revision += 1
                self._values.clear()

    def memoize(self, key: Any, build):
        with self._lock:
            if key not in self._values: self._values[key] = build()
            return self._values[key]

    def evict_memoized(self) -> None:
        # Retain the accepted snapshot and revision, never discard evidence.
        with self._lock: self._values.clear()

    @property
    def canonical(self) -> str:
        return self.memoize("canonical", lambda: json.dumps(self._snapshot, sort_keys=True,
                           separators=(",", ":"), ensure_ascii=True))

    @property
    def fingerprint(self) -> str:
        return self.memoize("fingerprint", lambda: hashlib.sha256(self.canonical.encode()).hexdigest())

    def clear(self) -> None:
        with self._lock:
            self._snapshot = None
            self._values.clear()
            self.revision = 0


def path_key(path: str) -> str:
    return os.path.normpath(os.path.expanduser(path))


def content_bytes(check: dict) -> bytes:
    return (base64.b64decode(check["content"], validate=True) if check.get("encoding", "utf-8").lower() == "base64"
            else check["content"].encode("utf-8"))


def content_hash(check: dict) -> str:
    return hashlib.sha256(content_bytes(check)).hexdigest()


def nonempty(value: Any, path: str) -> None:
    if not isinstance(value, str) or not value.strip():
        fail(path, "must be a nonempty string")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        fail(path, "must contain valid UTF-8 text")


def validate_requirement(value: Any, task: str | None, path: str) -> dict:
    if not isinstance(value, dict): fail(path, "must be an object")
    if set(value) - {"source", "description", "check", "depends_on", "scope", "supersedes"}: fail(path, "contains unsupported fields")
    for key in ("source", "description"):
        nonempty(value.get(key), f"{path}.{key}")
    if task is not None and value["source"] not in task:
        fail(path + ".source", "must quote the effective task instructions exactly")
    if "depends_on" in value:
        requirement_refs(value["depends_on"], path + ".depends_on", empty=True)
    if "supersedes" in value:
        requirement_refs(value["supersedes"], path + ".supersedes")
    if "scope" in value and value["scope"] not in ("outcome", "prerequisite"):
        fail(path + ".scope", "must be outcome or prerequisite")
    check = value.get("check")
    if not isinstance(check, dict): fail(path + ".check", "must be an object")
    kind = check.get("type")
    if not isinstance(kind, str): fail(path + ".check.type", "must be a supported proof type")
    try:
        if kind in FILE_CHECKS or kind == "stdout_equals":
            _field([check], CONTRACT["fields"]["checks"], path + ".check_list")
        elif kind in {"file_read", "file_append", "file_written"}:
            allowed = {"type", "path"} | ({"content", "encoding"} if kind != "file_read" else set())
            if kind == "file_written": allowed.add("mode")
            if set(check) - allowed: fail(path + ".check", "contains unsupported fields")
            validate_action({**check, "type": "read_file" if kind == "file_read" else "write_file"})
        elif kind == "command_executed":
            if set(check) - {"type", "argv", "command", "working_directory"}:
                fail(path + ".check", "contains unsupported fields")
            validate_action({**check, "type": "run_command"})
        elif kind == 'command_operation':
            if set(check) != {'type', 'operation'}: fail(path + '.check', 'requires only type and operation')
            validate_action({'type': 'run_command', 'operation': check.get('operation')})
        elif kind in OBSERVATION_CHECKS:
            if kind == "window_active":
                if set(check) != {"type", "pid", "title"}: fail(path + ".check", "requires only type, pid and title")
                from action_contract_generated import validate_contract_field
                validate_contract_field("pid", check["pid"], path + ".check.pid")
                validate_contract_field("element_id", check["title"], path + ".check.title")
            else:
                validate_expectation({**check, "type": "dialog_appeared" if kind == "dialog_present" else kind})
        elif kind in {"visual", "answer"}:
            if set(check) != {"type", "expected"}: fail(path + ".check", "requires only type and expected")
            nonempty(check.get("expected"), path + ".check.expected")
        else:
            fail(path + ".check.type", "must be a supported proof type")
    except ActionContractError as error:
        raise EvidenceValidationError(str(error).replace("action", path + ".check", 1).replace(".check_list[0]", ".check")) from error
    except ExpectedEffectError as error:
        raise EvidenceValidationError(str(error).replace("expected_result", path + ".check", 1)) from error
    return deepcopy(value)


def requirement_refs(value: Any, path: str, *, empty=False) -> None:
    if (not isinstance(value, list) or (not empty and not value) or
            any(not isinstance(ref, str) or not re.fullmatch(r"r[1-9][0-9]*", ref) for ref in value) or
            len(set(value)) != len(value)):
        fail(path, "must be a " + ("" if empty else "nonempty ") + "list of unique requirement IDs")


def dependency_order(requirements: dict) -> list[str]:
    remaining, ordered = dict(requirements), []
    while remaining:
        ready = [identifier for identifier, entry in remaining.items()
                 if all(ref in ordered for ref in entry.get("depends_on", []))]
        if not ready: fail("requirements.depends_on", "must form an acyclic graph")
        for identifier in ready:
            ordered.append(identifier)
            del remaining[identifier]
    return ordered


def project_requirements(existing: dict, entries: list[dict], task: str, path="requirements") -> dict:
    """Validate the entire proposed graph transactionally; IDs never renumber."""
    result, origins = deepcopy(existing), {}
    for index, entry in enumerate(entries):
        field_path = f"{path}[{index}]"
        entry = validate_requirement(entry, task, field_path)
        supersedes = entry.get("supersedes", [])
        if supersedes:
            correction_marker = "\n\nUser correction: "
            latest_correction = task.rsplit(correction_marker, 1)[-1] if correction_marker in task else ""
            if path != "requirements" or not latest_correction or entry["source"] not in latest_correction:
                fail(field_path + ".supersedes", "may only quote a current user correction during planning")
            unknown = [ref for ref in supersedes if ref not in result]
            if unknown:
                fail(field_path + ".supersedes", "must reference existing requirements from this task")
            if any(result[ref].get("state") == "superseded" for ref in supersedes):
                matched = next((key for key, old in result.items()
                                if old.get("state") != "superseded" and old["source"] == entry["source"]
                                and old["check"] == entry["check"]), None)
                if matched and all(result[ref].get("superseded_by") == matched for ref in supersedes):
                    origins[matched] = field_path
                    continue
                fail(field_path + ".supersedes", "cannot supersede an already superseded requirement")
            dependents = [identifier for identifier, requirement in result.items()
                          if requirement.get("state") != "superseded" and
                          identifier not in supersedes and
                          any(ref in supersedes for ref in requirement.get("depends_on", []))]
            if dependents:
                fail(field_path + ".supersedes", "must also replace or supersede active dependent requirements")
        matching = [key for key, old in result.items()
                    if old.get("state") != "superseded" and
                    old["source"] == entry["source"] and old["check"] == entry["check"]]
        identifier = next((key for key in matching if entry.get("scope", result[key].get("scope", "outcome")) == result[key].get("scope", "outcome")),
                          matching[0] if matching else None)
        # The final auditor may require a current outcome in addition to an
        # already-recorded historical precondition; it cannot replace either.
        if (identifier and path == "uncovered_requirements" and entry.get("scope") == "outcome" and
                result[identifier].get("scope") == "prerequisite"):
            identifier = next((key for key, old in result.items() if old["source"] == entry["source"] and
                               old["check"] == entry["check"] and old.get("scope") == "outcome"), None)
        if supersedes and identifier is not None:
            fail(field_path + ".supersedes", "must define a new replacement requirement")
        if supersedes:
            identifier = f"r{len(result) + 1}"
            result[identifier] = {**entry, "scope": entry.get("scope", "outcome"),
                                  "depends_on": entry.get("depends_on", []),
                                  "state": "pending", "evidence_ids": []}
            for ref in supersedes:
                result[ref]["state"] = "superseded"
                result[ref]["superseded_by"] = identifier
                result[ref]["evidence_ids"] = []
        elif identifier:
            old = result[identifier]
            if "scope" in entry and entry["scope"] != old.get("scope", "outcome"):
                fail(field_path + ".scope", "cannot change an existing requirement's proof scope")
            old["depends_on"] = list(dict.fromkeys(old.get("depends_on", []) + entry.get("depends_on", [])))
        else:
            identifier = f"r{len(result) + 1}"
            result[identifier] = {**entry, "scope": entry.get("scope", "outcome"),
                                  "depends_on": entry.get("depends_on", []), "state": "pending", "evidence_ids": []}
        origins[identifier] = field_path
    for identifier, entry in result.items():
        for ref in entry.get("depends_on", []):
            field_path = origins.get(identifier, f"requirements.{identifier}") + ".depends_on"
            if ref == identifier: fail(field_path, "cannot include the requirement itself")
            if ref not in result: fail(field_path, "must reference this task's checklist")
            if entry.get("state") != "superseded" and result[ref].get("state") == "superseded":
                fail(field_path, "cannot depend on a superseded requirement; update the dependency")
    dependency_order(result)
    return result


def validate_metadata(value: dict, purpose: str, ledger: TaskEvidenceLedger | None = None,
                      observation: dict | None = None) -> None:
    proposed = ledger.requirements if ledger else {}
    for key in ("requirements", "uncovered_requirements"):
        if key in value:
            entries = value[key]
            if not isinstance(entries, list): fail(key, "must be a list")
            for index, entry in enumerate(entries):
                validate_requirement(entry, ledger.task if ledger else None, f"{key}[{index}]")
            if ledger:
                proposed = project_requirements(proposed, ledger.canonical_entries(entries, observation), ledger.task, key)
            elif any(entry.get("depends_on") for entry in entries):
                fail(key + ".depends_on", "requires a current task checklist")
    if ledger: ledger.validate_observation_checks(proposed, observation)
    if "batch" in value:
        if purpose != "planning": fail("batch", "may be declared only by a planning response")
        if ledger is None: fail("batch", "requires the current task input and checklist")
        normalized_batch = validate_batch_declaration(value["batch"], ledger, proposed)
        if not ledger.batch_declaration_required_for(proposed) and ledger.batch_initialized:
            if normalized_batch != ledger.batch_declaration():
                fail("batch", "cannot change after planning unless inputs or checklist requirements changed")
    if "requirement_ids" in value:
        requirement_refs(value["requirement_ids"], "requirement_ids")
        if ledger is None or any(ref not in proposed or proposed[ref].get("state") == "superseded"
                                 for ref in value["requirement_ids"]):
            fail("requirement_ids", "must reference this task's checklist")
    if (purpose == "planning" and any(r.get("depends_on") for r in proposed.values()) and
            value.get("status") in {"act", "needs_user", "blocked"} and
            isinstance(value.get("action"), dict) and value["action"].get("type") not in {"none", "wait"} and
            not value.get("requirement_ids")):
        fail("requirement_ids", "must identify the requirements advanced by this action when dependencies exist")
    if "coverage_complete" in value and type(value["coverage_complete"]) is not bool:
        fail("coverage_complete", "must be a boolean")
    if "output_evidence_ids" in value:
        refs = value["output_evidence_ids"]
        if not isinstance(refs, list) or any(not isinstance(ref, str) for ref in refs) or len(set(refs)) != len(refs):
            fail("output_evidence_ids", "must be a list of unique evidence IDs")
        if ledger:
            for ref in refs:
                evidence = ledger.evidence.get(ref)
                if evidence is None or not evidence["valid"] or evidence["fact"]["type"] not in {"file_read", "stdout_equals"}:
                    fail("output_evidence_ids", "must reference complete verified file/output evidence from this task")
    if "proofs" in value:
        if not isinstance(value["proofs"], list): fail("proofs", "must be a list")
        seen = set()
        for index, proof in enumerate(value["proofs"]):
            path = f"proofs[{index}]"
            if not isinstance(proof, dict) or set(proof) != {"requirement_id", "evidence_ids", "rationale"}:
                fail(path, "requires requirement_id, evidence_ids, and rationale only")
            nonempty(proof["requirement_id"], path + ".requirement_id")
            nonempty(proof["rationale"], path + ".rationale")
            refs = proof["evidence_ids"]
            if not isinstance(refs, list) or not refs or any(not isinstance(ref, str) for ref in refs):
                fail(path + ".evidence_ids", "must be a nonempty list of evidence IDs")
            if proof["requirement_id"] in seen: fail(path + ".requirement_id", "must be unique")
            seen.add(proof["requirement_id"])
            if ledger:
                requirement = ledger.requirements.get(proof["requirement_id"])
                if requirement is None or requirement.get("state") == "superseded":
                    fail(path + ".requirement_id", "must reference an active requirement in this task's checklist")
                for ref in refs:
                    evidence = ledger.evidence.get(ref)
                    if evidence is None or not evidence["valid"]:
                        fail(path + ".evidence_ids", "must reference current evidence from this task")
                if not any(ledger.requirement_matches(proof["requirement_id"], ledger.evidence[ref], semantic=True) for ref in refs):
                    fail(path + ".evidence_ids", "do not prove the requirement's target and outcome")
    if ledger is None: return
    if purpose == "planning" and not ledger.requirements and value.get("status") in {"act", "done", "needs_choice"}:
        if not value.get("requirements"): fail("requirements", "must enumerate the original request's requirements on the first decision")
    if purpose == "verification" and value.get("verified") is True:
        if type(value.get("coverage_complete")) is not bool:
            fail("coverage_complete", "is required for completion verification")
        if value["coverage_complete"] and not value.get("uncovered_requirements"):
            claimed = {p["requirement_id"] for p in value.get("proofs", [])}
            active_requirements = {identifier for identifier, requirement in ledger.requirements.items()
                                   if requirement.get("state") != "superseded"}
            if claimed != active_requirements: fail("proofs", "must cite evidence for every active checklist requirement")
            output_refs = {ref for proof in value.get("proofs", [])
                           if ledger.requirements[proof["requirement_id"]]["check"]["type"] in {"file_read", "stdout_equals"}
                           for ref in proof["evidence_ids"]}
            if set(value.get("output_evidence_ids", [])) - output_refs:
                fail("output_evidence_ids", "must belong to requested full-output requirements")
            if any(r["state"] != "superseded" and r["check"]["type"] in {"answer", "file_read", "stdout_equals"}
                   for r in ledger.requirements.values()):
                nonempty(value.get("message"), "message")
                for proof in value["proofs"]:
                    check = ledger.requirements[proof["requirement_id"]]["check"]
                    if check["type"] in {"file_read", "stdout_equals"}:
                        text = ledger.exact_output(check, proof["evidence_ids"])
                        native_output = any(ref in value.get("output_evidence_ids", []) and
                                            ledger.matches(check, ledger.evidence[ref]) for ref in proof["evidence_ids"])
                        if text is None or (text not in value["message"] and not native_output):
                            fail("message", "must contain the complete verified requested output")
            if not ledger.batch_complete():
                fail("batch", "every input must have current proof for all of its associated requested outcomes")
    if (purpose == "planning" and ledger.batch_declaration_required_for(proposed) and
            "batch" not in value):
        fail("batch", "is required to classify separate work for each supplied input and associate its outcomes")


class TaskEvidenceLedger:
    def __init__(self, task: str, generation: str | None = None, *, input_scope: str | None = None,
                 exact_input_references: list[dict] | None = None) -> None:
        self._state = RevisionedJSONState()
        self.task, self.generation = task, generation
        self.inputs = TaskInputBindings(task, scope=input_scope,
                                        exact_input_references=exact_input_references)
        self.requirements: dict[str, dict] = {}
        self.instruction_revision = 0
        self.evidence: dict[str, dict] = {}
        self.coverage_complete = False
        self.local_complete_grammar = False
        self.observation_id: str | None = None
        self.current_observation: dict | None = None
        self.observation_checks: dict[str, ExpectedEffect | dict] = {}
        self.dependency_rejections = 0
        self.rejections = self.checks = 0
        self.action_sequence = 0
        self.readback = False
        # Presentation-only objects remain task-scoped and never enter prompt
        # history, completion evidence, or persistent task history.
        self._result_object_cache: dict[str, dict] = {}
        self.batch_mode: str | None = None
        self.batch_items: list[dict] = []
        self.batch_source_input_ids: list[str] = []
        self.batch_excluded_inputs: list[dict] = []
        self.batch_global_requirement_ids: list[str] = []
        self.batch_initialized = False
        self.batch_needs_declaration = False
        self.continuation_checkpoint: dict | None = None
        self.continuation_prior_verified_ids: set[str] = set()
        self.continuation_rechecked_ids: set[str] = set()
        self.continuation_omitted_sources: list[str] = []
        self.continuation_unresolved_receipts = 0
        self.continuation_observation_targets: dict[str, dict] = {}
        self.continuation_expected_identities: dict[str, dict] = {}
        self.continuation_expected_web_destinations: dict[str, str] = {}
        read = re.fullmatch(READ_PATTERN, task, re.I)
        if read:
            self.local_complete_grammar = True
            self.add_requirements([{"source": task, "description": "Return the complete file contents",
                                    "check": {"type": "file_read", "path": read.group(2)}}])
        elif re.fullmatch(LARGEST_PATTERN, task, re.I):
            self.local_complete_grammar = True
            self.add_requirements([{"source": task, "description": "Return the exact largest top-level Downloads file and size",
                                    "check": {"type": "answer", "expected": task}}])

    def initialize_continuation(self, checkpoint: dict) -> None:
        """Start from checkpoint definitions, never historical evidence or actions."""
        if (not isinstance(checkpoint, dict) or checkpoint.get("version") != CONTINUATION_CHECKPOINT_VERSION or
                checkpoint.get("eligible") is not True or
                type(checkpoint.get("instruction_revision")) is not int or checkpoint["instruction_revision"] < 0 or
                type(checkpoint.get("revision")) is not int or checkpoint["revision"] < 1 or
                type(checkpoint.get("unresolved_receipts")) is not int or checkpoint["unresolved_receipts"] != 0 or
                checkpoint.get("task_sha256") != hashlib.sha256(self.task.encode("utf-8")).hexdigest() or
                checkpoint.get("input_references_sha256") != self._input_reference_fingerprint()):
            raise EvidenceValidationError("Continuation checkpoint is stale or malformed")
        if set(checkpoint) - {
            "version", "eligible", "task_sha256", "input_references_sha256", "source_task_generation_id",
            "instruction_revision", "revision", "requirements", "observation_targets",
            "expected_file_identities", "expected_web_destinations", "batch", "result_summaries",
            "unresolved_receipts",
        }:
            raise EvidenceValidationError("Continuation checkpoint contains unsupported fields")
        source_generation = checkpoint.get("source_task_generation_id")
        if (not isinstance(source_generation, str) or
                not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", source_generation) or
                source_generation == self.generation):
            raise EvidenceValidationError("Continuation checkpoint source task is invalid")
        requirements = checkpoint.get("requirements")
        if not isinstance(requirements, list) or not 1 <= len(requirements) <= 512:
            raise EvidenceValidationError("Continuation checkpoint requirements are invalid")
        imported: dict[str, dict] = {}
        prior_verified: set[str] = set()
        for index, item in enumerate(requirements):
            field_path = f"continuation.requirements[{index}]"
            if not isinstance(item, dict) or set(item) - {
                "id", "source", "description", "check", "depends_on", "scope", "previously_proven", "superseded_by"
            }:
                raise EvidenceValidationError(f"{field_path} has unsupported fields")
            if type(item.get("previously_proven")) is not bool:
                raise EvidenceValidationError(f"{field_path}.previously_proven must be a boolean")
            identifier = item.get("id")
            if not isinstance(identifier, str) or not re.fullmatch(r"r[1-9][0-9]*", identifier) or identifier in imported:
                raise EvidenceValidationError(f"{field_path}.id is invalid")
            entry = validate_requirement({key: item[key] for key in ("source", "description", "check", "depends_on", "scope") if key in item},
                                         self.task, field_path)
            check_type = entry["check"].get("type")
            # Checks that cannot be safely rebound to fresh local evidence stay
            # as explicit unfinished visual requirements; old element IDs,
            # command strings, and action sequences never cross the boundary.
            if check_type in OBSERVATION_CHECKS - {"window_active"} or check_type in {
                "command_executed", "command_operation", "stdout_equals", "file_written", "file_append"
            }:
                self.continuation_omitted_sources.append(entry["source"])
                entry["check"] = {"type": "visual", "expected": entry["description"]}
            previously_proven = item.get("previously_proven") is True
            if previously_proven and check_type in FILE_CHECKS | {"window_active"}:
                prior_verified.add(identifier)
            if item.get("superseded_by") is not None:
                replacement = item["superseded_by"]
                if not isinstance(replacement, str) or not re.fullmatch(r"r[1-9][0-9]*", replacement):
                    raise EvidenceValidationError(f"{field_path}.superseded_by is invalid")
                entry["state"] = "superseded"
                entry["superseded_by"] = replacement
            else:
                entry["state"] = "pending"
            entry["evidence_ids"] = []
            imported[identifier] = entry
        for identifier, entry in imported.items():
            for dependency in entry.get("depends_on", []):
                if dependency not in imported:
                    raise EvidenceValidationError(f"continuation.requirements.{identifier}.depends_on references an unknown requirement")
        dependency_order(imported)
        self.requirements = imported
        self.evidence.clear()
        self.coverage_complete = False
        self.local_complete_grammar = False
        self.batch_initialized = False
        observation_targets = checkpoint.get("observation_targets", {})
        if not isinstance(observation_targets, dict):
            raise EvidenceValidationError("Continuation checkpoint targets are invalid")
        self.continuation_observation_targets = deepcopy(observation_targets)
        for identifier, target in self.continuation_observation_targets.items():
            if (identifier not in imported or imported[identifier].get("check", {}).get("type") != "window_active" or
                    not isinstance(target, dict) or set(target) - {"pid", "name", "bundle_id"} or
                    type(target.get("pid")) is not int or target["pid"] <= 0 or
                    not isinstance(target.get("bundle_id"), str) or not target["bundle_id"]):
                raise EvidenceValidationError("Continuation checkpoint contains an invalid app/window identity")
        for identifier in prior_verified:
            if (self.requirements[identifier].get("check", {}).get("type") == "window_active" and
                    identifier not in self.continuation_observation_targets):
                raise EvidenceValidationError("Continuation checkpoint cannot safely rebind a prior window result")
        expected_identities = checkpoint.get("expected_file_identities", {})
        if not isinstance(expected_identities, dict) or set(expected_identities) - prior_verified:
            raise EvidenceValidationError("Continuation checkpoint file identities are invalid")
        for identifier, identity in expected_identities.items():
            if (self.requirements[identifier].get("check", {}).get("type") not in FILE_CHECKS or
                    not isinstance(identity, dict) or not identity or
                    set(identity) - {"file_identity", "file_version", "parent_identity"} or
                    any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
                        for value in identity.values())):
                raise EvidenceValidationError("Continuation checkpoint contains an invalid file identity")
        self.continuation_expected_identities = deepcopy(expected_identities)
        expected_web_destinations = checkpoint.get("expected_web_destinations", {})
        if not isinstance(expected_web_destinations, dict) or set(expected_web_destinations) - prior_verified:
            raise EvidenceValidationError("Continuation checkpoint web destinations are invalid")
        for identifier, fingerprint in expected_web_destinations.items():
            if (self.requirements[identifier].get("check", {}).get("type") != "window_active" or
                    not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint)):
                raise EvidenceValidationError("Continuation checkpoint contains an invalid web destination fingerprint")
        self.continuation_expected_web_destinations = deepcopy(expected_web_destinations)
        for identifier, item in imported.items():
            replacement = item.get("superseded_by")
            if replacement is not None and (replacement not in imported or imported[replacement].get("state") == "superseded"):
                raise EvidenceValidationError(f"continuation.requirements.{identifier}.superseded_by is invalid")
        declaration = checkpoint.get("batch")
        if declaration is not None:
            normalized = validate_batch_declaration(declaration, self, imported)
            self.accept_batch(normalized)
            self.batch_initialized = True
            self.batch_needs_declaration = False
        self.continuation_prior_verified_ids = prior_verified
        self.continuation_unresolved_receipts = checkpoint.get("unresolved_receipts", 0)
        if type(self.continuation_unresolved_receipts) is not int or not 0 <= self.continuation_unresolved_receipts <= 4096:
            raise EvidenceValidationError("Continuation checkpoint receipt state is invalid")
        self.continuation_checkpoint = {
            "version": CONTINUATION_CHECKPOINT_VERSION,
            "result_summaries": checkpoint.get("result_summaries", []),
            "omitted_sources": list(dict.fromkeys(self.continuation_omitted_sources))[:64],
        }
        summaries = checkpoint.get("result_summaries", [])
        if (not isinstance(summaries, list) or len(summaries) > 64 or
                any(not isinstance(item, dict) or set(item) - {"kind", "name", "location"} or
                    item.get("kind") not in {"file", "folder", "web"} or
                    any(not isinstance(item.get(key), str) or len(item[key].encode("utf-8")) > 512
                        for key in ("name", "location")) for item in summaries)):
            raise EvidenceValidationError("Continuation checkpoint result summaries are invalid")
        self.continuation_checkpoint["result_summaries"] = deepcopy(summaries)
        self.refresh()

    def _rebind_continuation_observation_targets(self, observation: dict) -> None:
        """Rebind only a unique app/window identity, never a title by itself."""
        if not self.continuation_observation_targets:
            return
        indexes = observation_indexes(observation)
        for identifier, identity in list(self.continuation_observation_targets.items()):
            requirement = self.requirements.get(identifier)
            if not requirement or requirement.get("check", {}).get("type") != "window_active":
                continue
            bundle_id = identity.get("bundle_id")
            title = requirement["check"].get("title")
            if not isinstance(bundle_id, str) or not isinstance(title, str):
                continue
            apps = [app for app in indexes.applications if app.get("bundle_id") == bundle_id and
                    (not identity.get("name") or app.get("name") == identity.get("name"))]
            if len(apps) != 1:
                continue
            app = apps[0]
            windows = [window for window in app.get("windows", [])
                       if isinstance(window, dict) and window.get("title") == title]
            if not windows:
                windows = [window for window in app.get("graphics_windows", [])
                           if isinstance(window, dict) and window.get("title") == title]
            if len(windows) != 1:
                continue
            requirement["check"]["pid"] = app["pid"]
            self.continuation_observation_targets.pop(identifier, None)

    def continuation_snapshot(self, *, instruction_revision: int, unresolved_receipts: int,
                              revision: int) -> dict | None:
        """Produce a bounded recovery capsule from current validated ledger state."""
        self.refresh()
        if (type(unresolved_receipts) is not int or unresolved_receipts != 0 or
                type(revision) is not int or revision < 1):
            return None
        recheckable = FILE_CHECKS | {"window_active"}
        prior_proven = {
            identifier for identifier, item in self.requirements.items()
            if item.get("state") != "superseded" and item.get("scope", "outcome") != "prerequisite" and
            item.get("check", {}).get("type") in recheckable and self._has_historical_proof(identifier)
        }
        if not prior_proven or type(instruction_revision) is not int or instruction_revision < 0:
            return None
        projected_results = self._presentation_result_objects()
        entries = []
        targets: dict[str, dict] = {}
        expected_file_identities: dict[str, dict] = {}
        expected_web_destinations: dict[str, str] = {}
        for identifier, item in self.requirements.items():
            entry = {key: deepcopy(item[key]) for key in ("source", "description", "check", "depends_on", "scope", "superseded_by") if key in item}
            check_type = entry["check"].get("type")
            recheckable_observation = False
            if check_type == "window_active":
                pinned = self.observation_checks.get(identifier)
                recheckable_observation = (isinstance(pinned, dict) and
                                           type(pinned.get("pid")) is int and pinned["pid"] > 0 and
                                           isinstance(pinned.get("bundle_id"), str) and bool(pinned.get("bundle_id")) and
                                           isinstance(item.get("check", {}).get("title"), str))
                if recheckable_observation:
                    targets[identifier] = {key: pinned[key] for key in ("pid", "name", "bundle_id") if key in pinned}
                else:
                    entry["check"] = {"type": "visual", "expected": entry["description"]}
                    self.continuation_omitted_sources.append(entry["source"])
            elif check_type in OBSERVATION_CHECKS:
                entry["check"] = {"type": "visual", "expected": entry["description"]}
            elif check_type in {"command_executed", "command_operation", "stdout_equals", "file_written", "file_append"}:
                entry["check"] = {"type": "visual", "expected": entry["description"]}
            is_prior_recheckable = (identifier in prior_proven and
                                    (check_type in FILE_CHECKS or recheckable_observation))
            if is_prior_recheckable:
                entry["previously_proven"] = True
                if check_type in FILE_CHECKS:
                    candidates = [evidence for evidence in self.evidence.values()
                                  if evidence.get("generation") == self.generation and
                                  self.requirement_matches(identifier, {**evidence, "valid": True})]
                    if candidates:
                        identity = {key: candidates[-1]["fact"][key] for key in
                                    ("file_identity", "file_version", "parent_identity")
                                    if isinstance(candidates[-1].get("fact", {}).get(key), str)}
                        if identity:
                            expected_file_identities[identifier] = identity
                elif check_type == "window_active":
                    web_result = next((result for result in self._result_object_cache.values()
                                       if result.get("kind") == "web" and result.get("state") == "verified" and
                                       result.get("_requirement_id") == identifier and
                                       isinstance(result.get("url"), str)), None)
                    if web_result is not None:
                        expected_web_destinations[identifier] = hashlib.sha256(
                            web_result["url"].encode("utf-8")).hexdigest()
            else:
                entry["previously_proven"] = False
            entry["id"] = identifier
            entries.append(entry)
        summaries = [item for item in projected_results if item.get("state") in {"verified", "needs_recheck"}]
        summaries = [{key: item[key] for key in ("kind", "name", "location") if isinstance(item.get(key), str)}
                     for item in summaries[:64]]
        capsule = {
            "version": CONTINUATION_CHECKPOINT_VERSION,
            "task_sha256": hashlib.sha256(self.task.encode("utf-8")).hexdigest(),
            "input_references_sha256": self._input_reference_fingerprint(),
            "source_task_generation_id": self.generation,
            "instruction_revision": instruction_revision,
            "revision": revision,
            "requirements": entries,
            "observation_targets": targets,
            "expected_file_identities": expected_file_identities,
            "expected_web_destinations": expected_web_destinations,
            "batch": deepcopy(self.batch_declaration()) if self.batch_initialized else None,
            "result_summaries": summaries,
            "unresolved_receipts": unresolved_receipts,
        }
        encoded = json.dumps(capsule, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
        if len(encoded) > 262_144 or len(entries) > 512:
            return None
        return capsule

    def _input_reference_fingerprint(self) -> str:
        digest_value = hashlib.sha256()
        for kind, start, length, value in self.inputs.exact_references:
            for part in (kind, start, length, value):
                encoded = str(part).encode("utf-8")
                digest_value.update(len(encoded).to_bytes(8, "big"))
                digest_value.update(encoded)
        return digest_value.hexdigest()

    def _has_historical_proof(self, identifier: str) -> bool:
        requirement = self.requirements.get(identifier)
        if not requirement or requirement.get("state") == "superseded":
            return False
        if requirement.get("state") == "proven" and requirement.get("evidence_ids"):
            return True
        for evidence in self.evidence.values():
            if evidence.get("generation") != self.generation:
                continue
            if self.requirement_matches(identifier, {**evidence, "valid": True}):
                return True
        return False

    def add_requirements(self, entries: list[dict], observation: dict | None = None, *, path="requirements") -> bool:
        previous_outcomes = {identifier for identifier, requirement in self.requirements.items()
                             if requirement.get("state") != "superseded" and
                             requirement.get("scope", "outcome") != "prerequisite"}
        proposed = project_requirements(self.requirements, self.canonical_entries(entries, observation), self.task, path)
        self.validate_observation_checks(proposed, observation)
        changed = proposed != self.requirements
        self.requirements = proposed
        current_outcomes = {identifier for identifier, requirement in self.requirements.items()
                            if requirement.get("state") != "superseded" and
                            requirement.get("scope", "outcome") != "prerequisite"}
        if (self.batch_initialized and
                current_outcomes - set(self.batch_global_requirement_ids) -
                {ref for item in self.batch_items for ref in item.get("requirement_ids", [])}):
            self.batch_needs_declaration = True
        self.bind_observation_checks(observation or self.current_observation)
        if changed: self.coverage_complete = False
        self.record_observation_checks()
        self.refresh()
        return changed

    def accept_plan(self, decision: dict, observation: dict | None = None) -> None:
        self.add_requirements(decision.get("requirements", []), observation)
        if "batch" in decision:
            self.accept_batch(decision["batch"])

    def batch_declaration_required_for(self, proposed: dict | None = None) -> bool:
        if len(self.batch_source_candidates()) < 2 or not requests_per_input_work(self.task):
            return False
        if not self.batch_initialized or self.batch_needs_declaration:
            return True
        active = proposed if proposed is not None else self.requirements
        outcome_ids = {identifier for identifier, requirement in active.items()
                       if requirement.get("state") != "superseded" and
                       requirement.get("scope", "outcome") != "prerequisite"}
        assigned = set(self.batch_global_requirement_ids)
        assigned.update(ref for item in self.batch_items for ref in item.get("requirement_ids", []))
        return outcome_ids != assigned

    def batch_source_candidates(self):
        """Resource references not plainly described as output destinations."""
        return tuple(entry for entry in self.inputs.resource_inputs
                     if not is_output_destination(self.task, entry))

    def batch_declaration(self) -> dict:
        items = []
        if self.batch_mode == "per_input":
            items = [{"input_id": item["input_id"], "requirement_ids": list(item["requirement_ids"])}
                     for item in self.batch_items]
        return {"mode": self.batch_mode, "items": items,
                "source_input_ids": list(self.batch_source_input_ids),
                "excluded_inputs": deepcopy(self.batch_excluded_inputs),
                "global_requirement_ids": list(self.batch_global_requirement_ids)}

    def accept_batch(self, declaration: dict) -> None:
        by_id = {entry.identifier: entry for entry in self.inputs.resource_inputs}
        previous = {item["reference"]: item for item in self.batch_items}
        self.batch_mode = declaration["mode"]
        self.batch_source_input_ids = list(declaration["source_input_ids"])
        self.batch_excluded_inputs = deepcopy(declaration["excluded_inputs"])
        self.batch_global_requirement_ids = list(declaration["global_requirement_ids"])
        self.batch_items = []
        next_batch_number = max((int(item["id"][1:]) for item in previous.values()
                                 if re.fullmatch(r"b[1-9][0-9]*", item.get("id", ""))), default=0) + 1
        if self.batch_mode == "per_input":
            for item in declaration["items"]:
                entry = by_id[item["input_id"]]
                old = previous.get(entry.value)
                item_id = old["id"] if old else f"b{next_batch_number}"
                if old is None:
                    next_batch_number += 1
                self.batch_items.append({
                    "id": item_id,
                    "input_id": entry.identifier, "reference": entry.value,
                    "kind": entry.resource_kind or entry.kind,
                    "requirement_ids": list(item["requirement_ids"]),
                })
        self.batch_initialized = True
        self.batch_needs_declaration = False

    def batch_complete(self) -> bool:
        self.refresh()
        if self.batch_mode != "per_input":
            return not self.batch_declaration_required_for()
        if self.batch_needs_declaration or len(self.batch_items) < 2:
            return False
        outcome_ids = {identifier for identifier, requirement in self.requirements.items()
                       if requirement.get("state") != "superseded" and
                       requirement.get("scope", "outcome") != "prerequisite"}
        mapped = set(self.batch_global_requirement_ids)
        for item in self.batch_items:
            requirement_ids = item.get("requirement_ids", [])
            if not requirement_ids:
                return False
            for identifier in requirement_ids:
                requirement = self.requirements.get(identifier)
                if (requirement is None or requirement.get("state") == "superseded" or
                        requirement.get("scope", "outcome") == "prerequisite" or
                        requirement.get("state") != "proven"):
                    return False
                mapped.add(identifier)
        return mapped == outcome_ids and all(
            self.requirements[identifier].get("state") == "proven" for identifier in self.batch_global_requirement_ids
            if identifier in self.requirements and self.requirements[identifier].get("state") != "superseded"
        )

    def apply_instruction_revision(self, task: str, exact_input_references: list[dict]) -> None:
        """Retain history while making all prior proof provisional for revised instructions."""
        previous_items = {item["reference"]: deepcopy(item) for item in self.batch_items}
        next_batch_number = max((int(item["id"][1:]) for item in self.batch_items
                                 if re.fullmatch(r"b[1-9][0-9]*", item.get("id", ""))), default=0) + 1
        self.task = task
        self.instruction_revision += 1
        self.inputs = TaskInputBindings(task, exact_input_references=exact_input_references)
        current_resources = self.batch_source_candidates()
        self.batch_items = []
        for entry in current_resources:
            old = previous_items.get(entry.value)
            item_id = old["id"] if old else f"b{next_batch_number}"
            if old is None:
                next_batch_number += 1
            self.batch_items.append({
                "id": item_id, "input_id": entry.identifier, "reference": entry.value,
                "kind": entry.resource_kind or entry.kind,
                "requirement_ids": list(old.get("requirement_ids", [])) if old else [],
            })
        self.batch_mode = "per_input" if len(current_resources) >= 2 and requests_per_input_work(task) else None
        self.batch_source_input_ids = [entry.identifier for entry in current_resources] if self.batch_mode else []
        self.batch_excluded_inputs = []
        self.batch_global_requirement_ids = []
        self.batch_initialized = False
        self.batch_needs_declaration = self.batch_mode == "per_input"
        self.coverage_complete = False
        self.local_complete_grammar = False
        self.observation_id = None
        self.current_observation = None
        self.observation_checks.clear()
        # Immutable action facts remain useful when a correction leaves their
        # scope unchanged. Mutable screen/file state must be inspected again.
        for evidence in self.evidence.values():
            if evidence["mutable"]:
                evidence["valid"] = False
        for requirement in self.requirements.values():
            if requirement.get("state") != "superseded":
                requirement["state"] = "invalidated" if requirement.get("evidence_ids") else "pending"
            requirement["evidence_ids"] = []
        self.refresh()

    def apply_working_document_revision(self) -> None:
        """Invalidate target-sensitive proof without discarding execution history."""
        self.coverage_complete = False
        self.local_complete_grammar = False
        self.observation_id = None
        self.current_observation = None
        self.observation_checks.clear()
        target_sensitive = OBSERVATION_CHECKS | {"observation", "requirement_observed"}
        for evidence in self.evidence.values():
            if evidence["valid"] and (evidence["mutable"] or evidence["fact"].get("type") in target_sensitive):
                evidence["valid"] = False
        for requirement in self.requirements.values():
            if requirement.get("state") == "superseded":
                continue
            if requirement.get("check", {}).get("type") in OBSERVATION_CHECKS:
                requirement["state"] = "invalidated" if requirement.get("evidence_ids") else "pending"
                requirement["evidence_ids"] = []
        self.refresh()

    def canonical_entries(self, entries: list[dict], observation: dict | None = None) -> list[dict]:
        """A fresh control ID may describe the same already-bound requirement."""
        observation = observation or self.current_observation
        result = deepcopy(entries)
        if observation is None: return result
        for entry in result:
            if not isinstance(entry, dict): continue
            check = entry.get("check", {})
            if not isinstance(check, dict) or check.get("type") != "field_value" or not isinstance(entry.get("source"), str): continue
            for identifier, pinned in self.observation_checks.items():
                old = self.requirements[identifier]
                if not isinstance(pinned, ExpectedEffect) or pinned.kind != "field_value" or old["source"] != entry["source"]: continue
                if {k: v for k, v in old["check"].items() if k != "element_id"} != {k: v for k, v in check.items() if k != "element_id"}: continue
                candidates = pinned.field_candidates(observation)
                if len(pinned.unique(candidates)) == 1 and check.get("element_id") in {e.get("id") for e in candidates}:
                    entry["check"] = deepcopy(old["check"])
                    break
        return result

    def validate_observation_checks(self, proposed: dict, observation: dict | None = None) -> None:
        observation = observation or self.current_observation
        if observation is None: return
        for identifier, entry in proposed.items():
            check = entry["check"]
            if check["type"] not in OBSERVATION_CHECKS or identifier in self.observation_checks: continue
            try:
                if check["type"] == "field_value": validate_expectation(check, observation)
                elif check["pid"] not in observation_indexes(observation).applications_by_pid:
                    fail(f"requirements.{identifier}.check.pid", "must reference an app in the current observation")
            except ExpectedEffectError as error:
                raise EvidenceValidationError(str(error).replace("expected_result", f"requirements.{identifier}.check", 1)) from error

    def bind_observation_checks(self, observation: dict | None) -> None:
        if observation is None: return
        for identifier, entry in self.requirements.items():
            check = entry["check"]
            if check["type"] not in OBSERVATION_CHECKS or identifier in self.observation_checks: continue
            if check["type"] == "window_active":
                app = observation_indexes(observation).application(check["pid"])
                if app: self.observation_checks[identifier] = {k: app.get(k) for k in ("pid", "name", "bundle_id")}
            else:
                before = observation if check["type"] == "field_value" else {**observation, "elements": []}
                self.observation_checks[identifier] = ExpectedEffect(
                    {**check, "type": "dialog_appeared" if check["type"] == "dialog_present" else check["type"]}, before)

    def record_observation_checks(self) -> None:
        observation = self.current_observation
        if observation is None: return
        for identifier, pinned in self.observation_checks.items():
            check = self.requirements[identifier]["check"]
            if isinstance(pinned, ExpectedEffect):
                proof = pinned.observe(observation)
                element = observation_indexes(observation).element(proof.get("element_id")) or {}
                proven = proof["outcome"] == "verified" and element.get("enabled") is True
            else:
                app = observation_indexes(observation).application(check["pid"]) or {}
                native_windows = app.get("windows", [])
                if not any("title" in w for w in native_windows):
                    native_windows = [{**w, "topmost_on_agent_screen": index == 0}
                                      for index, w in enumerate(app.get("graphics_windows", []))]
                windows = [w for w in native_windows if w.get("title") == check["title"]]
                proven = (all(app.get(k) == v for k, v in pinned.items()) and
                          app.get("topmost_on_agent_screen") is True and len(windows) == 1 and
                          windows[0].get("topmost_on_agent_screen") is True)
                expected_web_fingerprint = self.continuation_expected_web_destinations.get(identifier)
                if proven and expected_web_fingerprint is not None:
                    revision = observation.get("observation_revision")
                    destinations = observation.get("result_destinations", [])
                    matching_destinations = [destination for destination in destinations
                                             if isinstance(destination, dict) and
                                             destination.get("pid") == check["pid"] and
                                             destination.get("window_title") == check["title"] and
                                             destination.get("bundle_id") == app.get("bundle_id") and
                                             destination.get("observation_revision") == revision]
                    proven = any(
                        (safe_destination := self._safe_web_destination(destination.get("url"))) is not None and
                        hashlib.sha256(safe_destination[0].encode("utf-8")).hexdigest() == expected_web_fingerprint
                        for destination in matching_destinations
                    )
            if not proven: continue
            fact = {"type": "requirement_observed", "requirement_id": identifier,
                    "check_fingerprint": digest(check), "revision": observation["observation_revision"]}
            if not any(e["valid"] and e["fact"] == fact for e in self.evidence.values()):
                self.add_evidence(fact, mutable=True)
            if identifier in self.continuation_prior_verified_ids:
                self.continuation_rechecked_ids.add(identifier)

    def requirement_matches(self, identifier: str, evidence: dict, *, semantic=False, current=False) -> bool:
        requirement = self.requirements[identifier]
        fact = evidence["fact"]
        if (not current and requirement.get("scope") == "prerequisite" and evidence["valid"] and
                evidence["generation"] == self.generation and fact.get("type") == "prerequisite_checked"):
            return fact.get("requirement_id") == identifier and fact.get("check_fingerprint") == digest(requirement["check"])
        return self.matches(requirement["check"], evidence, semantic=semantic)

    def action_requirements(self, decision: dict) -> list[str]:
        """Include deterministic effect matches even if a decision mislabels them."""
        selected = [identifier for identifier in decision.get("requirement_ids", [])
                    if identifier in self.requirements and self.requirements[identifier].get("state") != "superseded"]
        action = decision.get("action", {})
        if not any(r.get("state") != "superseded" and r.get("depends_on")
                   for r in self.requirements.values()): return selected
        for identifier, entry in self.requirements.items():
            if entry.get("state") == "superseded": continue
            check = entry["check"]
            matched = (action.get("type") == "write_file" and check["type"] in {"file_exists", "file_contents", "file_written", "file_append"} and
                       path_key(check["path"]) == path_key(action["path"]) and
                       ("content" not in check or content_hash(check) == content_hash(action)))
            if action.get("type") == "run_command":
                matched |= check == {"type": "command_executed", **{k: action[k] for k in ("argv", "command", "working_directory") if k in action}}
                matched |= check.get("type") == "command_operation" and check.get("operation") == action.get("operation")
                matched |= any(check == outcome for outcome in action.get("checks", []))
            if check == decision.get("expected_result"): matched = True
            if matched and identifier not in selected: selected.append(identifier)
        return selected

    def prerequisites(self, identifiers: list[str]) -> list[str]:
        pending, required = list(identifiers), set()
        while pending:
            identifier = pending.pop()
            for ref in self.requirements[identifier].get("depends_on", []):
                if ref not in required:
                    required.add(ref)
                    pending.append(ref)
        return [ref for ref in dependency_order(self.requirements) if ref in required]

    def check_prerequisites(self, decision: dict, *, retain=False) -> dict | None:
        identifiers = self.action_requirements(decision)
        if any(r.get("depends_on") for r in self.requirements.values()) and not identifiers:
            return {"blocked_by": [], "reason": "action_requirement_missing"}
        required = self.prerequisites(identifiers)
        direct = {ref for identifier in identifiers for ref in self.requirements[identifier].get("depends_on", [])}
        self.refresh()
        refs = {ref: [key for key, e in self.evidence.items() if self.requirement_matches(ref, e, current=ref in direct)]
                for ref in required}
        blocked = [ref for ref in required if not refs[ref] or self.requirements[ref]["state"] != "proven"]
        if blocked: return {"blocked_by": blocked, "reason": "prerequisite_unproven"}
        action = decision.get("action", {})
        controls = (self.current_observation or {}).get("elements", [])
        target = next((e for e in controls if e.get("id") == action.get("element_id")), None)
        for ref in direct:
            check = self.requirements[ref]["check"]
            if check["type"] != "window_active" or action.get("type") not in {"press", "focus", "set_value", "type_text", "key", "click", "double_click", "scroll"}: continue
            pid = target.get("pid") if target else action.get("pid")
            candidates = [target] if target else coordinate_targets(action, self.current_observation or {})
            if not candidates and action.get("type") in {"key", "type_text"}:
                candidates = [e for e in controls if e.get("pid") == pid and e.get("focused") is True]
            if pid != check["pid"] or any(e.get("window_title") and e["window_title"] != check["title"] for e in candidates):
                return {"blocked_by": [ref], "reason": "prerequisite_target_mismatch"}
        for identifier in identifiers:
            check = self.requirements[identifier]["check"]
            if action.get("type") == "write_file" and "path" in check and path_key(action["path"]) != path_key(check["path"]):
                return {"blocked_by": [], "reason": "action_requirement_target_mismatch"}
            target = self.observation_checks.get(identifier)
            if isinstance(target, ExpectedEffect) and target.kind == "field_value":
                if action.get("type") in {"type_text", "set_value", "focus", "press", "click", "double_click"}:
                    candidates = target.field_candidates(self.current_observation or {})
                    if len(target.unique(candidates)) != 1 or action.get("element_id") not in {e.get("id") for e in candidates}:
                        return {"blocked_by": [], "reason": "action_requirement_target_mismatch"}
        if retain:
            for ref in required:
                if self.requirements[ref].get("scope") != "prerequisite": continue
                if any(self.evidence[key]["fact"].get("type") == "prerequisite_checked" for key in refs[ref]): continue
                fact = {"type": "prerequisite_checked", "requirement_id": ref,
                        "check_fingerprint": digest(self.requirements[ref]["check"]),
                        "before_action": self.action_sequence + 1,
                        "witnesses": [deepcopy(self.evidence[key]["fact"]) for key in refs[ref]]}
                self.add_evidence(fact)
        return None

    def add_evidence(self, fact: dict, *, mutable=False, action=None) -> str:
        validate_native_payload('evidence_fact', fact, 'evidence.fact')
        identifier = f"e{len(self.evidence) + 1}"
        evidence = {"fact": deepcopy(fact), "mutable": mutable, "valid": True,
                    "verified": True, "verification_scope": fact.get("type"),
                    "action": deepcopy(action), "generation": self.generation,
                    "origin": ({"action_id": f"a{self.action_sequence}", "method": "readback" if self.readback else "execution"} if action else None),
                    "fact_fingerprint": digest(fact), "action_fingerprint": digest(action)}
        validate_native_evidence(evidence)
        self.evidence[identifier] = evidence
        self.refresh()
        return identifier

    def observe(self, observation: dict) -> None:
        # bridge_call already checks then removes the private wire generation.
        if self.generation and observation.get("task_generation_id", self.generation) != self.generation:
            fail("observation", "belongs to another task")
        revision = observation.get("observation_revision")
        nonempty(revision, "observation.observation_revision")
        self.invalidate(lambda e: e["fact"]["type"] == "observation")
        self.invalidate(lambda e: e["fact"]["type"] == "requirement_observed")
        self.current_observation = observation
        self._rebind_continuation_observation_targets(observation)
        self.observation_id = self.add_evidence({"type": "observation", "revision": revision})
        self.bind_observation_checks(observation)
        self.record_observation_checks()

    def invalidate(self, predicate) -> None:
        changed = False
        for evidence in self.evidence.values():
            if evidence["valid"] and predicate(evidence):
                evidence["valid"] = False
                changed = True
        if changed: self.coverage_complete = False
        self.refresh()

    def before_action(self, action: dict) -> None:
        kind = action.get("type")
        if kind in {"none", "wait", "read_file"}: return
        # Paths can alias and commands can mutate arbitrary resources. Be
        # conservative; a cheap local recheck is safer than inferring effects.
        self.invalidate(lambda e: e["fact"]["type"] == "observation" or e["mutable"])

    def record_action(self, action: dict, result: dict, *, recheck=False) -> None:
        try: action = validate_action(action)
        except ActionContractError: return
        kind = action["type"]
        if kind in {"none", "wait"}: return
        if recheck: validate_native_readback(result, action)
        else: validate_native_result(result, action)
        self.action_sequence += 1
        self.readback = recheck
        if recheck:
            self.checks += 1
            for check, actual in zip(result.get("requested_checks", []), result.get("checks", [])):
                self.record_check(check, actual, action)
            if kind == 'run_command': self.record_operation(action, result, recheck=True)
            if kind != "read_file": return
        identity = {key: result[key] for key in ("file_identity", "file_version", "parent_identity", "file_sha256") if key in result}
        if kind == "read_file":
            if (result.get("path") != path_key(action["path"]) or result.get("truncated") is not False or
                    type(result.get("bytes_returned")) is not int or not isinstance(result.get("content"), str) or
                    result.get("encoding") not in {"utf-8", "base64"}): return
            try: data = content_bytes(result)
            except (ValueError, UnicodeEncodeError): return
            if len(data) != result["bytes_returned"] or hashlib.sha256(data).hexdigest() != result.get("content_sha256"): return
            self.add_evidence({"type": "file_read", "path": result["path"], "content": result["content"],
                               "encoding": result["encoding"], "content_sha256": result["content_sha256"], **identity}, mutable=True, action=action)
        elif kind == "write_file":
            if (result.get("verified") is not True or result.get("path") != path_key(action["path"]) or
                    result.get("mode") != action.get("mode", "overwrite").lower() or
                    result.get("content_sha256") != content_hash(action) or
                    type(result.get("bytes_written")) is not int or result["bytes_written"] != len(content_bytes(action))): return
            self.add_evidence({"type": "file_written", "path": result["path"], "mode": result["mode"],
                               "content_sha256": result["content_sha256"], **identity}, action=action)
            fact = {"type": "file_append" if result["mode"] == "append" else "file_contents",
                    "path": result["path"], "content_sha256": result["content_sha256"], **identity}
            self.add_evidence(fact, mutable=result["mode"] != "append", action=action)
            self.add_evidence({"type": "file_exists", "path": result["path"], **identity}, mutable=True, action=action)
        elif kind == "run_command":
            if result.get("timed_out") is not False or type(result.get("exit_code")) is not int or result["exit_code"] != 0: return
            fact = {"type": "command_executed", **{k: action[k] for k in ("argv", "command") if k in action},
                    "working_directory": result.get("working_directory")}
            self.add_evidence(fact, action=action)
            expected, actual = action.get("checks", []), result.get("checks", [])
            if len(expected) != len(actual): return
            for check, checked in zip(expected, actual):
                self.record_check(check, checked, action)
            self.record_operation(action, result)

    def record_operation(self, action: dict, result: dict, recheck=False) -> None:
        operation = action.get('operation')
        if not operation: return
        snapshot = CONTRACT['command_operations'][operation['type']].get('snapshot')
        if snapshot and not any(c.get('type') == 'file_contents' and c.get('encoding') == 'base64'
                                and c.get('path') == operation[snapshot['destination']] for c in action['checks']): return
        if recheck:
            if result.get('requested_checks') != [c for c in action['checks'] if c['type'] != 'stdout_equals']: return
            if not any(e['generation'] == self.generation and e['fact'].get('type') == 'command_operation'
                       and e['action_fingerprint'] == digest(action) for e in self.evidence.values()): return
        elif result.get('command_operation') != operation or result.get('outcome_checks') != action.get('checks'):
            return
        expected = [c for c in action['checks'] if not recheck or c['type'] != 'stdout_equals']
        actual = result.get('checks', [])
        if not expected or len(expected) != len(actual): return
        proven = all(self.check_matches(c, a) for c, a in zip(expected, actual))
        identifier = self.add_evidence({'type': 'command_operation', 'operation': operation},
                                       mutable=any(c['type'] in FILE_CHECKS for c in expected), action=action)
        if not proven:
            self.evidence[identifier]['valid'] = False
            self.refresh()

    @staticmethod
    def check_matches(check: dict, actual: dict) -> bool:
        if not isinstance(actual, dict) or actual.get('verified') is not True or actual.get('type') != check.get('type'): return False
        if check['type'] in FILE_CHECKS:
            return (actual.get('path') == path_key(check['path']) and
                    (check['type'] != 'file_contents' or actual.get('content_sha256') == content_hash(check)))
        return check['type'] == 'stdout_equals' and actual.get('text_sha256') == hashlib.sha256(check['text'].encode()).hexdigest()

    def record_check(self, check: dict, actual: dict, action: dict) -> None:
        validate_native_payload('check_result', actual, 'check_result')
        if (not isinstance(check, dict) or not isinstance(actual, dict) or
                actual.get("verified") is not True or actual.get("type") != check.get("type")): return
        kind = check["type"]
        if kind in FILE_CHECKS:
            if actual.get("path") != path_key(check["path"]): return
            fact = {"type": kind, "path": actual["path"], **{key: actual[key] for key in
                    ("file_identity", "file_version", "parent_identity") if key in actual}}
            if kind == "file_contents":
                if actual.get("content_sha256") != content_hash(check): return
                fact["content_sha256"] = actual["content_sha256"]
            self.add_evidence(fact, mutable=True, action=action)
        elif kind == "stdout_equals":
            if actual.get("text_sha256") != hashlib.sha256(check["text"].encode()).hexdigest(): return
            self.add_evidence({"type": kind, "text": check["text"]}, action=action)

    def record_effect(self, check: dict, actual: dict, action: dict | None = None) -> None:
        """Only validated local checks enter this path; model claims do not."""
        try: check = validate_outcome_check(check)
        except ActionContractError: return
        validate_native_payload('check_result', actual, 'check_result')
        if check.get('type') not in FILE_CHECKS: return
        if action is None:
            for requirement_id, expected in self.continuation_expected_identities.items():
                requirement = self.requirements.get(requirement_id)
                if requirement and requirement.get("check") == check and any(
                    actual.get(key) != value for key, value in expected.items()
                ):
                    return
        if any(self.matches(check, evidence) for evidence in self.evidence.values()): return
        self.checks += 1
        self.readback = True
        previous = set(self.evidence)
        self.record_check(check, actual, action)
        for identifier in set(self.evidence) - previous:
            self.evidence[identifier]['effect_check'] = deepcopy(check)
        if actual.get("verified") is True:
            for evidence_id in set(self.evidence) - previous:
                evidence = self.evidence[evidence_id]
                for requirement_id in self.continuation_prior_verified_ids:
                    if requirement_id in self.requirements and self.requirement_matches(requirement_id, evidence):
                        self.continuation_rechecked_ids.add(requirement_id)

    def matches(self, check: dict, evidence: dict, *, semantic=False) -> bool:
        if not evidence["valid"] or evidence["generation"] != self.generation: return False
        fact, kind = evidence["fact"], check["type"]
        if kind == "visual": return semantic and fact["type"] == "observation"
        if kind == "answer":
            return semantic and fact["type"] in {"observation", "file_read", "stdout_equals", "local_answer"}
        if kind in OBSERVATION_CHECKS:
            return fact["type"] == "requirement_observed" and fact.get("check_fingerprint") == digest(check)
        if kind == "file_contents" and fact["type"] == "file_read":
            return path_key(check["path"]) == fact["path"] and content_hash(check) == fact["content_sha256"]
        if kind == "file_exists" and fact["type"] == "file_contents":
            return path_key(check["path"]) == fact["path"]
        if kind != fact["type"]: return False
        if "path" in check and path_key(check["path"]) != fact.get("path"): return False
        if kind in {"file_contents", "file_append"}: return content_hash(check) == fact.get("content_sha256")
        if kind == "file_written": return content_hash(check) == fact.get("content_sha256") and check.get("mode", "overwrite") == fact.get("mode")
        if kind == "stdout_equals": return check["text"] == fact.get("text")
        if kind == "command_executed":
            return (all(check.get(k) == fact.get(k) for k in ("argv", "command")) and
                    ("working_directory" not in check or path_key(check["working_directory"]) == fact.get("working_directory")))
        if kind == 'command_operation': return check['operation'] == fact.get('operation')
        return True

    def refresh(self) -> None:
        for identifier in dependency_order(self.requirements):
            requirement = self.requirements[identifier]
            if requirement.get("state") == "superseded":
                requirement["evidence_ids"] = []
                continue
            refs = [ref for ref, e in self.evidence.items() if self.requirement_matches(identifier, e)]
            old = requirement["evidence_ids"]
            if requirement["check"]["type"] in {"visual", "answer"}:
                refs = [ref for ref in old if self.requirement_matches(identifier, self.evidence[ref], semantic=True)]
            if any(self.requirements[ref]["state"] != "proven" for ref in requirement.get("depends_on", [])):
                refs = []
            requirement["state"] = "proven" if refs else ("invalidated" if old or requirement["state"] == "invalidated" else "pending")
            requirement["evidence_ids"] = refs

    def exact_output(self, check: dict, refs: list[str]) -> str | None:
        for ref in refs:
            fact = self.evidence[ref]["fact"]
            if self.matches(check, self.evidence[ref], semantic=True):
                if check["type"] == "file_read":
                    return ("[Binary file; base64 encoded]\n" if fact["encoding"] == "base64" else "") + fact["content"]
                if check["type"] == "stdout_equals": return fact["text"]
        return None

    def audit(self, verification: dict) -> bool:
        validate_metadata(verification, "verification", self)
        added = self.add_requirements(verification.get("uncovered_requirements", []), path="uncovered_requirements")
        if added or verification.get("uncovered_requirements") or verification.get("verified") is not True or verification.get("coverage_complete") is not True:
            self.coverage_complete = False
            self.rejections += 1
            return False
        for proof in verification.get("proofs", []):
            requirement = self.requirements[proof["requirement_id"]]
            requirement["evidence_ids"] = list(proof["evidence_ids"])
        self.coverage_complete = True
        self.refresh()
        if not self.can_complete(): self.rejections += 1
        return self.can_complete()

    def can_complete(self, output: str | None = None) -> bool:
        self.refresh()
        active = [r for r in self.requirements.values() if r.get("state") != "superseded"]
        if not active or not (self.coverage_complete or self.local_complete_grammar): return False
        if any(r["state"] != "proven" for r in active): return False
        if not self.batch_complete(): return False
        if output is not None:
            for r in active:
                if r["check"]["type"] in {"file_read", "stdout_equals"}:
                    exact = self.exact_output(r["check"], r["evidence_ids"])
                    if exact is None or exact not in output: return False
        return True

    def local_answer(self, text: str) -> None:
        if not self.local_complete_grammar or not re.fullmatch(LARGEST_PATTERN, self.task, re.I):
            fail("coverage", "requires a complete local request grammar")
        ref = self.add_evidence({"type": "local_answer", "text": text})
        for requirement in self.requirements.values(): requirement["evidence_ids"] = [ref]
        self.refresh()

    def recheck_actions(self) -> list[dict]:
        selected = {}
        for requirement in self.requirements.values():
            if requirement.get("state") == "superseded": continue
            if requirement["check"]["type"] in {"answer", "visual", "command_executed", "stdout_equals", "file_append", "file_written"}: continue
            for evidence in reversed(list(self.evidence.values())):
                action = evidence["action"]
                if not action or not evidence["mutable"] or evidence.get('effect_check'): continue
                # Match a revoked fact's identity without promoting it to proof.
                if self.matches(requirement["check"], {**evidence, "valid": True}):
                    selected[digest(action)] = action
                    break
        return list(selected.values())

    def recheck_effects(self) -> list[dict]:
        selected = {}
        for requirement in self.requirements.values():
            if requirement.get("state") == "superseded": continue
            for evidence in self.evidence.values():
                check = evidence.get('effect_check')
                if check and self.matches(requirement['check'], {**evidence, 'valid': True}):
                    selected[digest(check)] = deepcopy(check)
        return list(selected.values())

    def prompt_state(self) -> dict:
        def bounded(value):
            if isinstance(value, str) and len(value) > 1024:
                return {"excerpt": value[:1024], "full_length": len(value), "sha256": hashlib.sha256(value.encode()).hexdigest()}
            if isinstance(value, dict): return {k: bounded(v) for k, v in value.items()}
            if isinstance(value, list): return [bounded(v) for v in value]
            return value
        requirements = {identifier: requirement for identifier, requirement in self.requirements.items()
                        if requirement.get("state") != "superseded"}
        superseded = {identifier: {key: requirement[key] for key in ("source", "description", "superseded_by") if key in requirement}
                      for identifier, requirement in self.requirements.items()
                      if requirement.get("state") == "superseded"}
        batch_prompt = None
        if self.batch_initialized or self.batch_declaration_required_for():
            batch_prompt = {**self.batch_declaration(),
                            "needs_declaration": self.batch_declaration_required_for()}
        state = {"version": CHECKLIST_VERSION, "whole_request_coverage": "audited" if self.coverage_complete else "pending",
                 "requirements": bounded(requirements), "superseded_requirements": bounded(superseded),
                 "evidence": {key: {**bounded(e["fact"]), **({"origin": e["origin"]} if e["origin"] else {})}
                              for key, e in self.evidence.items() if e["valid"]}}
        if batch_prompt is not None:
            state["batch"] = batch_prompt
        if self.continuation_checkpoint is not None:
            self.refresh()
            state["continuation"] = {
                "mode": "recheck_then_continue",
                "previous_results": self.continuation_checkpoint.get("result_summaries", []),
                "rechecked_requirement_ids": sorted(self.continuation_rechecked_ids),
                "unfinished_requirement_ids": [
                    identifier for identifier, requirement in self.requirements.items()
                    if requirement.get("state") != "superseded" and requirement.get("state") != "proven"
                ],
                "omitted_recheck_sources": self.continuation_checkpoint.get("omitted_sources", []),
                "unresolved_prior_actions": self.continuation_unresolved_receipts,
            }
        return state

    def presentation_state(self, active_requirement_ids: list[str] | None = None,
                           lifecycle: str = "running") -> dict:
        """Return a bounded, content-safe view for the native progress strip.

        This is deliberately separate from prompt_state(): it never includes
        commands, entered values, file contents, screenshots, or evidence IDs.
        Only current evidence already accepted by the task ledger is summarized.
        """
        if lifecycle not in {"running", "waiting_for_user", "completed", "failed", "stopped"}:
            lifecycle = "running"
        self.refresh()
        active = set(active_requirement_ids or ())
        summaries = []
        task_bytes = self.task.encode("utf-8")
        range_budget = 4096
        evidence_budget = 512 * 1024
        projected_active = []
        projected_requirement_states = {}
        for identifier, requirement in list(self.requirements.items())[:512]:
            if requirement.get("state") == "superseded":
                continue
            if requirement.get("scope", "outcome") == "prerequisite":
                continue
            source = requirement["source"]
            encoded_source = source.encode("utf-8")
            ranges = []
            if encoded_source and len(encoded_source) <= 8192 and range_budget > 0:
                cursor = 0
                while cursor < len(task_bytes) and len(ranges) < min(256, range_budget):
                    start = task_bytes.find(encoded_source, cursor)
                    if start < 0:
                        break
                    ranges.append([start, start + len(encoded_source)])
                    cursor = start + 1
                range_budget -= len(ranges)
            proof = []
            if requirement["state"] == "proven":
                for evidence_id in requirement["evidence_ids"]:
                    evidence = self.evidence.get(evidence_id)
                    if evidence is None or not self.requirement_matches(identifier, evidence, semantic=True):
                        continue
                    summary = self._presentation_evidence(requirement["check"], evidence["fact"])
                    if summary and summary not in proof:
                        proof.append(summary)
                    if len(proof) >= 2:
                        break
            evidence_cost = sum(
                len((item.get("label", "") + item.get("detail", "") + item.get("reveal_path", "")).encode("utf-8"))
                for item in proof
            )
            if evidence_cost > evidence_budget:
                proof = []
            else:
                evidence_budget -= evidence_cost
            projected_state = requirement["state"]
            if projected_state == "proven" and not proof:
                # Never present a confirmed clause unless this projection can
                # carry at least one matching, currently valid proof summary.
                projected_state = "pending"
            projected_requirement_states[identifier] = projected_state
            summaries.append({
                "id": identifier,
                # The UI already owns the original task. Byte ranges avoid
                # copying commands, literal inputs, or credentials into IPC.
                "source_ranges": ranges,
                "state": projected_state,
                "active": identifier in active and lifecycle == "running" and projected_state != "proven",
                "evidence": proof,
            })
            if identifier in active and lifecycle == "running" and projected_state != "proven":
                projected_active.append(identifier)
        return {
            "version": 3,
            "lifecycle": lifecycle,
            "whole_request_coverage": "audited" if self.coverage_complete else "pending",
            "active_requirement_ids": projected_active,
            "requirements": summaries,
            "result_objects": self._presentation_result_objects(),
            "batch": self._presentation_batch(active, lifecycle, projected_requirement_states),
        }

    @staticmethod
    def _batch_outcome_label(check: dict) -> str:
        return {
            "file_read": "Read the requested input",
            "file_append": "Append the requested content",
            "file_written": "Write the requested output",
            "file_contents": "Match the requested file contents",
            "file_exists": "Confirm the requested file exists",
            "directory_exists": "Confirm the requested folder exists",
            "path_absent": "Confirm the requested path is absent",
            "command_executed": "Complete the requested command",
            "command_operation": "Verify the requested operation",
            "stdout_equals": "Match the requested output",
            "window_active": "Confirm the requested window",
            "field_value": "Confirm the requested field value",
            "dialog_present": "Confirm the expected dialog",
            "visual": "Check the requested visible result",
            "answer": "Provide the requested answer",
        }.get(check.get("type"), "Verify the requested outcome")

    def _presentation_batch(self, active: set[str], lifecycle: str,
                            projected_states: dict[str, str]) -> dict | None:
        if self.batch_mode != "per_input" or len(self.batch_items) < 2:
            return None
        items = []
        handled = 0
        terminal = lifecycle in {"completed", "failed", "stopped"}
        for item in self.batch_items[:128]:
            requirement_ids = [identifier for identifier in item.get("requirement_ids", [])
                              if identifier in self.requirements and
                              self.requirements[identifier].get("state") != "superseded"]
            requirements = [self.requirements[identifier] for identifier in requirement_ids]
            outcomes = [{"id": identifier, "label": self._batch_outcome_label(requirement["check"])}
                        for identifier, requirement in zip(requirement_ids, requirements)]
            invalidated = any(projected_states.get(identifier) == "invalidated" for identifier in requirement_ids)
            all_proven = bool(requirements) and all(projected_states.get(identifier) == "proven"
                                                     for identifier in requirement_ids)
            active_ids = [identifier for identifier in requirement_ids
                          if identifier in active and projected_states.get(identifier) != "proven"]
            if invalidated:
                state = "needs_recheck"
                step = "Earlier proof needs to be checked again."
            elif self.batch_needs_declaration:
                state = "unfinished" if terminal else "waiting"
                step = ("This input was not fully mapped before the run ended." if terminal else
                        "Rechecking which outcomes belong to this input.")
            elif all_proven:
                state = "verified"
                step = "All assigned outcomes have current proof."
                handled += 1
            elif terminal:
                state = "unfinished"
                step = "This input was not fully verified before the run ended."
            elif not requirements:
                state = "waiting"
                step = "Rechecking which outcomes belong to this input."
            elif lifecycle == "running" and active_ids:
                state = "working"
                requirement = self.requirements[active_ids[0]]
                step = "Working on: " + self._batch_outcome_label(requirement["check"]) + "."
            else:
                state = "waiting"
                step = "Waiting for its requested outcomes."
            items.append({
                "id": item["id"], "input_id": item["input_id"], "reference": item["reference"],
                "kind": item["kind"], "state": state, "active": state == "working",
                "current_step": step, "outcomes": outcomes,
            })
        return {"version": BATCH_PROGRESS_VERSION, "needs_declaration": self.batch_needs_declaration,
                "handled_count": handled, "items": items}

    def latest_confirmed_status(self) -> str:
        """Describe the newest currently valid proof for a proven outcome."""
        self.refresh()
        for evidence_id, evidence in reversed(list(self.evidence.items())):
            if not evidence.get("valid") or evidence.get("verified") is not True:
                continue
            if evidence.get("generation") != self.generation:
                continue
            for identifier, requirement in reversed(list(self.requirements.items())):
                if requirement.get("scope", "outcome") == "prerequisite":
                    continue
                if requirement.get("state") != "proven" or evidence_id not in requirement.get("evidence_ids", []):
                    continue
                if not self.requirement_matches(identifier, evidence, semantic=True):
                    continue
                summary = self._presentation_evidence(requirement["check"], evidence["fact"])
                if not summary:
                    continue
                label = summary.get("label", "Verified result")
                detail = summary.get("detail", "")
                check_type = requirement["check"].get("type")
                if check_type in FILE_CHECKS | {"file_read", "file_written", "file_append"} and isinstance(detail, str):
                    detail = os.path.basename(detail.rstrip("/")) or "the requested location"
                elif check_type in {"window_active", "dialog_present"}:
                    detail = "the expected window"
                if label == "Command completed":
                    return "Command finished; its requested result is not confirmed"
                if detail:
                    return f"{label}: {detail}"
                return str(label)
        return "No confirmed result yet."

    @staticmethod
    def _result_object_id(kind: str, target: str) -> str:
        prefix = {"file": "f", "folder": "d", "web": "w"}[kind]
        fingerprint = hashlib.sha256((kind + "\0" + target).encode("utf-8")).hexdigest()
        return f"{prefix}:{fingerprint}"

    @staticmethod
    def _safe_web_destination(value: Any) -> tuple[str, str] | None:
        if not isinstance(value, str) or not value:
            return None
        try:
            if len(value.encode("utf-8")) > 4096:
                return None
        except UnicodeEncodeError:
            return None
        if any(unicodedata.category(char) == "Cc" for char in value):
            return None
        if any(char.isspace() or char == "\\" for char in value):
            return None
        try:
            from urllib.parse import urlsplit
            parsed = urlsplit(value)
            hostname = parsed.hostname
            # A browser's observed document location is useful as an openable
            # result only when it is an ordinary public web URL, without user
            # credentials or malformed ports.
            if (parsed.scheme.lower() not in {"http", "https"} or not hostname or
                    parsed.username is not None or parsed.password is not None):
                return None
            try:
                ipaddress.ip_address(hostname)
            except ValueError:
                ascii_host = hostname.encode("idna").decode("ascii")
                labels = ascii_host.rstrip(".").split(".")
                if (not labels or len(ascii_host) > 253 or
                        any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                            for label in labels)):
                    return None
            if len(hostname) > 253:
                return None
            port = parsed.port
            if port is not None and not 1 <= port <= 65535:
                return None
            return value, hostname.lower()
        except (ValueError, UnicodeError):
            return None

    def _presentation_result_objects(self) -> list[dict]:
        """Project only requested, natively evidenced output targets.

        The output is a user-interface convenience, never a source of proof.
        Historical targets remain visible as needing recheck after mutable
        evidence is invalidated, while only currently matching evidence is
        labelled verified.
        """
        self.refresh()
        current: dict[str, dict] = {}
        associated_requirements: set[str] = set()

        def add(item: dict, requirement_id: str) -> None:
            item["_requirement_id"] = requirement_id
            previous = current.get(item["id"])
            if previous is None or (previous["state"] != "verified" and item["state"] == "verified"):
                current[item["id"]] = item

        file_types = {"file_written", "file_append", "file_contents", "file_exists", "directory_exists"}
        for requirement_id, requirement in self.requirements.items():
            if requirement.get("scope", "outcome") == "prerequisite":
                continue
            check = requirement.get("check", {})
            kind = check.get("type")
            if kind in file_types and isinstance(check.get("path"), str):
                associated_requirements.add(requirement_id)
                matching = []
                for evidence_id, evidence in self.evidence.items():
                    if self.requirement_matches(requirement_id, evidence):
                        matching.append((evidence_id, evidence))
                path_key_value = path_key(check["path"])
                has_current_requirement_proof = requirement.get("state") == "proven" and bool(matching)
                if has_current_requirement_proof:
                    chosen = next(((evidence_id, evidence) for evidence_id, evidence in reversed(matching)
                                   if evidence_id in requirement.get("evidence_ids", [])), matching[-1])
                else:
                    historical = []
                    for evidence_id, evidence in self.evidence.items():
                        if evidence.get("generation") != self.generation:
                            continue
                        if self.matches(check, {**evidence, "valid": True}):
                            historical.append((evidence_id, evidence))
                    cached = [item for item in self._result_object_cache.values()
                              if item.get("_requirement_id") == requirement_id and
                              item.get("kind") in {"file", "folder"} and
                              path_key(item.get("path", "")) == path_key(check["path"])]
                    chosen = historical[-1] if historical else None
                    if chosen is None and cached:
                        # Reuse the last verified object description without
                        # treating it as fresh proof.
                        stale = dict(cached[-1])
                        stale["state"] = "needs_recheck"
                        add(stale, requirement_id)
                        continue
                if chosen is None:
                    continue
                evidence_id, evidence = chosen
                fact = evidence.get("fact", {})
                path = fact.get("path")
                if not isinstance(path, str) or path_key(path) != path_key(check["path"]):
                    continue
                identity_fields = ("file_identity", "file_version", "parent_identity")
                selected_identity = {field: fact[field] for field in identity_fields if field in fact}
                fresh_object_support = any(
                    candidate.get("valid") is True and candidate.get("generation") == self.generation and
                    candidate.get("fact", {}).get("path") == path_key_value and
                    candidate.get("fact", {}).get("type") in {
                        "file_read", "file_contents", "file_append", "file_exists", "directory_exists",
                    } and
                    all(candidate.get("fact", {}).get(field) == value
                        for field, value in selected_identity.items())
                    for candidate in self.evidence.values()
                )
                status = ("verified" if has_current_requirement_proof and fresh_object_support
                          else "needs_recheck")
                object_kind = "folder" if kind == "directory_exists" or fact.get("type") == "directory_exists" else "file"
                if object_kind == "folder" and fact.get("type") != "directory_exists":
                    continue
                if object_kind == "file" and fact.get("type") == "directory_exists":
                    continue
                if len(path.encode("utf-8")) > 4096 or not path.startswith("/"):
                    continue
                item = {
                    "id": self._result_object_id(object_kind, path),
                    "kind": object_kind,
                    "state": status,
                    "name": path.rsplit("/", 1)[-1] or path,
                    "location": path.rsplit("/", 1)[0] or "/",
                    "path": path,
                }
                for field in ("file_identity", "file_version", "parent_identity"):
                    value = fact.get(field)
                    if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value):
                        item[field] = value
                add(item, requirement_id)
                continue

            if kind != "window_active":
                continue
            associated_requirements.add(requirement_id)
            check_fingerprint = digest(check)
            current_observation = self.current_observation or {}
            revision = current_observation.get("observation_revision")
            app = observation_indexes(current_observation).application(check.get("pid"))
            has_current_proof = any(
                evidence_id in requirement.get("evidence_ids", []) and
                (evidence := self.evidence.get(evidence_id)) is not None and
                evidence.get("valid") is True and evidence.get("fact", {}).get("type") == "requirement_observed" and
                evidence["fact"].get("check_fingerprint") == check_fingerprint and
                evidence["fact"].get("revision") == revision
                for evidence_id in requirement.get("evidence_ids", [])
            )
            destinations = current_observation.get("result_destinations", [])
            if (requirement.get("state") == "proven" and has_current_proof and isinstance(app, dict)
                    and isinstance(destinations, list)):
                matches = [destination for destination in destinations
                           if isinstance(destination, dict) and destination.get("pid") == check.get("pid")
                           and destination.get("window_title") == check.get("title")
                           and destination.get("bundle_id") == app.get("bundle_id")
                           and destination.get("bundle_id") in RESULT_BROWSER_BUNDLE_IDS
                           and destination.get("observation_revision") == revision]
                for destination in matches:
                    safe_url = self._safe_web_destination(destination.get("url"))
                    if safe_url is None:
                        continue
                    url, hostname = safe_url
                    title = destination.get("title")
                    title = title if isinstance(title, str) and title.strip() and len(title.encode("utf-8")) <= 512 else hostname
                    item = {"id": self._result_object_id("web", url), "kind": "web", "state": "verified",
                            "name": title, "location": hostname, "url": url, "hostname": hostname}
                    add(item, requirement_id)

        # Retain just the objects still associated with an outcome requirement.
        for identifier, item in list(self._result_object_cache.items()):
            requirement_id = item.get("_requirement_id")
            if requirement_id not in associated_requirements:
                continue
            requirement = self.requirements.get(requirement_id, {})
            check = requirement.get("check", {})
            if item.get("kind") in {"file", "folder"} and path_key(item.get("path", "")) != path_key(check.get("path", "")):
                continue
            if identifier not in current:
                stale = dict(item)
                stale["state"] = "needs_recheck"
                current[identifier] = stale

        # Carry forward the original display order for already-seen exact
        # destinations, then append newly verified objects in ledger order.
        ordered: dict[str, dict] = {}
        for identifier in self._result_object_cache:
            if identifier in current:
                ordered[identifier] = current.pop(identifier)
        ordered.update(current)
        self._result_object_cache = ordered
        output = []
        byte_count = 0
        for item in ordered.values():
            projected = {key: value for key, value in item.items() if key != "_requirement_id"}
            try:
                size = sum(len(projected.get(field, "").encode("utf-8")) for field in (
                    "id", "name", "location", "path", "url", "file_identity", "file_version", "parent_identity",
                )) + 96
            except (AttributeError, UnicodeEncodeError):
                continue
            if len(output) >= 128 or byte_count + size > 512 * 1024:
                break
            output.append(projected)
            byte_count += size
        return output

    @staticmethod
    def _presentation_evidence(check: dict, fact: dict) -> dict | None:
        """Summarize verified scope without exposing private values or output."""
        kind = check.get("type")
        if kind in {"file_contents", "file_written", "file_append", "file_exists", "directory_exists"}:
            path = fact.get("path")
            if not isinstance(path, str):
                return None
            label = {
                "file_contents": "File contents matched",
                "file_written": "File write verified",
                "file_append": "File append verified",
                "file_exists": "File exists",
                "directory_exists": "Folder exists",
            }.get(kind, "File result verified")
            bounded_path = path[:1024] if len(path.encode("utf-8")) <= 4096 else None
            result = {"label": label, "detail": path[:512]}
            if bounded_path is not None:
                result["reveal_path"] = bounded_path
            return result
        if kind == "path_absent":
            path = fact.get("path")
            return {"label": "Path is absent", "detail": path[:512]} if isinstance(path, str) else None
        if kind == "file_read":
            path = fact.get("path")
            return {"label": "Full file contents read", "detail": path[:512],
                    **({"reveal_path": path[:1024]} if isinstance(path, str) and len(path.encode("utf-8")) <= 4096 else {})} if isinstance(path, str) else None
        if kind == "command_operation":
            return {"label": "Requested operation verified", "detail": "Its specified outcome checks passed."}
        if kind == "command_executed":
            return {"label": "Command completed", "detail": "The validated command finished successfully."}
        if kind == "stdout_equals":
            return {"label": "Requested output matched", "detail": "The verified output matched the request."}
        if kind == "window_active":
            title = check.get("title")
            return {"label": "Document window observed",
                    "detail": str(title)[:256] if isinstance(title, str) else "The expected window was observed."}
        if kind == "dialog_present":
            title = check.get("title")
            return {"label": "Expected dialog observed",
                    "detail": str(title)[:256] if isinstance(title, str) else "The expected dialog was observed."}
        if kind == "field_value":
            return {"label": "Field value verified", "detail": "The requested field state was verified."}
        if kind == "visual":
            return {"label": "Screen result verified", "detail": "The existing completion audit accepted the visual evidence."}
        if kind == "answer":
            return {"label": "Requested answer verified", "detail": "The existing completion audit accepted the supporting evidence."}
        return {"label": "Requirement evidence verified", "detail": "The task evidence ledger accepted this result."}

    def fingerprint(self) -> str:
        self._sync_state()
        return self._state.fingerprint

    @property
    def revision(self) -> int:
        self._sync_state()
        return self._state.revision

    def _sync_state(self) -> None:
        self._state.update([CHECKLIST_VERSION, BATCH_PROGRESS_VERSION, self.task, self.generation,
                       self.inputs.fingerprint(), self.requirements,
                       {key: [e["fact_fingerprint"], e["action_fingerprint"], e["valid"], e["mutable"], e["origin"], e.get('effect_check')]
                        for key, e in self.evidence.items()}, self.coverage_complete,
                       self.batch_mode, self.batch_items, self.batch_source_input_ids,
                       self.batch_excluded_inputs, self.batch_global_requirement_ids,
                       self.batch_initialized, self.batch_needs_declaration])
