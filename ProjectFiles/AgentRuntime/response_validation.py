"""Strict response contracts. No target, command, or content is synthesized."""
from __future__ import annotations

import json
import math
from typing import Any
from task_evidence import EvidenceValidationError, validate_metadata
from observation_context import coordinates_are_ambiguous, observation_indexes
from expected_effects import validate_expectation, ExpectedEffectError
from command_intents import explicit_operation, matches_explicit_request
from local_text_recognition import coordinate_text_target, TextRecognitionError
from task_inputs import InputReferenceError, reject_unbound_references
from evidence_consistency import validate_disagreement

from action_contract_generated import (
    CONTRACT_HASH, CONTRACT_VERSION, VALID_ACTIONS, KEYS,
    ActionContractError, validate_action,
)

VALIDATION_VERSION = 11


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
    if "status" in result and (not isinstance(result["status"], str) or result["status"] not in {"act", "done", "needs_user", "blocked"}):
        fail("status", "must be act, done, needs_user, or blocked")
    if result.get("status") == "act" and "action" not in result:
        fail("action", "is required when status is act")
    if purpose == "verification":
        if type(result.get("verified")) is not bool: fail("verified", "must be a boolean")
    else:
        status = result.get("status")
        if not isinstance(status, str) or status not in {"act", "done", "needs_user", "blocked"}: fail("status", "must be act, done, needs_user, or blocked")
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
    try:
        validate_metadata(result, purpose, ledger, observation)
    except EvidenceValidationError as error:
        raise ResponseValidationError(str(error)) from error
    return result
