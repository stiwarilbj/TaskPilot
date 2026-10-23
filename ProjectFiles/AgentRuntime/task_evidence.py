"""Task-local proof ledger. Model claims never create native evidence.

Semantic coverage is audited in the existing verification request. Only a
full-request local grammar may bypass that audit. Nothing here is persisted.
"""
from __future__ import annotations

import base64
import hashlib
import json
import math
import os
import re
import threading
from copy import deepcopy
from typing import Any

from action_contract_generated import (CONTRACT, ActionContractError, _field, validate_action, validate_outcome_check,
    validate_native_result, validate_check_batch, validate_native_readback, validate_native_payload, validate_native_evidence)
from task_inputs import TaskInputBindings
from expected_effects import ExpectedEffect, ExpectedEffectError, validate_expectation
from observation_context import coordinate_targets, observation_indexes

CHECKLIST_VERSION = 7
FILE_CHECKS = {"file_exists", "directory_exists", "path_absent", "file_contents"}
OBSERVATION_CHECKS = {"window_active", "field_value", "dialog_present"}
READ_PATTERN = r'\s*(?:read|show|print)\s+(?:the\s+)?(?:contents of\s+)?file\s+(["`\'])((?:/|~/)(?:(?!\1)[^\n])+)\1\s*[.!]?\s*'
LARGEST_PATTERN = (r"\s*(?:(?:what(?:['’]s| is)|which is) (?:the |my )?|(?:find|tell me|show me) (?:the )?)"
                   r"largest file (?:in|inside) (?:my |the |your )?downloads(?: folder)?\s*[?.!]?\s*")


class EvidenceValidationError(ValueError):
    pass


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
    if set(value) - {"source", "description", "check", "depends_on", "scope"}: fail(path, "contains unsupported fields")
    for key in ("source", "description"):
        nonempty(value.get(key), f"{path}.{key}")
    if task is not None and value["source"] not in task:
        fail(path + ".source", "must quote the original request exactly")
    if "depends_on" in value:
        requirement_refs(value["depends_on"], path + ".depends_on", empty=True)
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
        matching = [key for key, old in result.items() if old["source"] == entry["source"] and old["check"] == entry["check"]]
        identifier = next((key for key in matching if entry.get("scope", result[key].get("scope", "outcome")) == result[key].get("scope", "outcome")),
                          matching[0] if matching else None)
        # The final auditor may require a current outcome in addition to an
        # already-recorded historical precondition; it cannot replace either.
        if (identifier and path == "uncovered_requirements" and entry.get("scope") == "outcome" and
                result[identifier].get("scope") == "prerequisite"):
            identifier = next((key for key, old in result.items() if old["source"] == entry["source"] and
                               old["check"] == entry["check"] and old.get("scope") == "outcome"), None)
        if identifier:
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
    if "requirement_ids" in value:
        requirement_refs(value["requirement_ids"], "requirement_ids")
        if ledger is None or any(ref not in proposed for ref in value["requirement_ids"]):
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
                if requirement is None: fail(path + ".requirement_id", "must reference this task's checklist")
                for ref in refs:
                    evidence = ledger.evidence.get(ref)
                    if evidence is None or not evidence["valid"]:
                        fail(path + ".evidence_ids", "must reference current evidence from this task")
                if not any(ledger.requirement_matches(proof["requirement_id"], ledger.evidence[ref], semantic=True) for ref in refs):
                    fail(path + ".evidence_ids", "do not prove the requirement's target and outcome")
    if ledger is None: return
    if purpose == "planning" and not ledger.requirements and value.get("status") in {"act", "done"}:
        if not value.get("requirements"): fail("requirements", "must enumerate the original request's requirements on the first decision")
    if purpose == "verification" and value.get("verified") is True:
        if type(value.get("coverage_complete")) is not bool:
            fail("coverage_complete", "is required for completion verification")
        if value["coverage_complete"] and not value.get("uncovered_requirements"):
            claimed = {p["requirement_id"] for p in value.get("proofs", [])}
            if claimed != set(ledger.requirements): fail("proofs", "must cite evidence for every checklist requirement")
            output_refs = {ref for proof in value.get("proofs", [])
                           if ledger.requirements[proof["requirement_id"]]["check"]["type"] in {"file_read", "stdout_equals"}
                           for ref in proof["evidence_ids"]}
            if set(value.get("output_evidence_ids", [])) - output_refs:
                fail("output_evidence_ids", "must belong to requested full-output requirements")
            if any(r["check"]["type"] in {"answer", "file_read", "stdout_equals"} for r in ledger.requirements.values()):
                nonempty(value.get("message"), "message")
                for proof in value["proofs"]:
                    check = ledger.requirements[proof["requirement_id"]]["check"]
                    if check["type"] in {"file_read", "stdout_equals"}:
                        text = ledger.exact_output(check, proof["evidence_ids"])
                        native_output = any(ref in value.get("output_evidence_ids", []) and
                                            ledger.matches(check, ledger.evidence[ref]) for ref in proof["evidence_ids"])
                        if text is None or (text not in value["message"] and not native_output):
                            fail("message", "must contain the complete verified requested output")


class TaskEvidenceLedger:
    def __init__(self, task: str, generation: str | None = None, *, input_scope: str | None = None) -> None:
        self._state = RevisionedJSONState()
        self.task, self.generation = task, generation
        self.inputs = TaskInputBindings(task, scope=input_scope)
        self.requirements: dict[str, dict] = {}
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
        read = re.fullmatch(READ_PATTERN, task, re.I)
        if read:
            self.local_complete_grammar = True
            self.add_requirements([{"source": task, "description": "Return the complete file contents",
                                    "check": {"type": "file_read", "path": read.group(2)}}])
        elif re.fullmatch(LARGEST_PATTERN, task, re.I):
            self.local_complete_grammar = True
            self.add_requirements([{"source": task, "description": "Return the exact largest top-level Downloads file and size",
                                    "check": {"type": "answer", "expected": task}}])

    def add_requirements(self, entries: list[dict], observation: dict | None = None, *, path="requirements") -> bool:
        proposed = project_requirements(self.requirements, self.canonical_entries(entries, observation), self.task, path)
        self.validate_observation_checks(proposed, observation)
        changed = proposed != self.requirements
        self.requirements = proposed
        self.bind_observation_checks(observation or self.current_observation)
        if changed: self.coverage_complete = False
        self.record_observation_checks()
        self.refresh()
        return changed

    def accept_plan(self, decision: dict, observation: dict | None = None) -> None:
        self.add_requirements(decision.get("requirements", []), observation)

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
            if not proven: continue
            fact = {"type": "requirement_observed", "requirement_id": identifier,
                    "check_fingerprint": digest(check), "revision": observation["observation_revision"]}
            if not any(e["valid"] and e["fact"] == fact for e in self.evidence.values()):
                self.add_evidence(fact, mutable=True)

    def requirement_matches(self, identifier: str, evidence: dict, *, semantic=False, current=False) -> bool:
        requirement = self.requirements[identifier]
        fact = evidence["fact"]
        if (not current and requirement.get("scope") == "prerequisite" and evidence["valid"] and
                evidence["generation"] == self.generation and fact.get("type") == "prerequisite_checked"):
            return fact.get("requirement_id") == identifier and fact.get("check_fingerprint") == digest(requirement["check"])
        return self.matches(requirement["check"], evidence, semantic=semantic)

    def action_requirements(self, decision: dict) -> list[str]:
        """Include deterministic effect matches even if a decision mislabels them."""
        selected = list(decision.get("requirement_ids", []))
        action = decision.get("action", {})
        if not any(r.get("depends_on") for r in self.requirements.values()): return selected
        for identifier, entry in self.requirements.items():
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
        if any(self.matches(check, evidence) for evidence in self.evidence.values()): return
        self.checks += 1
        self.readback = True
        previous = set(self.evidence)
        self.record_check(check, actual, action)
        for identifier in set(self.evidence) - previous:
            self.evidence[identifier]['effect_check'] = deepcopy(check)

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
        if not self.requirements or not (self.coverage_complete or self.local_complete_grammar): return False
        if any(r["state"] != "proven" for r in self.requirements.values()): return False
        if output is not None:
            for r in self.requirements.values():
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
        return {"version": CHECKLIST_VERSION, "whole_request_coverage": "audited" if self.coverage_complete else "pending",
                "requirements": bounded(self.requirements),
                "evidence": {key: {**bounded(e["fact"]), **({"origin": e["origin"]} if e["origin"] else {})}
                             for key, e in self.evidence.items() if e["valid"]}}

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
        for identifier, requirement in list(self.requirements.items())[:512]:
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
            "version": 1,
            "lifecycle": lifecycle,
            "whole_request_coverage": "audited" if self.coverage_complete else "pending",
            "active_requirement_ids": projected_active,
            "requirements": summaries,
        }

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
        self._state.update([CHECKLIST_VERSION, self.task, self.generation, self.inputs.fingerprint(), self.requirements,
                       {key: [e["fact_fingerprint"], e["action_fingerprint"], e["valid"], e["mutable"], e["origin"], e.get('effect_check')]
                        for key, e in self.evidence.items()}, self.coverage_complete])
