"""Task-local proof ledger. Model claims never create native evidence.

Semantic coverage is audited in the existing verification request. Only a
full-request local grammar may bypass that audit. Nothing here is persisted.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
from copy import deepcopy
from typing import Any

from action_contract_generated import CONTRACT, ActionContractError, _field, validate_action, validate_outcome_check

CHECKLIST_VERSION = 3
FILE_CHECKS = {"file_exists", "directory_exists", "path_absent", "file_contents"}
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


def path_key(path: str) -> str:
    return os.path.normpath(os.path.expanduser(path))


def content_bytes(check: dict) -> bytes:
    return (base64.b64decode(check["content"], validate=True) if check.get("encoding") == "base64"
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
    if set(value) - {"source", "description", "check"}: fail(path, "contains unsupported fields")
    for key in ("source", "description"):
        nonempty(value.get(key), f"{path}.{key}")
    if task is not None and value["source"] not in task:
        fail(path + ".source", "must quote the original request exactly")
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
        elif kind in {"visual", "answer"}:
            if set(check) != {"type", "expected"}: fail(path + ".check", "requires only type and expected")
            nonempty(check.get("expected"), path + ".check.expected")
        else:
            fail(path + ".check.type", "must be a supported proof type")
    except ActionContractError as error:
        raise EvidenceValidationError(str(error).replace("action", path + ".check", 1).replace(".check_list[0]", ".check")) from error
    return deepcopy(value)


def validate_metadata(value: dict, purpose: str, ledger: TaskEvidenceLedger | None = None) -> None:
    for key in ("requirements", "uncovered_requirements"):
        if key in value:
            entries = value[key]
            if not isinstance(entries, list): fail(key, "must be a list")
            for index, entry in enumerate(entries):
                validate_requirement(entry, ledger.task if ledger else None, f"{key}[{index}]")
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
                if not any(ledger.matches(requirement["check"], ledger.evidence[ref], semantic=True) for ref in refs):
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
    def __init__(self, task: str, generation: str | None = None) -> None:
        self.task, self.generation = task, generation
        self.requirements: dict[str, dict] = {}
        self.evidence: dict[str, dict] = {}
        self.coverage_complete = False
        self.local_complete_grammar = False
        self.observation_id: str | None = None
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

    def add_requirements(self, entries: list[dict]) -> bool:
        added = False
        for entry in entries:
            entry = validate_requirement(entry, self.task, "requirements")
            if any(all(r[k] == entry[k] for k in entry) for r in self.requirements.values()): continue
            self.requirements[f"r{len(self.requirements) + 1}"] = {**entry, "state": "pending", "evidence_ids": []}
            added = True
        if added: self.coverage_complete = False
        self.refresh()
        return added

    def accept_plan(self, decision: dict) -> None:
        self.add_requirements(decision.get("requirements", []))

    def add_evidence(self, fact: dict, *, mutable=False, action=None) -> str:
        identifier = f"e{len(self.evidence) + 1}"
        self.evidence[identifier] = {"fact": deepcopy(fact), "mutable": mutable, "valid": True,
                                     "action": deepcopy(action), "generation": self.generation,
                                     "origin": ({"action_id": f"a{self.action_sequence}", "method": "readback" if self.readback else "execution"} if action else None),
                                     "fact_fingerprint": digest(fact), "action_fingerprint": digest(action)}
        self.refresh()
        return identifier

    def observe(self, observation: dict) -> None:
        # bridge_call already checks then removes the private wire generation.
        if self.generation and observation.get("task_generation_id", self.generation) != self.generation:
            fail("observation", "belongs to another task")
        revision = observation.get("observation_revision")
        nonempty(revision, "observation.observation_revision")
        self.invalidate(lambda e: e["fact"]["type"] == "observation")
        self.observation_id = self.add_evidence({"type": "observation", "revision": revision})

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
        if not isinstance(result, dict): return
        self.action_sequence += 1
        self.readback = recheck
        if recheck:
            self.checks += 1
            for check, actual in zip(result.get("requested_checks", []), result.get("checks", [])):
                self.record_check(check, actual, action)
            if kind == 'run_command': self.record_operation(action, result, recheck=True)
            if kind != "read_file": return
        if kind == "read_file":
            if (result.get("path") != path_key(action["path"]) or result.get("truncated") is not False or
                    type(result.get("bytes_returned")) is not int or not isinstance(result.get("content"), str) or
                    result.get("encoding") not in {"utf-8", "base64"}): return
            try: data = content_bytes(result)
            except (ValueError, UnicodeEncodeError): return
            if len(data) != result["bytes_returned"] or hashlib.sha256(data).hexdigest() != result.get("content_sha256"): return
            self.add_evidence({"type": "file_read", "path": result["path"], "content": result["content"],
                               "encoding": result["encoding"], "content_sha256": result["content_sha256"]}, mutable=True, action=action)
        elif kind == "write_file":
            if (result.get("verified") is not True or result.get("path") != path_key(action["path"]) or
                    result.get("mode") != action.get("mode", "overwrite") or
                    result.get("content_sha256") != content_hash(action) or
                    type(result.get("bytes_written")) is not int or result["bytes_written"] != len(content_bytes(action))): return
            self.add_evidence({"type": "file_written", "path": result["path"], "mode": result["mode"],
                               "content_sha256": result["content_sha256"]}, action=action)
            fact = {"type": "file_append" if result["mode"] == "append" else "file_contents",
                    "path": result["path"], "content_sha256": result["content_sha256"]}
            self.add_evidence(fact, mutable=result["mode"] != "append", action=action)
            self.add_evidence({"type": "file_exists", "path": result["path"]}, mutable=True, action=action)
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
        if (not isinstance(check, dict) or not isinstance(actual, dict) or
                actual.get("verified") is not True or actual.get("type") != check.get("type")): return
        kind = check["type"]
        if kind in FILE_CHECKS:
            if actual.get("path") != path_key(check["path"]): return
            fact = {"type": kind, "path": actual["path"]}
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
        for requirement in self.requirements.values():
            refs = [ref for ref, e in self.evidence.items() if self.matches(requirement["check"], e)]
            old = requirement["evidence_ids"]
            if requirement["check"]["type"] in {"visual", "answer"}:
                refs = [ref for ref in old if self.matches(requirement["check"], self.evidence[ref], semantic=True)]
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
        added = self.add_requirements(verification.get("uncovered_requirements", []))
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

    def fingerprint(self) -> str:
        return digest([CHECKLIST_VERSION, self.task, self.generation, self.requirements,
                       {key: [e["fact_fingerprint"], e["action_fingerprint"], e["valid"], e["mutable"], e["origin"], e.get('effect_check')]
                        for key, e in self.evidence.items()}, self.coverage_complete])
