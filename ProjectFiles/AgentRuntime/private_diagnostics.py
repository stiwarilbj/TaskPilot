"""Allowlisted, content-free private diagnostic schemas.

Diagnostic values are deliberately small enums and bounded counters. These
validators sit immediately before runtime metrics cross IPC and before action
records are persisted; arbitrary result dictionaries never reach JSON output.
"""
from __future__ import annotations

import math
from typing import Any

from action_contract_generated import CONTRACT


REQUEST_METRIC_REQUIRED_FIELDS = frozenset({
    "planning", "verification", "retries", "model_switches", "cache_hits", "reconnects",
})
REQUEST_METRIC_OPTIONAL_FIELDS = frozenset({
    "prompt_calls", "provider_retries", "action_deliveries", "action_rejections",
    "unconfirmed_actions", "repairs", "evidence_checks", "coverage_rejections",
    "requirements_proven", "dependency_checks", "dependency_rejections",
    "conflict_inspections", "evidence_conflicts", "recovery_cycles", "cycle_suppressions",
    "receipt_queries", "receipt_recoveries", "effect_checks", "verified_effects",
    "unconfirmed_effects", "receipt_unresolved", "local_notifications",
    "local_targeted_checks", "local_poll_wakeups", "command_inspections", "command_probes",
    "command_probe_cache_hits", "command_preflight_rejections",
})
REQUEST_METRIC_FIELDS = REQUEST_METRIC_REQUIRED_FIELDS | REQUEST_METRIC_OPTIONAL_FIELDS
MAX_DIAGNOSTIC_COUNTER = 1_000_000_000

ACTION_DIAGNOSTIC_FIELDS = frozenset({
    "schema_version", "timestamp_ms", "runtime_pid", "action_type", "outcome",
    "delivery_method", "error_code", "verification_scope", "recovery",
})
ACTION_TYPES = frozenset(CONTRACT["actions"].keys())
ACTION_OUTCOMES = frozenset({
    "verified", "delivered_unconfirmed", "rejected", "dispatched", "suppressed",
    "recovery_required", "cancelled",
})
DELIVERY_METHODS = frozenset({
    "local_check", "workspace", "accessibility", "accessibility_value",
    "accessibility_selected_text", "process_event", "session_event", "hid",
})
VERIFICATION_SCOPES = frozenset({
    "none", "delivery_only", "execution_only", "requested_outcomes", "window_visible",
    "focus", "text_value", "file_read", "file_write", "expected_effect",
    "expected_effect_unconfirmed", "file_exists", "directory_exists", "path_absent",
    "file_contents", "stdout_equals",
})
ERROR_CODES = frozenset({
    "action_rejected", "ambiguous_target", "activation_failed", "cancelled",
    "command_capabilities_changed", "command_options_unverified", "command_syntax",
    "command_tool_missing", "delivery_rejected", "delivery_uncertain", "disabled_target",
    "evidence_conflict", "file_conflict", "focus_mismatch", "instruction_superseded",
    "invalid_action", "local_budget_exhausted", "observation_unstable", "permission_denied",
    "prerequisite_unproven", "protected_target", "protocol_error", "recovery_cycle",
    "receipt_conflict", "runtime_recovering", "secure_input", "stale_target",
    "stop_boundary_rejected", "stop_boundary_uncertain", "target_choice_conflict",
    "target_choice_opaque_command", "target_choice_stale", "unsupported_action",
    "working_document_lost", "working_document_superseded", "working_document_target_mismatch",
    "working_selection_lost", "working_selection_target_mismatch",
})
RECOVERY_KINDS = frozenset({
    "choose_different_action", "choose_inspected_options", "choose_supported_method",
    "correct_command_syntax", "disabled_target", "effect_already_present",
    "inspect_after_local_budget", "inspect_command_again", "inspect_effect",
    "inspect_filesystem_again", "inspect_or_choose_safe_preparation", "observe_again",
    "observe_and_activate", "observe_and_refocus", "select_installed_tool",
    "select_specific_control", "wait_for_loading", "wait_or_choose_enabled", "fresh_observation",
})


class DiagnosticSchemaError(ValueError):
    pass


def validate_request_metrics(payload: dict[str, Any]) -> dict[str, int | None]:
    """Return a copy after strict field/type/range checks; reject nested data."""
    if type(payload) is not dict:
        raise DiagnosticSchemaError("request metrics must be an object")
    keys = set(payload)
    if not REQUEST_METRIC_REQUIRED_FIELDS <= keys or not keys <= REQUEST_METRIC_FIELDS:
        raise DiagnosticSchemaError("request metrics contain missing or unknown fields")
    result: dict[str, int | None] = {}
    for key, value in payload.items():
        if key == "provider_retries" and value is None:
            result[key] = None
            continue
        if type(value) is not int or not 0 <= value <= MAX_DIAGNOSTIC_COUNTER:
            raise DiagnosticSchemaError("request metric value is not an allowed bounded counter")
        result[key] = value
    return result


def action_record(action: Any, result: Any, *, timestamp: float, runtime_pid: int) -> dict[str, int | str] | None:
    """Project native action dictionaries onto a fixed, content-free record."""
    if type(action) is not dict or type(result) is not dict:
        return None
    action_type = action.get("type")
    if type(action_type) is not str or action_type not in ACTION_TYPES:
        return None
    if type(runtime_pid) is not int or not 1 <= runtime_pid <= 2_147_483_647:
        return None
    if not isinstance(timestamp, (int, float)) or isinstance(timestamp, bool) or not math.isfinite(timestamp) or timestamp < 0:
        return None
    record: dict[str, int | str] = {
        "schema_version": 1,
        "timestamp_ms": min(9_007_199_254_740_991, int(timestamp * 1000)),
        "runtime_pid": runtime_pid,
        "action_type": action_type,
    }
    allowed_values = {
        "outcome": ACTION_OUTCOMES,
        "delivery_method": DELIVERY_METHODS,
        "error_code": ERROR_CODES,
        "verification_scope": VERIFICATION_SCOPES,
        "recovery": RECOVERY_KINDS,
    }
    for field, choices in allowed_values.items():
        if field not in result:
            continue
        value = result[field]
        # Empty error_code is the native "no error" sentinel, not a diagnostic.
        if field == "error_code" and value == "":
            continue
        if type(value) is not str or value not in choices:
            return None
        record[field] = value
    return validate_action_record(record)


def validate_action_record(record: Any) -> dict[str, int | str] | None:
    """Final persistence-boundary check for an already projected record."""
    if type(record) is not dict or not set(record) <= ACTION_DIAGNOSTIC_FIELDS:
        return None
    if not {"schema_version", "timestamp_ms", "runtime_pid", "action_type"} <= set(record):
        return None
    if (type(record["schema_version"]) is not int or record["schema_version"] != 1
            or type(record["timestamp_ms"]) is not int or not 0 <= record["timestamp_ms"] <= 9_007_199_254_740_991
            or type(record["runtime_pid"]) is not int or not 1 <= record["runtime_pid"] <= 2_147_483_647
            or type(record["action_type"]) is not str or record["action_type"] not in ACTION_TYPES):
        return None
    allowed_values = {
        "outcome": ACTION_OUTCOMES,
        "delivery_method": DELIVERY_METHODS,
        "error_code": ERROR_CODES,
        "verification_scope": VERIFICATION_SCOPES,
        "recovery": RECOVERY_KINDS,
    }
    for field, choices in allowed_values.items():
        if field in record and (type(record[field]) is not str or record[field] not in choices):
            return None
    return dict(record)
