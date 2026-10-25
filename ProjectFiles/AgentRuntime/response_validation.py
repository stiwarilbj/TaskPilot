"""Strict response contracts. No target, command, or content is synthesized."""
from __future__ import annotations

import json
import math
import re
from typing import Any
from task_evidence import EvidenceValidationError, validate_metadata
from observation_context import coordinates_are_ambiguous, observation_indexes
from expected_effects import validate_expectation, ExpectedEffectError
from command_intents import explicit_operation, matches_explicit_request
from local_text_recognition import coordinate_text_target, TextRecognitionError
from task_inputs import InputReferenceError, reject_unbound_references
from task_evidence import project_requirements
from evidence_consistency import validate_disagreement
from target_choices import validate_choice_shape

from action_contract_generated import (
    CONTRACT_HASH, CONTRACT_VERSION, VALID_ACTIONS, KEYS,
    ActionContractError, validate_action,
)

VALIDATION_VERSION = 16


class ResponseValidationError(RuntimeError):
    pass


def fail(path: str, expectation: str) -> None:
    raise ResponseValidationError(f"{path} {expectation}")


def extract_json_object(text: str) -> dict[str, Any]:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                fail("response", "contains duplicate object keys")
            result[key] = value
        return result
    def constant(_):
        fail("response", "must contain only finite numbers")
    decoder = json.JSONDecoder(object_pairs_hook=pairs, parse_constant=constant)
    cleaned = text.strip()
    # Scan only outer containers. Never recover an inner object from a broken
    # outer object or array, and never choose between multiple objects.
    if cleaned.startswith('"'):
        fail("response", "must contain one object, not a quoted JSON value")
    containers = []
    index = 0
    while index < len(cleaned):
        if cleaned[index] in "}]":
            fail("response", "contains unmatched outer punctuation")
        if cleaned[index] not in "{[":
            index += 1
            continue
        try:
            value, end = decoder.raw_decode(cleaned, index)
        except (ValueError, RecursionError):
            fail("response", "must contain one complete JSON object")
        containers.append(value)
        index = end
    if len(containers) != 1 or not isinstance(containers[0], dict):
        fail("response", "must contain exactly one JSON object")
    result = containers[0]
    def finite(value):
        if isinstance(value, float) and not math.isfinite(value):
            fail("response", "must contain only finite numbers")
        if isinstance(value, dict):
            for item in value.values(): finite(item)
        elif isinstance(value, list):
            for item in value: finite(item)
    finite(result)
    return result


def string(value: Any, path: str, nonempty: bool = False) -> None:
    if not isinstance(value, str): fail(path, "must be a string")
    if nonempty and not value.strip(): fail(path, "must be a nonempty string")
    try: value.encode("utf-8")
    except UnicodeEncodeError: fail(path, "must contain valid UTF-8 text")


def _role_quote_is_grounded(task: str, occurrence: tuple, role: str, quote: str,
                           occurrences: tuple[tuple, ...]) -> bool:
    """Require a nearby exact clause whose wording clearly supports the role."""
    encoded = task.encode("utf-8")
    masked = bytearray(encoded)
    for _identifier, _kind, start, length, _value, _user_role in occurrences:
        masked[start:start + length] = b" " * length
    quote_bytes = quote.encode("utf-8")
    quote_positions = []
    cursor = 0
    while True:
        found = encoded.find(quote_bytes, cursor)
        if found < 0:
            break
        end = found + len(quote_bytes)
        if not any(found < right and end > left for left, right in
                   ((item[2], item[2] + item[3]) for item in occurrences)):
            quote_positions.append((found, end))
        cursor = found + 1
    target_start, target_end = occurrence[2], occurrence[2] + occurrence[3]
    nearby = False
    for quote_start, quote_end in quote_positions:
        distance = min(abs(target_start - quote_end), abs(quote_start - target_end))
        if distance > 240:
            continue
        between_start, between_end = sorted((quote_end, target_start)) if quote_end <= target_start else sorted((target_end, quote_start))
        if any(byte in b".!?;\n\r" for byte in masked[between_start:between_end]):
            continue
        nearby = True
        break
    if not nearby:
        return False

    text = quote.casefold()
    example = bool(re.search(r"\b(?:reference|example|template|style|format|sample)\b", text))
    destination = bool(
        re.search(r"\b(?:save|export|write|put|store|place|deliver|download|create|generate|output|copy|move)\b"
                  r"[^.!?;\n]{0,100}\b(?:to|in|into|under|beside|at|as)\s*$", text) or
        re.search(r"\b(?:destination|output\s+(?:folder|file|location)|save\s+location|target\s+folder)\b", text)
    )
    source = bool(re.search(r"\b(?:summari[sz]e|analy[sz]e|read|review|edit|modify|change|convert|process|"
                            r"compare|merge|translate|transcribe|extract|open|source|input|from|using)\b", text))
    supported = {name for name, matched in (("reference_example", example), ("destination", destination),
                                             ("source", source)) if matched}
    return supported == {role}


def validate_input_roles(value: Any, ledger) -> list[dict[str, str]]:
    if not isinstance(value, list) or len(value) > 128:
        fail("input_roles", "must be a list of at most 128 role proposals")
    if ledger is None:
        fail("input_roles", "requires task-owned exact input references")
    occurrences = ledger.inputs.reference_occurrences
    by_id = {item[0]: item for item in occurrences}
    known = set(by_id)
    submitted = ledger.task.encode("utf-8")
    protected = [(item[2], item[2] + item[3]) for item in ledger.inputs.reference_occurrences]
    seen: set[str] = set()
    normalized = []
    for index, item in enumerate(value):
        path = f"input_roles[{index}]"
        if not isinstance(item, dict) or set(item) != {"occurrence_id", "role", "source_quote"}:
            fail(path, "requires occurrence_id, role, and source_quote only")
        identifier, role, quote = item["occurrence_id"], item["role"], item["source_quote"]
        if not isinstance(identifier, str) or identifier not in known:
            fail(path + ".occurrence_id", "must reference an exact input occurrence from this task")
        if identifier in seen:
            fail(path + ".occurrence_id", "must be unique")
        occurrence = by_id[identifier]
        if occurrence[5] is not None:
            fail(path + ".occurrence_id", "must omit a reference with a user-selected role")
        if not isinstance(role, str) or role not in {"source", "destination", "reference_example"}:
            fail(path + ".role", "must be source, destination, or reference_example")
        string(quote, path + ".source_quote", nonempty=True)
        if not quote.strip() or len(quote.encode("utf-8")) > 240:
            fail(path + ".source_quote", "must be a nonempty exact user quotation of at most 240 UTF-8 bytes")
        quote_bytes = quote.encode("utf-8")
        positions = []
        start = 0
        while True:
            found = submitted.find(quote_bytes, start)
            if found < 0: break
            end = found + len(quote_bytes)
            if not any(found < right and end > left for left, right in protected):
                positions.append(found)
            start = found + 1
        if not positions:
            fail(path + ".source_quote", "must exactly quote unbound user wording, not an input value")
        if not _role_quote_is_grounded(ledger.task, occurrence, role, quote, occurrences):
            fail(path, "must use nearby wording that clearly supports this role")
        seen.add(identifier)
        normalized.append({"occurrence_id": identifier, "role": role, "source_quote": quote})
    return normalized


def normalize_action(value: Any, observation: dict[str, Any] | None = None) -> dict[str, Any]:
    try:
        action = validate_action(value)
    except ActionContractError as error:
        raise ResponseValidationError(str(error)) from error
    kind = action["type"]
    if observation is not None:
        indexes = observation_indexes(observation)
        if "element_id" in action:
            element = indexes.element(action["element_id"], last=True)
            if element is None: fail("action.element_id", "must reference the current observation")
            if "pid" in action and action["pid"] != element.get("pid"): fail("action.pid", "must match the selected element's app")
        elif "pid" in action:
            if action["pid"] not in indexes.applications_by_pid:
                fail("action.pid", "must reference an app in the current observation")
        if kind == "open_route":
            routes = observation.get("system_context", {}).get("task_routes", [])
            if action["route_id"] not in {r.get("route_id") for r in routes if isinstance(r, dict)}:
                fail("action.route_id", "must reference a supplied task route")
        if coordinates_are_ambiguous(action, observation, indexes):
            fail("action.element_id", "must select one observed control; these coordinates overlap multiple unrelated controls")
        try: coordinate_text_target(action, observation)
        except TextRecognitionError as error: raise ResponseValidationError(str(error)) from error
    return action


def bind_command_outcomes(action: dict, result: dict) -> dict:
    """Bind native source snapshots to this operation, never model assertions."""
    if action.get('type') != 'run_command' or 'operation' not in action: return action
    if result.get('command_operation') != action['operation']:
        raise RuntimeError('The native command result did not match its requested operation')
    checks = result.get('outcome_checks')
    try: bound = validate_action({**action, 'checks': checks})
    except ActionContractError as error: raise RuntimeError('Invalid native operation evidence: ' + str(error)) from error
    if bound['checks'] != checks or checks[:len(action['checks'])] != action['checks']:
        raise RuntimeError('The native command result omitted the operation outcome checks')
    from action_contract_generated import CONTRACT
    snapshot = CONTRACT['command_operations'][action['operation']['type']].get('snapshot')
    if snapshot:
        extra = checks[len(action['checks']):]
        candidates = extra if extra else action['checks']
        if len(extra) > 1 or not any(c.get('type') == 'file_contents' and c.get('encoding') == 'base64'
                                    and c.get('path') == action['operation'][snapshot['destination']] for c in candidates):
            raise RuntimeError('The native command result omitted its exact source snapshot')
    elif checks != action['checks']:
        raise RuntimeError('The native command result supplied unexpected operation evidence')
    return bound


def validate_response(value: dict[str, Any], purpose: str, observation: dict[str, Any] | None = None, ledger=None) -> dict[str, Any]:
    try:
        if ledger is not None: value = ledger.inputs.resolve(value)
        else: reject_unbound_references(value)
    except InputReferenceError as error: raise ResponseValidationError(str(error)) from error
    result = dict(value)
    if "input_roles" in result:
        if purpose != "planning": fail("input_roles", "is valid only during planning")
        result["input_roles"] = validate_input_roles(result["input_roles"], ledger)
    if 'evidence_disagreement' in result:
        validate_disagreement(result['evidence_disagreement'], observation, ledger, fail)
    for key in ("summary", "context_used", "visual_evidence", "intended_target", "output", "output_title", "reason", "message", "title", "check"):
        if key in result: string(result[key], key)
    if 'expected_result' in result:
        try: result['expected_result'] = validate_expectation(result['expected_result'], observation)
        except ExpectedEffectError as error: raise ResponseValidationError(str(error)) from error
    for key in ("completed_requirements", "remaining_requirements", "missing"):
        if key in result and (not isinstance(result[key], list) or any(not isinstance(item, str) for item in result[key])):
            fail(key, "must be a list of strings")
    if "finish_after_action" in result and type(result["finish_after_action"]) is not bool: fail("finish_after_action", "must be a boolean")
    for key, choices in (("selected_capability", {"file_read", "file_write", "shell", "browser", "app_automation", "mixed"}), ("output_kind", {"answer", "result", "completion"}), ("kind", {"answer", "result", "completion"})):
        if key in result and (not isinstance(result[key], str) or result[key] not in choices): fail(key, "must be a supported value")
    statuses = {"act", "done", "needs_user", "needs_choice", "blocked"}
    if "status" in result and (not isinstance(result["status"], str) or result["status"] not in statuses):
        fail("status", "must be act, done, needs_user, needs_choice, or blocked")
    if result.get("status") == "act" and "action" not in result:
        fail("action", "is required when status is act")
    if result.get("status") == "needs_choice" and "action" in result:
        fail("action", "must be omitted while waiting for a target choice")
    if purpose == "verification":
        if type(result.get("verified")) is not bool: fail("verified", "must be a boolean")
    else:
        status = result.get("status")
        if not isinstance(status, str) or status not in statuses: fail("status", "must be act, done, needs_user, needs_choice, or blocked")
        if purpose == "readiness" and (status != "done" or result.get("check") != "TASKPILOT_READY"): fail("check", "must equal TASKPILOT_READY with status done")
    if "action" in result:
        result["action"] = normalize_action(result["action"], observation)
        expected = explicit_operation(ledger.task) if ledger else None
        if expected and 'operation' in result['action'] and not matches_explicit_request(result['action']['operation'], expected):
            fail('action.operation', 'must match the explicit operation and operands in the original request')
    if "user_input" in result:
        request = result["user_input"]
        if not isinstance(request, dict): fail("user_input", "must be an object")
        if not isinstance(request.get("kind"), str) or request["kind"] not in {"password", "verification_code", "secret"}: fail("user_input.kind", "must be password, verification_code, or secret")
        for key in ("title", "message", "target_signature"):
            if key in request: string(request[key], f"user_input.{key}")
    if result.get("status") == "needs_user":
        if "user_input" not in result: fail("user_input", "is required when status is needs_user")
        action = result.get("action", {})
        for key in ("element_id", "pid"):
            if key not in action: fail(f"action.{key}", "is required for secure input")
        if observation is not None:
            element = observation_indexes(observation).element(action["element_id"])
            if element.get("role") not in {"AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox"}:
                fail("action.element_id", "must reference an observed text input for secure input")
            if element.get("enabled") is False:
                fail("action.element_id", "must reference an enabled secure input target")
    if result.get("status") == "needs_choice":
        if purpose != "planning":
            fail("status", "needs_choice is valid only during planning")
        if "choice" not in result:
            fail("choice", "is required when status is needs_choice")
        if observation is None or ledger is None:
            fail("choice", "requires the current native observation and task checklist")
    try:
        validate_metadata(result, purpose, ledger, observation)
    except EvidenceValidationError as error:
        raise ResponseValidationError(str(error)) from error
    if result.get("status") == "needs_choice":
        proposed = dict(ledger.requirements)
        if isinstance(result.get("requirements"), list):
            try:
                entries = ledger.canonical_entries(result["requirements"], observation)
                proposed = project_requirements(proposed, entries, ledger.task)
            except EvidenceValidationError as error:
                raise ResponseValidationError(str(error)) from error
        active_requirement_ids = {identifier for identifier, item in proposed.items()
                                  if item.get("state") != "superseded" and
                                  item.get("scope", "outcome") != "prerequisite"}
        try:
            result["choice"] = validate_choice_shape(result["choice"], observation, ledger, fail,
                                                      active_requirement_ids)
        except (ValueError, OSError) as error:
            if isinstance(error, ResponseValidationError):
                raise
            raise ResponseValidationError(str(error)) from error
        if ledger.batch_declaration_required_for() and "batch" not in result:
            fail("batch", "is required before resolving a target used by per-input work")
    return result
