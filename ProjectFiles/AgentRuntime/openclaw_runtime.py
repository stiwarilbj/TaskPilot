#!/usr/bin/env python3
"""OpenClaw-powered visible desktop loop for TaskPilot.

TaskPilot owns macOS permissions, capture, Accessibility actions, display routing,
and cleanup. This helper sends each current TaskPilot observation to OpenClaw over
the official ACP stdio bridge, asks for one JSON action, and returns that action
to the native controller over JSONL.
"""

from __future__ import annotations

import argparse
import managed_openclaw
import base64
from collections import deque
from contextlib import contextmanager, nullcontext
from contextvars import ContextVar
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import shlex
import signal
import stat
import subprocess
import sys
import threading
import time
import uuid
import tempfile
import struct
import zlib
from datetime import datetime
from typing import Any


MAX_STEPS = 100
MAX_IDENTICAL_ACTIONS = 3
PROMPT_TIMEOUT_SECONDS = None  # Wait for completion or an explicit provider/transport error.
SCREEN_POLL_SECONDS = 0.15
SCREEN_STABLE_SECONDS = 0.3
LOCAL_CHANGE_VERSION = 1
COMMAND_CAPABILITY_VERSION = 1
PRODUCT_NAME = "TaskPilot"
LEGACY_APPLICATION_SUPPORT_FOLDER = "Orbit Agent"
from request_policy import (
    ALL_MODELS, PRIMARY_MODELS, FALLBACK_MODELS, CONFIG_VERSION, configuration_transaction,
    AdaptiveModelRouter, Failure, ModelAttemptError, RecoveryExhaustedError, RuntimeState, classify_failure, model_route,
)
from provider_errors import ProviderRequestError, facts as provider_error_facts, message_text, response_error
from action_receipts import BridgeReplyLost, RuntimeInbox, reconcile_receipt
from local_budget import LocalBudget, LocalBudgetExpired, current_budget, local_scope, local_operation
from task_execution import (TaskContext, Phase, ExecutionStateError, InstructionSuperseded,
                            WorkingDocumentSuperseded,
                            current_task)
from task_wait import TaskWaitPublisher, WAIT_PRESENTATION_VERSION
from task_destination import TaskDestinationPublisher, planned_destination, explicit_destination_instruction
from bounded_transport import ACPTransport, TransportFailure, FRAME_BYTES, read_frames, write_frame
from prompt_compiler import (
    PROMPT_COMPILER_VERSION, COMPLETION_RULES, json_data, recovery_condition,
    decision_rules, compile_prompt, compile_repair,
)

from observation_context import (select_elements, historical_progress, coordinate_targets, structural_identity, RELATIONSHIPS_VERSION, words,
                                 ObservationIndexes, OBSERVATION_INDEX_VERSION, observation_indexes, observation_index_scope)
from screen_coordinates import COORDINATE_MAPPING_VERSION, CoordinateMappingError, validate_observation_mapping
from observation_completeness import (OBSERVATION_COMPLETENESS_VERSION, ObservationCompletenessError,
                                      validate_completeness, prompt_coverage, coverage_cache_input)
from local_text_recognition import (TEXT_RECOGNITION_VERSION, TextRecognitionError,
                                    validate_text_recognition, prompt_text_recognition, detail_images)
from task_evidence import (TaskEvidenceLedger, RevisionedJSONState, CHECKLIST_VERSION, BATCH_PROGRESS_VERSION,
                           CONTINUATION_CHECKPOINT_VERSION,
                           requests_per_input_work,
                           LARGEST_PATTERN, digest as evidence_digest)
from expected_effects import ExpectedEffect, EXPECTED_EFFECT_VERSION, FILE_EFFECTS, path_key
from task_inputs import EXACT_INPUT_REFERENCE_VERSION, TASK_INPUT_VERSION, input_reference_rules
from task_inputs import TaskInputBindings, InputReferenceError
from task_action_boundaries import (STOP_BOUNDARY_POLICY_VERSION, BoundaryViolation,
                                    detect_stop_boundaries, validate_action_against_boundaries)
from command_intents import explicit_operation
from evidence_consistency import EvidenceConsistency, EVIDENCE_CONSISTENCY_VERSION
from recovery_cycles import RecoveryCycles, RECOVERY_CYCLE_VERSION
from target_choices import (PROTOCOL_VERSION as TARGET_CHOICE_PROTOCOL_VERSION,
                            grounded_candidates, native_candidate_payload,
                            candidate_fingerprint)

from response_validation import (
    VALIDATION_VERSION, ResponseValidationError, extract_json_object, bind_command_outcomes,
    normalize_action, validate_response,
)
from private_diagnostics import action_record, validate_action_record, validate_request_metrics


def expected_wait_description(decision: dict[str, Any] | None) -> str:
    decision = decision if isinstance(decision, dict) else {}
    expectation = decision.get("expected_result")
    if isinstance(expectation, dict):
        kind = expectation.get("type")
        if kind == "dialog_appeared":
            title = expectation.get("title")
            return title if isinstance(title, str) and title.strip() else "The expected dialog"
        if kind == "field_value":
            return "The expected field update"
        if kind in FILE_EFFECTS:
            return "The requested file result"
        return "The expected screen change"
    action = decision.get("action")
    if isinstance(action, dict):
        if action.get("type") == "run_command":
            return "The requested command result"
        if action.get("type") in {"write_file", "read_file"}:
            return "The requested file result"
        if action.get("type") == "wait":
            return "The app to finish waiting"
    return "The expected result"

MAX_COMPACT_ELEMENTS = 360
MAX_RECENT_ACTIONS = 8
VERIFICATION_SESSION_VERSION = 1
STATE_FINGERPRINT_VERSION = 1
from action_contract_generated import (
    TASK_PROTOCOL_VERSION, NativeProtocolError, validate_native_payload, validate_native_result, validate_native_receipt, validate_check_batch, validate_native_readback,
    CONTRACT_HASH, CONTRACT_VERSION, VALID_ACTIONS, TRUSTED_NATIVE_ACTIONS,
    action_example, action_default, ACTION_REFERENCE, PROMPT_BOUNDS, ACTION_CAPABILITIES,
    CONTRACT, operation_example, COMMAND_OPERATION_REFERENCE,
)


STANDARD_LOCATIONS = {
    "desktop": "~/Desktop",
    "documents": "~/Documents",
    "downloads": "~/Downloads",
    "home": "~",
    "pictures": "~/Pictures",
    "movies": "~/Movies",
    "music": "~/Music",
}

WORKING_DOCUMENT_PROTOCOL_VERSION = 2

_active_acp_process: subprocess.Popen[str] | None = None
_bridge_observation_revision: str | None = None
_task_generation_id: str | None = None
_instruction_revision = 0
_instruction_correction_key = None
_working_document_revision = 0
_working_document_update_key = None
_target_choice_protocol_version = 0
_continuation_checkpoint: dict[str, Any] | None = None
_observation_keywords: list[str] = []
_exact_input_references: list[dict[str, Any]] = []
_runtime_inbox: RuntimeInbox | None = None
_receipt_metrics = {"receipt_queries": 0, "receipt_recoveries": 0, "receipt_unresolved": 0}
_local_change_metrics = {"local_notifications": 0, "local_targeted_checks": 0, "local_poll_wakeups": 0}
_command_capability_metrics = {"command_inspections": 0, "command_probes": 0, "command_probe_cache_hits": 0, "command_preflight_rejections": 0}
_command_capabilities: dict[str, dict[str, Any]] = {}
_screenshot_buffers = ContextVar("task_screenshot_buffers", default=None)
_pressure_lock = threading.Lock()
_pressure_images = None


def _task_value(name: str) -> Any:
    context = current_task.get()
    if context is not None:
        return getattr(context, name)
    if name == "generation": return _task_generation_id
    if name == "correction_key": return _instruction_correction_key
    if name == "working_document_revision": return _working_document_revision
    if name == "working_document_key": return _working_document_update_key
    if name == "target_choice_key": return context.target_choice_key
    if name == "continuation_checkpoint": return _continuation_checkpoint
    return globals()["_" + name]


def _set_task_value(name: str, value: Any) -> None:
    context = current_task.get()
    if context is not None:
        setattr(context, name, value)
    else:
        globals()["_" + name] = value


def handle_runtime_control(line: str) -> bool:
    try:
        message = json.loads(line)
    except (ValueError, TypeError):
        return False
    if not isinstance(message, dict) or message.get("kind") != "memory_pressure":
        return False
    with _pressure_lock:
        images = _pressure_images
    generation = message.get("task_generation_id")
    if (images is not None and isinstance(generation, str) and generation
            and generation == images.generation
            and message.get("level") in ("warning", "critical")):
        images.evict_disposable()
    # Consume invalid/stale pressure controls too; never confuse them with a
    # native action receipt or a secure-input reply.
    return True


def runtime_inbox() -> RuntimeInbox:
    global _runtime_inbox
    context = current_task.get()
    if context is not None:
        if context.inbox is None:
            context.inbox = (_runtime_inbox if _runtime_inbox is not None and _runtime_inbox.stream is sys.stdin
                             else RuntimeInbox(sys.stdin, control_handler=handle_runtime_control))
        return context.inbox
    if _runtime_inbox is None or _runtime_inbox.stream is not sys.stdin:
        _runtime_inbox = RuntimeInbox(sys.stdin, control_handler=handle_runtime_control)
    return _runtime_inbox


def runtime_line(timeout: float | None = None, *, key=None) -> str:
    inbox = runtime_inbox()
    return inbox.read(timeout, **({'key': key} if key is not None else {}))


def instruction_correction_pending() -> bool:
    context = current_task.get()
    return bool(context is not None and (
        context.pending_correction_message is not None or
        (context.correction_key and runtime_inbox().has_instruction_correction()) or
        context.pending_working_document_message is not None or
        context.pending_task_control is not None or
        (context.working_document_key and runtime_inbox().has_working_document_update())
    ))


def receive_pending_task_control(timeout: float | None = 0) -> dict[str, Any]:
    context = current_task.get()
    if context is None:
        raise InstructionSuperseded("No task control is available to apply")
    if context.pending_task_control is not None:
        control = context.pending_task_control
        context.pending_task_control = None
        return control
    if context.pending_correction_message is not None or (
            context.correction_key and runtime_inbox().has_instruction_correction()):
        return {"control_kind": "instruction_correction", **receive_instruction_correction(timeout)}
    if context.pending_working_document_message is not None:
        message = context.pending_working_document_message
        context.pending_working_document_message = None
    else:
        if not context.working_document_key:
            raise InstructionSuperseded("No working document update is available")
        line = runtime_inbox().take_working_document_update(timeout)
        try:
            message = json.loads(line)
        except (TypeError, ValueError) as error:
            raise RuntimeError("TaskPilot received malformed working-document control data") from error
    if (not isinstance(message, dict) or message.get("kind") != "working_document_update" or
            message.get("task_generation_id") != context.generation or message.get("version") != WORKING_DOCUMENT_PROTOCOL_VERSION or
            type(message.get("binding_revision")) is not int or
            message["binding_revision"] != context.working_document_revision + 1):
        raise RuntimeError("TaskPilot received a working-document update for another task or revision")
    identifier = message.get("update_id")
    try:
        canonical = str(uuid.UUID(identifier)).lower()
    except (ValueError, TypeError, AttributeError) as error:
        raise RuntimeError("TaskPilot received an invalid working-document update ID") from error
    if canonical != identifier:
        raise RuntimeError("TaskPilot received a noncanonical working-document update ID")
    selection_id = message.get("selection_id")
    if selection_id is not None:
        try:
            selection_canonical = str(uuid.UUID(selection_id)).lower()
        except (ValueError, TypeError, AttributeError) as error:
            raise RuntimeError("TaskPilot received an invalid working-document selection") from error
        if selection_canonical != selection_id:
            raise RuntimeError("TaskPilot received a noncanonical working-document selection")
    selection_scope_id = message.get("selection_scope_id")
    if selection_scope_id is not None:
        try:
            scope_canonical = str(uuid.UUID(selection_scope_id)).lower()
        except (ValueError, TypeError, AttributeError) as error:
            raise RuntimeError("TaskPilot received an invalid working-selection ID") from error
        if scope_canonical != selection_scope_id or selection_id is None:
            raise RuntimeError("TaskPilot received an invalid working-selection binding")
    remove_selection_limit = message.get("remove_selection_limit", False)
    if type(remove_selection_limit) is not bool or (remove_selection_limit and (selection_id is not None or selection_scope_id is not None)):
        raise RuntimeError("TaskPilot received an invalid working-selection removal")
    return {"control_kind": "working_document_update", "id": canonical,
            "revision": message["binding_revision"], "selection_id": selection_id,
            "selection_scope_id": selection_scope_id,
            "remove_selection_limit": remove_selection_limit}


def receive_target_choice_response(timeout: float | None = 0) -> dict[str, Any]:
    context = current_task.get()
    pending = context.pending_target_choice if context is not None else None
    if context is None or not isinstance(pending, dict) or not context.target_choice_key:
        raise RuntimeError("No target choice is waiting for a response")
    try:
        message = json.loads(runtime_inbox().take_target_choice(timeout))
    except (TypeError, ValueError) as error:
        raise RuntimeError("TaskPilot received malformed target-choice response data") from error
    if (not isinstance(message, dict) or message.get("kind") != "target_choice_response" or
            set(message) != {"kind", "version", "task_generation_id", "request_id", "instruction_revision",
                             "working_document_revision", "binding_revision", "candidate_id", "inspect_again"} or
            type(message.get("version")) is not int or
            message["version"] != TARGET_CHOICE_PROTOCOL_VERSION or
            message.get("task_generation_id") != context.generation or
            message.get("request_id") != pending["request_id"] or
            type(message.get("instruction_revision")) is not int or
            message["instruction_revision"] != context.instruction_revision or
            type(message.get("working_document_revision")) is not int or
            message["working_document_revision"] != pending["working_document_revision"] or
            type(message.get("binding_revision")) is not int or
            message["binding_revision"] != pending["binding_revision"] or
            type(message.get("inspect_again")) is not bool):
        raise RuntimeError("TaskPilot received a target choice for another task or revision")
    if message["inspect_again"]:
        if message.get("candidate_id") is not None:
            raise RuntimeError("Inspect Again cannot include a target candidate")
        return {"inspect_again": True}
    candidate_id = message.get("candidate_id")
    if not isinstance(candidate_id, str) or candidate_id not in pending["candidate_map"]:
        raise RuntimeError("TaskPilot received a candidate that was not offered for this question")
    return {"inspect_again": False, "candidate_id": candidate_id}


def receive_instruction_correction(timeout: float | None = 0) -> dict[str, Any]:
    context = current_task.get()
    if context is None or not context.correction_key:
        raise InstructionSuperseded("No correction is available to apply")
    if context.pending_correction_message is not None:
        message = context.pending_correction_message
        context.pending_correction_message = None
    else:
        line = runtime_inbox().take_instruction_correction(timeout)
        try:
            message = json.loads(line)
        except (TypeError, ValueError) as error:
            raise RuntimeError("TaskPilot received malformed correction control data") from error
    correction = message.get("correction") if isinstance(message, dict) else None
    if (not isinstance(message, dict) or message.get("kind") != "instruction_correction" or
            message.get("task_generation_id") != context.generation or
            type(message.get("instruction_revision")) is not int or
            type(correction) is not dict or correction.get("version") != 1 or
            correction.get("instruction_revision") != message.get("instruction_revision") or
            not isinstance(correction.get("correction_id"), str)):
        raise RuntimeError("TaskPilot received a correction for another task or revision")
    try:
        identifier = str(uuid.UUID(correction["correction_id"])).lower()
    except (ValueError, TypeError, AttributeError) as error:
        raise RuntimeError("TaskPilot received an invalid correction ID") from error
    if identifier != correction["correction_id"]:
        raise RuntimeError("TaskPilot received a noncanonical correction ID")
    request = correction.get("request")
    references = correction.get("exact_input_references")
    amendment = correction.get("role_amendment")
    for applied in context.instruction_corrections:
        if applied.get("id") != identifier:
            continue
        if (applied.get("revision") == correction.get("instruction_revision") and
                applied.get("request") == request and
                applied.get("exact_input_references") == references and
                applied.get("role_amendment") == amendment):
            return {"id": identifier, "revision": correction["instruction_revision"],
                    "request": request, "exact_input_references": references, "role_amendment": amendment,
                    "duplicate": True}
        raise RuntimeError("TaskPilot received a correction ID with conflicting contents")
    if correction["instruction_revision"] != context.instruction_revision + 1:
        raise RuntimeError("TaskPilot received a stale or skipped correction revision")
    if (not isinstance(request, str) or (not request.strip() and amendment is None) or len(request.encode("utf-8")) > 32768 or
            type(references) is not list or len(references) > 128):
        raise RuntimeError("TaskPilot received invalid correction text or exact inputs")
    # Validate every UTF-8 range against the corrected source before changing
    # task bindings or invalidating current evidence.
    TaskInputBindings(request, exact_input_references=references)
    if amendment is not None:
        required = {"occurrence_id", "kind", "utf8_start", "utf8_length", "value", "role"}
        if type(amendment) is not dict or set(amendment) != required:
            raise RuntimeError("TaskPilot received malformed input-role amendment data")
        if (not isinstance(amendment.get("occurrence_id"), str) or
                not isinstance(amendment.get("kind"), str) or
                amendment.get("kind") not in {"file", "folder", "url", "text"} or
                type(amendment.get("utf8_start")) is not int or amendment["utf8_start"] < 0 or
                type(amendment.get("utf8_length")) is not int or amendment["utf8_length"] <= 0 or
                not isinstance(amendment.get("value"), str) or not amendment["value"]):
            raise RuntimeError("TaskPilot received malformed input-role target metadata")
        role = amendment.get("role")
        if role is not None and (not isinstance(role, str) or role not in {"source", "destination", "reference_example"}):
            raise RuntimeError("TaskPilot received an unsupported input role")
        current = TaskInputBindings(context.task, exact_input_references=context.exact_input_references)
        target = (amendment.get("occurrence_id"), amendment.get("kind"), amendment.get("utf8_start"),
                  amendment.get("utf8_length"), amendment.get("value"))
        matches = [item for item in current.reference_occurrences if item[:5] == target]
        if len(matches) != 1:
            raise RuntimeError("TaskPilot input-role amendment does not match one current exact input occurrence")
    elif correction.get("role_amendment") is not None:
        raise RuntimeError("TaskPilot received an invalid input-role amendment")
    return {"id": identifier, "revision": correction["instruction_revision"],
            "request": request, "exact_input_references": references, "role_amendment": amendment}


class ActionRejected(RuntimeError):
    def __init__(self, message: str, code: str = "action_rejected", details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.details = details or {}


class ModelCapacityError(RuntimeError):
    """A selected model hit a quota, rate, or temporary-capacity limit."""


def is_model_capacity_failure(error: BaseException | str) -> bool:
    message = str(error).lower()
    markers = (
        "429", "503", "rate limit", "rate-limit", "rate_limit", "quota", "resource exhausted",
        "resource_exhausted", "too many concurrent", "throttl", "concurrency limit",
        "weekly limit", "monthly limit", "daily limit", "usage limit",
        "all models failed", "overloaded", "model is unavailable", "model unavailable",
        "code=unavailable", "high demand", "temporarily unavailable",
        "first response retry", "model request timed out", "model timed out",
    )
    return isinstance(error, ModelCapacityError) or any(marker in message for marker in markers)


class TaskModelRouter(AdaptiveModelRouter):
    def __init__(self, state: RuntimeState | None = None) -> None:
        super().__init__(emit=emit, state=state)


def emit(kind: str, **payload: Any) -> None:
    if kind == "wait_phase":
        context = current_task.get()
        if context is not None:
            context.wait_request_sequence += 1
            publish_task_wait(
                str(payload.get("phase") or "model_response"),
                str(payload.get("waiting_for") or "The model’s response"),
                operation_key=f"request:{context.wait_request_sequence}",
                ledger=context.ledger,
            )
        return
    if kind == "request_metrics":
        try:
            payload = validate_request_metrics(payload)
        except (TypeError, ValueError):
            # Diagnostic rejection is intentionally non-fatal to task work.
            return
    envelope = {"kind": kind, **payload}
    if _task_value('generation') is not None: envelope["task_generation_id"] = _task_value('generation')
    context = current_task.get()
    if _task_value('generation') is not None:
        envelope["instruction_revision"] = _task_value('instruction_revision')
        envelope["working_document_revision"] = _task_value('working_document_revision')
    print(json.dumps(envelope, separators=(",", ":")), flush=True)


def publish_task_wait(phase: str, waiting_for: str, *, attention: str = "none",
                      operation_key: str | None = None, ledger: TaskEvidenceLedger | None = None) -> None:
    context = current_task.get()
    if context is None or context.generation is None:
        return
    if context.wait_publisher is None:
        context.wait_publisher = TaskWaitPublisher(context.generation)
    try:
        snapshot = context.wait_publisher.update(
            phase, latest_confirmed_status(ledger or context.ledger), waiting_for, attention,
            operation_key=operation_key,
        )
        if snapshot is not None:
            emit(**snapshot)
    except Exception:
        # This optional presentation must never affect task execution.
        return


def publish_task_destination(*, state: str, operation_key: str, planned_path: Any = None,
                             actual_path: Any = None, requested_filename: Any = None,
                             selected_filename: Any = None, destination_exists: Any = None,
                             instruction: Any = None, observation_revision: Any = None) -> None:
    """Publish bounded destination information without affecting task execution."""
    context = current_task.get()
    if context is None or context.generation is None:
        return
    if context.destination_publisher is None:
        context.destination_publisher = TaskDestinationPublisher(context.generation)
    try:
        snapshot = context.destination_publisher.update(
            state=state, operation_key=operation_key, planned_path=planned_path,
            actual_path=actual_path, requested_filename=requested_filename,
            selected_filename=selected_filename, destination_exists=destination_exists,
            instruction=instruction, observation_revision=observation_revision)
        if snapshot is not None:
            emit(**snapshot)
    except Exception:
        return


def publish_planned_destination(ledger: TaskEvidenceLedger | None) -> None:
    context = current_task.get()
    if context is None or context.generation is None or ledger is None:
        return
    path, filename = planned_destination(ledger)
    publish_task_destination(
        state="planned" if path or filename else "cleared",
        operation_key=f"planned:{context.instruction_revision}",
        planned_path=path,
        requested_filename=filename,
        instruction=explicit_destination_instruction(ledger.task, ledger.inputs.exact_references),
    )


def current_destination_values() -> dict[str, Any]:
    context = current_task.get()
    publisher = context.destination_publisher if context else None
    current = publisher.current if publisher else None
    if not current:
        return {}
    return {key: current.get(key) for key in
            ("planned_path", "requested_filename", "instruction") if current.get(key) is not None}


def action_destination(action: dict[str, Any], observation: dict[str, Any] | None = None) -> tuple[str | None, str | None]:
    """Return only destinations carried by validated native action parameters."""
    action_type = action.get("type")
    if action_type == "write_file" and isinstance(action.get("path"), str):
        return action["path"], "native_write"
    operation = action.get("operation")
    if action_type == "run_command" and isinstance(operation, dict):
        kind = operation.get("type")
        operand = "destination" if kind in {"copy_file", "move_file"} else "path" if kind == "create_directory" else None
        if operand and isinstance(operation.get(operand), str):
            return operation[operand], "deterministic_command"
    if observation and action_type in {"click", "press"}:
        elements = observation.get("elements", [])
        target = next((row for row in elements if isinstance(row, dict) and row.get("id") == action.get("element_id")), None)
        if target and str(target.get("title") or "").strip().casefold() in {"save", "save as", "export"}:
            candidates = observation.get("save_panel_destinations", [])
            matched = [row for row in candidates if isinstance(row, dict) and
                       row.get("path_confirmed") is True and
                       row.get("pid") == target.get("pid") and
                       row.get("window_id") == target.get("window_id") and
                       isinstance(row.get("actual_path"), str)]
            if len(matched) == 1:
                return matched[0]["actual_path"], "save_panel"
    return None, None


def publish_action_destination(action: dict[str, Any], task: str, observation: dict[str, Any] | None,
                               step: int, *, delivered: bool = False) -> None:
    path, source = action_destination(action, observation)
    if path is None:
        return
    import os
    expanded = os.path.expanduser(path)
    exists = os.path.lexists(expanded) if os.path.isabs(expanded) else None
    preserved = current_destination_values()
    context = current_task.get()
    exact_references = context.ledger.inputs.exact_references if context and context.ledger else ()
    preserved["instruction"] = explicit_destination_instruction(task, exact_references) or preserved.get("instruction")
    selected_filename = (os.path.basename(expanded.rstrip(os.sep)) or None) if os.path.isabs(expanded) else None
    publish_task_destination(
        state="checking" if delivered else "preparing",
        operation_key=f"save:{step}:{source}", actual_path=path,
        selected_filename=selected_filename,
        **preserved,
        destination_exists=exists,
        observation_revision=(observation or {}).get("observation_revision") if source == "save_panel" else None,
    )


def publish_observed_destination(observation: dict[str, Any], task: str, step: int) -> None:
    context = current_task.get()
    exact_references = context.ledger.inputs.exact_references if context and context.ledger else ()
    preserved = current_destination_values()
    preserved["instruction"] = explicit_destination_instruction(task, exact_references) or preserved.get("instruction")
    panels = observation.get("save_panel_destinations", [])
    if not isinstance(panels, list) or not panels:
        publisher = context.destination_publisher if context else None
        current = publisher.current if publisher else None
        if current and current.get("state") in {"selected", "selected_unconfirmed"}:
            publish_planned_destination(context.ledger)
        return
    if len(panels) != 1 or not isinstance(panels[0], dict):
        publish_task_destination(state="selected_unconfirmed", operation_key=f"panel-ambiguous:{step}",
                                 **preserved)
        return
    panel = panels[0]
    path = panel.get("actual_path") if panel.get("path_confirmed") is True else None
    filename = panel.get("selected_filename")
    publisher = context.destination_publisher if context else None
    current = publisher.current if publisher else None
    state = "checking" if current and current.get("state") == "checking" else "selected"
    publish_task_destination(
        state=state if path else "selected_unconfirmed",
        operation_key=f"save-panel:{panel.get('pid')}:{panel.get('window_id')}",
        actual_path=path, selected_filename=filename, **preserved,
        destination_exists=panel.get("destination_exists") if path else None,
        observation_revision=observation.get("observation_revision"),
    )


def clear_destination_after_proof(ledger: TaskEvidenceLedger | None) -> None:
    context = current_task.get()
    current = context.destination_publisher.current if context and context.destination_publisher else None
    path = current.get("actual_path") if current else None
    if not ledger or not path:
        return
    from expected_effects import path_key
    if any(requirement.get("state") == "proven" and
           isinstance(requirement.get("check"), dict) and
           requirement["check"].get("path") and
           path_key(requirement["check"]["path"]) == path_key(path)
           for requirement in ledger.requirements.values()):
        publish_task_destination(state="cleared", operation_key=f"verified:{context.step}")


def latest_confirmed_status(ledger: TaskEvidenceLedger | None) -> str:
    if ledger is None:
        return "No confirmed result yet."
    return ledger.latest_confirmed_status()


def mark_continuation_receipt_uncertain(action: dict[str, Any] | None = None,
                                        action_id: str | None = None) -> None:
    """Prevent continuation from replaying a mutation whose effect is unknown."""
    context = current_task.get()
    if context is None:
        return
    kind = action.get("type") if isinstance(action, dict) else None
    if kind in {"none", "wait", "read_file"}:
        return
    identifier = action_id or context.current_action_receipt_id
    if isinstance(identifier, str) and identifier:
        context.continuation_uncertain_receipt_ids.add(identifier)


def publish_task_progress(ledger: TaskEvidenceLedger | None, *, lifecycle: str | None = None,
                          active_requirement_ids: list[str] | None = None, force: bool = False) -> None:
    """Publish a bounded, content-safe projection of current task evidence."""
    context = current_task.get()
    if context is None or ledger is None or context.generation is None:
        return
    if lifecycle is not None:
        context.progress_lifecycle = lifecycle
    if active_requirement_ids is not None:
        context.progress_active_requirement_ids = list(dict.fromkeys(active_requirement_ids))[:512]
    try:
        publish_task_input_roles(ledger)
        snapshot = ledger.presentation_state(context.progress_active_requirement_ids, context.progress_lifecycle)
        publish_task_continuation_checkpoint(ledger)
        fingerprint = hashlib.sha256(json.dumps(snapshot, sort_keys=True, separators=(",", ":"),
                                        ensure_ascii=True).encode()).hexdigest()
        if not force and fingerprint == context.progress_fingerprint:
            return
        context.progress_fingerprint = fingerprint
        context.progress_revision += 1
        emit("task_progress", revision=context.progress_revision, **snapshot)
        clear_destination_after_proof(ledger)
        if context.wait_publisher is not None:
            publish_task_wait(context.wait_publisher.phase, context.wait_publisher.waiting_for,
                              attention=context.wait_publisher.attention,
                              operation_key=context.wait_publisher.operation_key, ledger=ledger)
    except Exception:
        # The progress projection is optional UI state. Its failure must not
        # change planning, execution, evidence, or completion behavior.
        return


def publish_task_input_roles(ledger: TaskEvidenceLedger | None) -> None:
    """Publish only bounded role labels; exact values remain in the request itself."""
    context = current_task.get()
    if context is None or ledger is None or context.generation is None:
        return
    try:
        if not ledger.inputs.reference_occurrences:
            return
        roles = ledger.input_role_state()
        if len(roles) > 128:
            return
        snapshot = {"version": 1, "task_generation_id": context.generation,
                    "instruction_revision": context.instruction_revision, "roles": roles}
        fingerprint = hashlib.sha256(json.dumps(snapshot, sort_keys=True, separators=(",", ":"),
                                        ensure_ascii=True).encode()).hexdigest()
        if fingerprint == context.input_roles_fingerprint:
            return
        context.input_roles_fingerprint = fingerprint
        context.input_roles_revision += 1
        emit("task_input_roles", revision=context.input_roles_revision, **snapshot)
    except Exception:
        # This view-only projection cannot affect execution or evidence.
        return


def publish_task_continuation_checkpoint(ledger: TaskEvidenceLedger) -> None:
    """Publish a bounded in-memory recovery capsule, never execution history."""
    context = current_task.get()
    if context is None or context.generation is None:
        return
    try:
        # A terminal delivery without an established effect must not make an
        # old mutation replayable from a continuation checkpoint. Keep only
        # opaque action IDs in task memory; the checkpoint exposes a count.
        unresolved_receipts = max(
            _task_value("receipt_metrics").get("receipt_unresolved", 0),
            len(context.continuation_uncertain_receipt_ids),
        )
        snapshot = ledger.continuation_snapshot(
            instruction_revision=_task_value("instruction_revision"),
            unresolved_receipts=unresolved_receipts,
            revision=1,
        )
        payload = snapshot or {
            "version": 1,
            "eligible": False,
            "task_sha256": hashlib.sha256(ledger.task.encode("utf-8")).hexdigest(),
            "input_references_sha256": ledger._input_reference_fingerprint(),
            "source_task_generation_id": context.generation,
            "instruction_revision": _task_value("instruction_revision"),
            "revision": 1,
            "requirements": [], "observation_targets": {}, "batch": None,
            "expected_file_identities": {}, "expected_web_destinations": {}, "result_summaries": [],
            "unresolved_receipts": unresolved_receipts,
        }
        stable = dict(payload)
        stable.pop("revision", None)
        fingerprint = hashlib.sha256(json.dumps(stable, sort_keys=True, separators=(",", ":"),
                                                  ensure_ascii=True).encode()).hexdigest()
        if fingerprint == context.continuation_fingerprint:
            return
        context.continuation_fingerprint = fingerprint
        context.continuation_revision += 1
        payload["eligible"] = snapshot is not None
        payload["revision"] = context.continuation_revision
        emit("task_continuation_checkpoint", **payload, task_generation_id=context.generation)
    except Exception:
        # Recovery presentation is optional; proof and execution remain authoritative.
        return


def runtime_fingerprint(key: str) -> str:
    if key:
        return hashlib.sha256(key.encode()).hexdigest()
    # A profile-file digest invalidates readiness after external credential edits
    # without ever storing or emitting the credential itself.
    profile = Path(os.environ.get("OPENCLAW_STATE_DIR", str(Path.home() / ".openclaw"))) / "agents/main/agent/auth-profiles.json"
    try:
        return hashlib.sha256(profile.read_bytes()).hexdigest()
    except OSError:
        return "unconfigured"


def openclaw_version(path: str) -> str:
    result = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError("OpenClaw could not report its version. Repair the installation in Settings.")
    return result.stdout.strip()


def synchronize_model_configuration(path: str, state: RuntimeState) -> None:
    with configuration_transaction():
        _synchronize_model_configuration(path, state)


def _synchronize_model_configuration(path: str, state: RuntimeState) -> None:
    if state.configuration_version() == CONFIG_VERSION:
        return
    removed = {f"google/gemini-{v}-flash" for v in ("3.5", "3.6", "3.7")}
    def read(setting: str) -> Any:
        result = subprocess.run([path, "config", "get", setting], capture_output=True, text=True, timeout=15)
        if result.returncode:
            return None
        try:
            return json.loads(result.stdout)
        except ValueError:
            return result.stdout.strip()
    def write(setting: str, value: Any) -> None:
        result = subprocess.run([path, "config", "set", setting, json.dumps(value), "--strict-json", "--replace"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        if result.returncode:
            raise RuntimeError(f"TaskPilot could not update its {setting} model configuration. Reconfigure OpenClaw in Settings.")
    allowed = read("agents.defaults.modelPolicy.allow") or []
    extras = [m for m in allowed if isinstance(m, str) and m not in ALL_MODELS and m not in removed] if isinstance(allowed, list) else []
    write("agents.defaults.modelPolicy.allow", list(ALL_MODELS) + extras)
    model = read("agents.defaults.model")
    current = model if isinstance(model, dict) else {}
    extras = [m for m in current.get("fallbacks", []) if m not in ALL_MODELS and m not in removed]
    write("agents.defaults.model", {**current, "primary": PRIMARY_MODELS[0], "fallbacks": list(ALL_MODELS[1:]) + extras})
    image = read("agents.defaults.imageModel")
    if isinstance(image, dict):
        write("agents.defaults.imageModel", {**image, "primary": PRIMARY_MODELS[0], "fallbacks": [m for m in image.get("fallbacks", []) if m not in removed and m != PRIMARY_MODELS[0]]})
    aliases = read("agents.defaults.models")
    if isinstance(aliases, dict) and removed.intersection(aliases):
        write("agents.defaults.models", {m: v for m, v in aliases.items() if m not in removed})
    state.configuration_updated()


def model_configuration_fingerprint() -> str:
    path = Path(os.environ.get("OPENCLAW_CONFIG_PATH", str(Path.home() / ".openclaw/openclaw.json")))
    try:
        defaults = json.loads(path.read_text()).get("agents", {}).get("defaults", {})
        settings = {key: defaults.get(key) for key in ("model", "modelPolicy", "imageModel", "models")}
        return hashlib.sha256(json.dumps(settings, sort_keys=True).encode()).hexdigest()
    except (OSError, ValueError, AttributeError):
        return "unconfigured"


def prepare_runtime(path: str, key: str) -> RuntimeState:
    with configuration_transaction():
        fingerprint = runtime_fingerprint(key)
        descriptor_path = os.environ.get('TASKPILOT_MANAGED_DESCRIPTOR')
        version = 'OpenClaw ' + managed_openclaw.load_descriptor(Path(descriptor_path))['openclaw_version'] if descriptor_path else openclaw_version(path)
        state = RuntimeState(fingerprint, version, configuration=model_configuration_fingerprint())
        if not os.environ.get("TASKPILOT_MANAGED_DESCRIPTOR"):
            synchronize_model_configuration(path, state)
        state = RuntimeState(fingerprint, version, configuration=model_configuration_fingerprint())
        if key and not os.environ.get("TASKPILOT_MANAGED_DESCRIPTOR"):
            sync_openclaw_google_key(path, key)
        return state


def synthetic_check_image(path: Path) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = b"".join(b"\0" + b"\xff\xff\xff" * 16 for _ in range(16))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) +
                     chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def check_models(path: str, key: str, read_only: bool = False) -> bool:
    with screenshot_buffer_scope():
        result = _check_models(path, key, read_only)
        if result and not read_only and os.environ.get("TASKPILOT_MANAGED_DESCRIPTOR"):
            managed_openclaw.mark_working(Path(os.environ["TASKPILOT_MANAGED_DESCRIPTOR"]))
        return result


def _check_models(path: str, key: str, read_only: bool = False) -> bool:
    if not read_only and os.environ.get('TASKPILOT_MANAGED_DESCRIPTOR'):
        managed_openclaw.wait_for_health(Path(os.environ['TASKPILOT_MANAGED_DESCRIPTOR']))
        path = refresh_managed_descriptor()['executable']
    descriptor = managed_openclaw.load_descriptor(Path(os.environ['TASKPILOT_MANAGED_DESCRIPTOR'])) if os.environ.get('TASKPILOT_MANAGED_DESCRIPTOR') else None
    version = "OpenClaw " + descriptor['openclaw_version'] if descriptor else None
    state = RuntimeState(runtime_fingerprint(key), version or openclaw_version(path), configuration=model_configuration_fingerprint()) if read_only else prepare_runtime(path, key)
    if read_only:
        return _perform_model_check(path, state, read_only=True)
    with state.explicit_check() as coalesced:
        result = False
        try:
            result = _perform_model_check(path, state, read_only=coalesced, key=key)
            return result
        finally:
            if not coalesced: state.finish_check(result)


def _perform_model_check(path: str, state: RuntimeState, read_only: bool = False, key: str = "") -> bool:
    checks = {m: {"model": m, "state": "configured", "detail": "Configured; not verified through TaskPilot"} for m in ALL_MODELS}
    for model in ALL_MODELS:
        checks[model].update(state.health(model))
    cached = state.verified_model()
    if cached:
        checks[cached].update(state="verified", detail="Verified through TaskPilot within the last ten minutes")
        emit("model_checks", checks=list(checks.values()), cached=True)
        return True
    if read_only:
        emit("model_checks", checks=list(checks.values()), cached=False)
        return False
    # A reported reset suppresses premature checks. With no reset, an explicit
    # Check may probe the owning model once to detect repaired billing/quota.
    unresolved = next((m for m in ALL_MODELS if state.credential_health(m).get("state") == "temporary" and
                       state.credential_health(m).get("retry_at") is None), None)
    probes = {m for m in ALL_MODELS if state.health(m).get("state") == "temporary" and state.health(m).get("retry_at") is None}
    if unresolved:
        owner = model_route(Failure.from_health(state.credential_health(unresolved)), unresolved)
        unresolved = owner if owner in ALL_MODELS else unresolved
        probes = {unresolved}
    if all(state.health(m).get("state") == "temporary" for m in ALL_MODELS) and not probes:
        emit("model_checks", checks=list(checks.values()), cached=False, prompt_calls=0, repairs=0)
        return False
    try:
        with configuration_transaction():
            latest = prepare_runtime(path, key)
            if latest.identity != state.identity:
                # Configuration changed while waiting for the check lease. Do not
                # publish a result under a snapshot that no longer describes ACP.
                emit("model_checks", checks=list(checks.values()), cached=False, prompt_calls=0, repairs=0)
                return False
            client = ACPClient(path)
            client.readiness_state = state
    except Exception as error:
        state.record_failure(PRIMARY_MODELS[0], classify_failure(error, time.time(), PRIMARY_MODELS[0]))
        checks[PRIMARY_MODELS[0]].update(state.health(PRIMARY_MODELS[0]))
        emit("model_checks", checks=list(checks.values()), cached=False, prompt_calls=0)
        return False
    try:
        with tempfile.TemporaryDirectory(prefix="taskpilot-check-") as directory:
            image = Path(directory) / "check.png"
            synthetic_check_image(image)
            budget = ResponseRepairBudget()
            exhausted: set[str] = set()
            for model in ALL_MODELS:
                if model in exhausted or (model not in probes and state.health(model).get("state") == "temporary"):
                    continue
                try:
                    health, started_revision = state.attempt_snapshot(model)
                    if model not in probes and health.get("state") == "temporary": continue
                    client.select_model(model)
                    validated_prompt(client, 'Do not call tools. Inspect this synthetic image and return exactly {"status":"done","check":"TASKPILOT_READY"}.', image, "readiness", budget)
                except Exception as error:
                    failure = classify_failure(error, time.time(), model)
                    state.record_failure(model, failure)
                    probes.discard(model)
                    if failure.scope == "credential":
                        probes.difference_update(m for m in ALL_MODELS if m.startswith((failure.provider or model.split('/', 1)[0]) + '/'))
                    stop = failure.kind in {"credentials", "transport", "configuration", "cancelled"}
                    for item in failure.attempts:
                        prior = Failure.from_health(item)
                        prior.recovered_upstream = True
                        if not prior.model and not (prior.scope == "credential" and prior.provider == model.split('/', 1)[0]):
                            continue
                        route = model_route(prior, model)
                        if route in ALL_MODELS:
                            state.record_failure(route, prior)
                            if prior.scope == "credential":
                                probes.difference_update(m for m in ALL_MODELS if m.startswith((prior.provider or model.split('/', 1)[0]) + '/'))
                            exhausted.add(route)
                            stop = stop or prior.kind in {"credentials", "transport", "configuration", "cancelled"}
                    for other in ALL_MODELS:
                        checks[other].update(state.health(other))
                    if stop:
                        break
                    continue
                verified = state.verify(model, started_revision)
                for other in ALL_MODELS:
                    checks[other] = {"model": other, "state": "configured", "detail": "Configured; not verified through TaskPilot", **state.health(other)}
                if verified:
                    checks[model].update(state="verified", detail="Verified through TaskPilot with image input and structured output")
                break
    finally:
        client.close()
    emit("model_checks", checks=list(checks.values()), cached=False, prompt_calls=client.prompt_calls, repairs=int(budget.used))
    return any(c["state"] == "verified" for c in checks.values())


def bridge_exchange(method: str, display_id: int, params: dict[str, Any], timeout: float | None = None,
                    working_document_revision: int | None = None) -> dict[str, Any]:
    request_id = str(uuid.uuid4())
    inbox = runtime_inbox()
    generation = _task_value('generation')
    context = current_task.get()
    revision = context.instruction_revision if context is not None else 0
    binding_revision = (context.working_document_revision if working_document_revision is None and context is not None
                        else _task_value('working_document_revision') if working_document_revision is None
                        else working_document_revision)
    key = inbox.register('bridge_response', request_id, generation)
    try:
        emit("bridge_request", request_id=request_id, method=method,
             instruction_revision=revision, working_document_revision=binding_revision,
             params={"display_id": display_id, **params})
        response = json.loads(runtime_line(timeout, key=key))
        if not isinstance(response, dict):
            raise NativeProtocolError("bridge_response must be an object")
        if generation is not None and response.get("task_generation_id") != generation:
            raise RuntimeError("TaskPilot received a bridge reply for a different task")
        if context is not None and response.get("instruction_revision") != revision:
            raise InstructionSuperseded("The native response belongs to an older instruction revision")
        if (generation is not None or context is not None) and response.get("working_document_revision") != binding_revision:
            raise WorkingDocumentSuperseded("The native response belongs to another working document revision")
        if response.get("error_code") == "instruction_superseded":
            if method == "act" and context is not None:
                action_id = params.get("action_id")
                if action_id and context.machine.pending_action == action_id:
                    context.machine.resolve(action_id)
            raise InstructionSuperseded(response.get("error") or "A newer correction superseded this decision")
        if response.get("error_code") == "working_document_superseded":
            if method == "act" and context is not None:
                action_id = params.get("action_id")
                if action_id and context.machine.pending_action == action_id:
                    context.machine.resolve(action_id)
            raise WorkingDocumentSuperseded(response.get("error") or "The working document changed")
        return response
    finally:
        inbox.transport.unregister(key)


def task_requests_save_or_export(task: str,
                                exact_input_references: list[dict[str, Any]] | None = None) -> bool:
    """Permit standard Save/Export UI only when user instructions ask for it.

    Exact-input values are task data. Mask their validated UTF-8 source ranges
    before looking for instructions so a filename, URL, or pasted literal that
    happens to say "save" or "export" cannot grant an execution exception.
    """
    text = str(task or "")
    if exact_input_references:
        bindings = TaskInputBindings(text, exact_input_references=exact_input_references)
        encoded = bytearray(text.encode("utf-8"))
        for _, start, length, _ in bindings.exact_references:
            end = start + length
            for index in range(start, end):
                if encoded[index] not in (0x0A, 0x0D):
                    encoded[index] = 0x20
        text = encoded.decode("utf-8")
    positive = list(re.finditer(r"\b(?:save|export)\b", text, re.I))
    if not positive:
        return False
    negated = list(re.finditer(
        r"\b(?:do not|don't|never|avoid|without)\s+(?:(?:send|publish|submit|replace|overwrite|change|edit|create|save|export)\s+or\s+)*(?:save|saving|export|exporting)\b|\bno need to (?:save|export)\b",
        text, re.I))
    return any(not any(span.start() <= match.start() < span.end() for span in negated) for match in positive)


def bridge_call(method: str, display_id: int, **params: Any) -> dict[str, Any]:
    budget = current_budget.get()
    if budget is None:
        seconds = 30.0 if method == 'act' else 5.0
        if method == 'act' and params.get('action', {}).get('type') == 'run_command':
            seconds += float(params['action'].get('timeout_seconds', action_default('run_command', 'timeout_seconds')))
        with local_scope(seconds, method):
            return bridge_call(method, display_id, **params)
    budget.check(method)
    context = current_task.get()
    if context is not None:
        effect = {"act": "execute", "observe": "observe", "action_receipt": "receipt",
                  "check_effect": "read", "wait_file_effect": "read", "recheck": "read",
                  "inspect_command": "read", "wait_for_change": "read",
                  "completion_gate": "complete", "bind_working_document": "read",
                  "bind_task_target_choice": "target_choice"}.get(method)
        if effect is None: raise ExecutionStateError("Unknown task bridge operation")
        context.machine.require(effect)
    timeout = params.pop("_reply_timeout", None)
    working_document_revision = params.pop("_working_document_revision", None)
    if method == "observe":
        params.setdefault("observation_keywords", _task_value('observation_keywords'))
    if method == "act":
        if _task_value("bridge_observation_revision"):
            params.setdefault("observation_revision", _task_value("bridge_observation_revision"))
        # A UUID represents this logical execution, not a hash of its payload.
        # Repairs and model selection happen before it can be allocated.
        if "action_id" not in params:
            params["action_id"] = str(uuid.uuid4()).lower()
        elif isinstance(params["action_id"], str):
            params["action_id"] = params["action_id"].lower()
        if context is not None:
            params["target_binding_revision"] = context.target_binding_revision
            params["target_bindings"] = list(context.target_bindings)
            params["target_requirement_ids"] = (
                context.ledger.action_requirements(context.decision)
                if context.ledger is not None and isinstance(context.decision, dict) else []
            )
            params["intended_target"] = (
                context.decision.get("intended_target")
                if isinstance(context.decision, dict) else None
            )
            params["working_selection_save_export_allowed"] = task_requests_save_or_export(
                context.task, context.exact_input_references)
            action_type = params.get("action", {}).get("type")
            context.presentation_action_id = params["action_id"] if action_type in {"press", "click", "double_click", "scroll"} else None
            context.current_action_receipt_id = params["action_id"]
        timeout = 30.0
        if params.get("action", {}).get("type") == "run_command":
            timeout += float(params["action"].get("timeout_seconds", action_default("run_command", "timeout_seconds")))
        if context is not None: context.machine.dispatch(params["action_id"])
    # Pass a remaining allowance, never a monotonic timestamp across processes.
    remaining = budget.check(method)
    params['local_budget_ms'] = max(1, math.floor(remaining * 1000))
    timeout = remaining if timeout is None else min(timeout, remaining)
    try:
        if context is None and working_document_revision is None:
            # Keep isolated bridge fixtures and generation-free local helpers
            # compatible; real task calls always carry the binding revision.
            response = bridge_exchange(method, display_id, params, timeout)
        else:
            response = bridge_exchange(method, display_id, params, timeout, working_document_revision)
        if not isinstance(response, dict) or type(response.get('ok')) is not bool:
            raise NativeProtocolError('bridge_response.ok must be a boolean')
        if response['ok']:
            if not isinstance(response.get('result'), dict):
                raise NativeProtocolError('bridge_response.result must be an object')
            if any(key in response for key in CONTRACT['native_schemas']['error']['fields'] if key != 'terminal'):
                raise NativeProtocolError('bridge_response cannot contain both a result and error fields')
        else:
            if 'result' in response: raise NativeProtocolError('bridge_response cannot contain both a result and error fields')
            validate_native_payload('error', {key: response[key] for key in
                CONTRACT['native_schemas']['error']['fields'] if key in response}, 'bridge_response.error_payload')
        if method == 'act':
            header = response.get('action_receipt')
            if header is not None:
                if not isinstance(header, dict) or set(header) != {'action_id', 'state', 'terminal'}:
                    raise NativeProtocolError('bridge_response.action_receipt must contain only action_id, state and terminal')
                if header.get('terminal') is False:
                    validate_native_receipt(header, params['action_id'])
                    if response['ok'] or response['outcome'] != 'dispatched' or header['state'] not in {'pending', 'dispatched'}:
                        raise NativeProtocolError('bridge_response.action_receipt must agree with dispatched work')
                    raise BridgeReplyLost('The native action is still pending')
                receipt = dict(header)
                if response['ok']: receipt['result'] = response['result']
                else: receipt.update({key: response[key] for key in CONTRACT['native_schemas']['error']['fields']})
                validate_native_receipt(receipt, params['action_id'], params['action'])
            elif response['ok']:
                raise NativeProtocolError('bridge_response.action_receipt is required for native actions')
            elif response['terminal'] is False:
                raise BridgeReplyLost('The native action is still dispatched')
    except BridgeReplyLost as error:
        if method != "act": raise
        if context is not None: context.machine.reconcile()
        if not error.connected:
            _task_value('receipt_metrics')["receipt_unresolved"] += 1
            mark_continuation_receipt_uncertain(params.get("action"), params.get("action_id"))
            raise
        if error.code:
            emit('status', message=f'Native transport failure ({error.code}); checking the action receipt without repeating it…')
        response = reconcile_receipt(params["action_id"],
            lambda action_id, remaining: bridge_call("action_receipt", display_id,
                action_id=action_id, _reply_timeout=remaining), _task_value('receipt_metrics'),
            clock=time.monotonic, sleep=time.sleep, action=params['action'])
    if not response['ok']:
        if response['error_code'] == 'protocol_error': raise NativeProtocolError(response['error'])
        if context is not None and method == 'act': context.machine.resolve(params['action_id'])
        raise ActionRejected(response['error'], response['error_code'],
                             {'outcome': response['outcome'], 'verification_scope': response['verification_scope']})
    result = response.get("result")
    if isinstance(result, dict):
        if method == 'act':
            validate_native_result(result, params['action'])
            if context is not None: context.machine.resolve(params['action_id'])
        elif method == 'action_receipt': validate_native_receipt(result, params['action_id'])
        elif method in {'check_effect', 'wait_file_effect'}:
            validate_check_batch(result, requested_checks=[params['check']])
        elif method == 'recheck': validate_native_readback(result, params['action'])
        if method == "observe" and isinstance(result, dict):
            if _task_value('generation') is not None and result.get("task_generation_id") != _task_value('generation'):
                raise ActionRejected("Observation belongs to another task", "cancelled")
            result = dict(result)
            result.pop("task_generation_id", None)
            try:
                validate_observation_mapping(result, required=_task_value('generation') is not None)
                validate_completeness(result, required=_task_value('generation') is not None)
                validate_text_recognition(result, required=_task_value('generation') is not None)
            except (CoordinateMappingError, ObservationCompletenessError, TextRecognitionError) as error:
                _set_task_value("bridge_observation_revision", None)
                discard_observation_image(result)
                raise ActionRejected(str(error), "observation_unstable") from error
            _set_task_value("bridge_observation_revision", result.get("observation_revision"))
        return result
    raise NativeProtocolError('bridge_response.result must be an object')


def find_openclaw(explicit_path: str | None = None) -> str:
    descriptor_path = os.environ.get("TASKPILOT_MANAGED_DESCRIPTOR")
    if descriptor_path:
        descriptor = managed_openclaw.activate_environment(Path(descriptor_path))
        if explicit_path and os.path.realpath(explicit_path) != os.path.realpath(descriptor['executable']):
            raise managed_openclaw.ManagedRuntimeError("OpenClaw executable does not match the private runtime descriptor.")
        return descriptor['executable']
    # Explicit paths are retained for isolated test fixtures and old integrations;
    # production startup always supplies a managed descriptor. No PATH discovery.
    if explicit_path and os.path.isfile(explicit_path) and os.access(explicit_path, os.X_OK): return explicit_path
    raise managed_openclaw.ManagedRuntimeError("TaskPilot did not provide its private OpenClaw runtime descriptor.")


def default_openclaw_key_state_path() -> Path:
    override = os.environ.get("ORBIT_OPENCLAW_KEY_STATE")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / LEGACY_APPLICATION_SUPPORT_FOLDER / "openclaw-key-state.json"


def sync_openclaw_google_key(
    openclaw_path: str,
    api_key: str,
    state_path: Path | None = None,
) -> None:
    with configuration_transaction():
        _sync_openclaw_google_key(openclaw_path, api_key, state_path)


def _sync_openclaw_google_key(
    openclaw_path: str,
    api_key: str,
    state_path: Path | None = None,
) -> None:
    """Keep OpenClaw's google:orbit profile aligned with TaskPilot's saved key.

    The secret crosses only a private stdin pipe. The persisted comparison is
    a one-way digest, so TaskPilot can avoid restarting the Gateway on every task.
    """
    key = api_key.strip()
    if len(key) < 20:
        raise RuntimeError(
            f"Add and save a complete Gemini API key in {PRODUCT_NAME} Settings before running a task."
        )
    destination = state_path or default_openclaw_key_state_path()
    fingerprint = hashlib.sha256(key.encode("utf-8")).hexdigest()
    try:
        current = json.loads(destination.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        current = {}
    if isinstance(current, dict) and current.get("fingerprint") == fingerprint:
        return

    environment = dict(os.environ)
    environment["OPENCLAW_HIDE_BANNER"] = "1"
    environment["OPENCLAW_SUPPRESS_NOTES"] = "1"
    try:
        saved = subprocess.run(
            [
                openclaw_path, "models", "auth", "paste-api-key",
                "--provider", "google", "--profile-id", "google:orbit",
            ],
            input=key + "\n",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
            check=False,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(
            f"{PRODUCT_NAME} could not synchronize the saved Gemini API key with OpenClaw. "
            "Open Settings and click Reconfigure Gemini."
        ) from error
    finally:
        key = ""
    if saved.returncode != 0:
        raise RuntimeError(
            "OpenClaw rejected the saved Gemini API key. Open Settings and click Reconfigure Gemini."
        )

    # The Gateway keeps provider credentials in memory. Restart only after the
    # saved key changes, before ACP connects, so the next turn cannot use a
    # stale credential from an earlier TaskPilot setup.
    restarted = subprocess.run(
        [openclaw_path, "gateway", "restart"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=30,
        check=False,
        env=environment,
    )
    if restarted.returncode != 0:
        raise RuntimeError(
            f"{PRODUCT_NAME} saved the Gemini key, but OpenClaw could not reload it. "
            "Open Settings and click Reconfigure Gemini."
        )
    healthy = False
    for _attempt in range(12):
        health = subprocess.run(
            [openclaw_path, "health", "--json"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=8,
            check=False,
            env=environment,
        )
        if health.returncode == 0:
            healthy = True
            break
        time.sleep(0.5)
    if not healthy:
        raise RuntimeError(
            "OpenClaw did not become ready after reloading the Gemini key. "
            "Open Settings and click Reconfigure Gemini."
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps({"version": 1, "fingerprint": fingerprint}, separators=(",", ":")),
            encoding="utf-8",
        )
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def session_transcript_cursor(session_id: str, sessions_root: Path | None = None) -> tuple[Path, int] | None:
    root = sessions_root or Path(os.environ.get("OPENCLAW_STATE_DIR", str(Path.home() / ".openclaw"))) / "agents/main/sessions"
    try:
        registry = json.loads((root / "sessions.json").read_text())
        for name, value in registry.items():
            if name.endswith(f":{session_id}") and isinstance(value, dict):
                path = Path(value.get("sessionFile", "")).expanduser().resolve()
                if path.is_relative_to(root.resolve()) and path.is_file():
                    return path, path.stat().st_size
    except (OSError, ValueError, AttributeError):
        pass
    return None


def openclaw_session_error(session_id: str, sessions_root: Path | None = None,
                           after_cursor: tuple[Path, int] | None = None, *,
                           structured: bool = False, started_at: float | None = None) -> Any:
    """Recover provider failures that the current ACP bridge does not stream.

    OpenClaw records some Google capacity failures as a normal assistant
    message (for example, "temporarily overloaded") with stopReason=stop.
    ACP currently completes those turns without streaming the message body, so
    inspect the newest assistant record as well as explicit error records.
    """
    root = sessions_root or Path(os.environ.get("OPENCLAW_STATE_DIR", str(Path.home() / ".openclaw"))) / "agents/main/sessions"
    try:
        registry = json.loads((root / "sessions.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    if not isinstance(registry, dict):
        return ""
    entry: dict[str, Any] | None = None
    for key, value in registry.items():
        if isinstance(key, str) and key.endswith(f":{session_id}") and isinstance(value, dict):
            entry = value
            break
    if entry is None:
        return ""
    raw_session_file = entry.get("sessionFile")
    if not isinstance(raw_session_file, str) or not raw_session_file:
        return ""
    try:
        resolved_root = root.resolve()
        session_file = Path(raw_session_file).expanduser().resolve()
        if not session_file.is_relative_to(resolved_root):
            return ""
        with session_file.open("rb") as handle:
            size = handle.seek(0, os.SEEK_END)
            offset = after_cursor[1] if after_cursor and after_cursor[0] == session_file else 0
            handle.seek(max(offset, size - 262_144, 0), os.SEEK_SET)
            tail = handle.read().decode("utf-8", errors="ignore")
    except OSError:
        return ""
    for raw_line in reversed(tail.splitlines()):
        try:
            item = json.loads(raw_line)
        except json.JSONDecodeError:
            continue
        message = item.get("message") if isinstance(item, dict) else None
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        if started_at is not None and after_cursor is None and not current_transcript_message(message, item, started_at):
            return ""
        if message.get("stopReason") == "error":
            detail = message.get("errorMessage") or message.get("error")
            return message if structured else message_text(detail, "").strip()[:500]
        content = message.get("content")
        parts = content if isinstance(content, list) else [content]
        assistant_text = " ".join(
            str(part.get("text") or "").strip()
            for part in parts
            if isinstance(part, dict) and isinstance(part.get("text"), str)
        ).strip()
        lowered = assistant_text.lower()
        credential_failure = any(marker in lowered for marker in (
            "api key not valid", "invalid api key", "invalid credential",
            "permission denied", "forbidden", "unauthorized",
        ))
        if assistant_text and (is_model_capacity_failure(assistant_text) or credential_failure):
            return assistant_text if structured else assistant_text[:500]
        # Do not walk into an older turn and accidentally report a stale error.
        return ""
    return ""


def current_transcript_message(message: dict[str, Any], item: dict[str, Any], started_at: float) -> bool:
    stamp = message.get("timestamp") or item.get("timestamp")
    if isinstance(stamp, str):
        try: stamp = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() * 1000
        except (ValueError, OverflowError): return False
    return type(stamp) in {int, float} and stamp >= started_at


def user_facing_openclaw_error(detail: str) -> str:
    cleaned = " ".join(detail.split()).strip()
    lowered = cleaned.lower()
    if "api key not valid" in lowered or "invalid api key" in lowered or "invalid credential" in lowered:
        return (
            "Gemini rejected the saved API key. Open Settings → Gemini API key, enter the current key, "
            "click Check, then click Reconfigure Gemini."
        )
    return cleaned[:400]


def normalized_action(value: Any) -> dict[str, Any]:
    return normalize_action(value)


def effective_decision_status(decision: dict[str, Any]) -> str:
    """Recover models that label an otherwise valid next action as blocked."""
    status = str(decision.get("status") or "")
    action = decision.get("action")
    if status == "blocked" and isinstance(action, dict):
        action_type = str(action.get("type") or "")
        if action_type in VALID_ACTIONS - {"none"}:
            return "act"
    return status


def action_identity(action: dict[str, Any], observation: dict[str, Any]) -> str:
    """Identify an action independently of per-observation element IDs."""
    identity = {k: v for k, v in action.items() if k not in {"element_id", "observation_revision"}}
    indexes = observation_indexes(observation)
    element = indexes.element(action.get("element_id"))
    if element:
        identity["target"] = {k: element.get(k) for k in ("pid", "role", "title")}
        identity["target"]["structure"] = structural_identity(element, observation, indexes)
    return json.dumps(identity, sort_keys=True, separators=(",", ":"))


def action_may_mutate(action: dict[str, Any], observation: dict[str, Any]) -> bool:
    kind = action.get("type")
    if kind in {"type_text", "set_value", "write_file", "run_command"}:
        return True
    if kind == "key":
        key = str(action.get("key")).lower()
        modifiers = {str(m).lower() for m in action.get("modifiers", [])}
        if key in {"tab", "escape", "left", "right", "up", "down", "home", "end", "page_up", "page_down"}:
            return False
        return not (key in {"a", "c", "f", "l"} and modifiers in ({"command"}, {"cmd"}))
    if kind not in {"press", "click", "double_click"}:
        return False
    element = observation_indexes(observation).element(action.get("element_id")) or {}
    label = str(element.get("title") or "")
    # Treat unknown controls as mutations. Only explicit navigation affordances
    # may be repeated after verified nonexecution; labels alone cannot prove
    # that a button such as "Increment" or "Continue" is harmless.
    if element.get("role") == "AXMenuBarItem":
        return False
    return label.strip().casefold() not in {"back", "forward", "next page", "previous page"}



def action_target(action: dict[str, Any], observation: dict[str, Any]) -> dict[str, Any] | None:
    indexes = observation_indexes(observation)
    if action.get("element_id"):
        return indexes.element(action["element_id"])
    pid = action.get("pid")
    if action.get("type") in {"type_text", "key"}:
        fields = [e for e in indexes.elements_by_pid.get(pid, ()) if e.get("focused") is True
                  and e.get("role") in {"AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"}]
        return fields[0] if len(fields) == 1 else None
    if "x" not in action or "y" not in action:
        return None
    targets = coordinate_targets(action, observation, indexes)
    return targets[0] if targets else None


def action_target_pid(action: dict[str, Any], observation: dict[str, Any]) -> int | None:
    target = action_target(action, observation)
    return target.get("pid") if target else action.get("pid")


def observation_window_state(application: dict[str, Any]) -> list[dict[str, Any]]:
    """Stable window evidence, excluding scoped IDs and activation metadata."""
    windows = [{key: window[key] for key in ("title", "frame", "source") if key in window}
               for window in application.get("windows", []) if isinstance(window, dict)]
    return sorted(windows, key=lambda window: json.dumps(window, sort_keys=True))


def target_identity(target: dict[str, Any] | None, observation: dict[str, Any]) -> dict[str, Any] | None:
    # Role changes do not establish that a mutation is safe to send again.
    return {**{k: target.get(k) for k in ("pid", "title", "window_title")},
            "structure": structural_identity(target, observation)} if target else None


def action_failure_recovery(code: str) -> str:
    return {"local_budget_exhausted": "inspect_after_local_budget", "file_conflict": "inspect_filesystem_again", "stale_target": "observe_again", "disabled_target": "wait_or_choose_enabled",
            "focus_mismatch": "observe_and_refocus", "activation_failed": "observe_and_activate",
            "unsupported_action": "choose_supported_method", "ambiguous_target": "select_specific_control",
            "stop_boundary_rejected": "inspect_or_choose_safe_preparation",
            "stop_boundary_uncertain": "inspect_or_choose_safe_preparation",
            "delivery_uncertain": "inspect_effect", "command_tool_missing": "select_installed_tool",
            "command_options_unverified": "choose_inspected_options", "command_capabilities_changed": "inspect_command_again",
            "command_syntax": "correct_command_syntax"}.get(code, "choose_different_action")


class ActionRecovery:
    """Task-local bounds and effect checks; never execute a replacement action."""
    def __init__(self) -> None:
        self.failures: dict[str, int] = {}
        self.uncertain: list[tuple[dict[str, Any], dict[str, Any]]] = []
        self.suppressed: set[str] = set()

    def failure_key(self, action: dict[str, Any], observation: dict[str, Any]) -> str:
        target = action_target(action, observation)
        pid = action_target_pid(action, observation)
        parameters = {k: v for k, v in action.items() if k not in {"element_id", "observation_revision"}
                      and not (target and k in {"pid", "x", "y"})}
        context = {"action": parameters,
                   "target": {k: v for k, v in (target or {}).items() if k not in {"id", "parent_id", "window_id"}},
                   "windows": sorted([w for a in observation.get("applications", [])
                                      if isinstance(a, dict) and a.get("pid") == pid
                                      for w in observation_window_state(a)], key=lambda w: json.dumps(w, sort_keys=True))}
        return json.dumps(context, sort_keys=True)

    def rejected(self, action: dict[str, Any], observation: dict[str, Any], code: str) -> None:
        key = self.failure_key(action, observation)
        self.failures[key] = self.failures.get(key, 0) + 1
        if code == "delivery_uncertain":
            self.unconfirmed(action, observation)

    def unconfirmed(self, action: dict[str, Any], observation: dict[str, Any]) -> None:
        if action_may_mutate(action, observation):
            self.uncertain.append((action.copy(), observation))

    def succeeded(self, action: dict[str, Any], observation: dict[str, Any]) -> None:
        self.failures.pop(self.failure_key(action, observation), None)

    def overlaps(self, previous: dict[str, Any], before: dict[str, Any],
                 action: dict[str, Any], observation: dict[str, Any]) -> bool:
        if previous.get("type") in TRUSTED_NATIVE_ACTIONS or action.get("type") in TRUSTED_NATIVE_ACTIONS:
            if previous.get("type") == action.get("type") == "run_command":
                def effect(value):
                    source = value.get("command")
                    argv = value.get("argv")
                    if argv is None and isinstance(source, str):
                        # Compare only literal single commands across representations.
                        # Expansion/control operators keep their exact shell identity.
                        if not any(c in source for c in "$`|;&<>*?(){}\\\n"):
                            try: argv = shlex.split(source)
                            except ValueError: pass
                    cwd = os.path.normpath(os.path.expanduser(value.get("working_directory") or "~"))
                    return (argv if argv is not None else source, cwd)
                return effect(previous) == effect(action)
            if previous.get("type") == action.get("type") == "write_file":
                return os.path.normpath(os.path.expanduser(previous["path"])) == os.path.normpath(os.path.expanduser(action["path"]))
            return action_identity(previous, before) == action_identity(action, observation)
        pid = action_target_pid(previous, before)
        if pid is None or pid != action_target_pid(action, observation):
            return False
        if any(a.get("type") in {"click", "double_click"} and not a.get("element_id") for a in (previous, action)):
            return True  # Screenshot-only coordinates cannot prove a different control.
        # Enter can submit a form whose button has a different label/role.
        if any(a.get("type") == "key" and str(a.get("key", "")).lower() in {"return", "enter"}
               for a in (previous, action)):
            return True
        old_target, new_target = action_target(previous, before), action_target(action, observation)
        if old_target and new_target and old_target.get("native_identity") \
                and old_target.get("native_identity") == new_target.get("native_identity"):
            return True  # A relabeled panel cannot authorize replay of the same live control.
        first, second = target_identity(old_target, before), target_identity(new_target, observation)
        return first is None or second is None or first == second

    def check(self, action: dict[str, Any], observation: dict[str, Any]) -> dict[str, Any] | None:
        if action_may_mutate(action, observation):
            for previous, before in self.uncertain:
                if not self.overlaps(previous, before, action, observation):
                    continue
                target = action_target(action, observation)
                # Only a complete, nonsecure field value proves a replacement
                # succeeded. A changed screenshot or unchanged screen does not.
                if previous.get("type") == action.get("type") == "set_value" \
                        and previous.get("text") == action.get("text") and target \
                        and target.get("value_complete") is True \
                        and "securetextfield" not in (str(target.get("role", "")) + str(target.get("subrole", ""))).lower() \
                        and target.get("value", "") == action["text"]:
                    return {"message": "The fresh field value matches the earlier replacement; no input was repeated",
                            "outcome": "verified", "delivery_method": "local_check", "verification_scope": "text_value",
                            "recovery": "effect_already_present"}
                key = "uncertain:" + str(action_target_pid(action, observation)) + ":" + action_identity(previous, before)
                if key in self.suppressed:
                    raise RuntimeError("The previous input may already have changed the app. TaskPilot stopped rather than repeat an uncertain mutation.")
                self.suppressed.add(key)
                return {"message": "Do not replay or switch delivery methods for this uncertain mutation. Inspect fresh evidence of its effect, use a read-only check, or report the unresolved result.",
                        "outcome": "suppressed", "recovery": "inspect_effect"}
        key = self.failure_key(action, observation)
        if self.failures.get(key, 0) >= 2:
            if key in self.suppressed:
                raise RuntimeError("TaskPilot stopped after the same rejected action was proposed again without a changed target or recovery method.")
            self.suppressed.add(key)
            return {"message": "This action already failed twice in the same target state. Choose a different valid method or report exhausted recovery; do not send it again.",
                    "outcome": "suppressed", "recovery": "choose_different_action"}
        return None


def blocked_recovery_action(task: str, observation: dict[str, Any], history: list[dict[str, Any]]) -> dict[str, Any] | None:
    named = task_capability_context(task, observation)["explicitly_named_apps"]
    installed = observation.get("installed_applications", [])
    visible = {str(a.get("name", "")).casefold() for a in observation.get("applications", []) if isinstance(a, dict)}
    for name in named:
        matching = [a for a in installed if isinstance(a, dict) and str(a.get("name", "")).casefold() == name.casefold()]
        attempted = any(isinstance(e.get("action"), dict) and e["action"].get("type") == "launch_app"
                        and str(e["action"].get("app", "")).casefold() == name.casefold() for e in history)
        if len(matching) == 1 and name.casefold() not in visible and not attempted:
            return {"type": "launch_app", "app": matching[0]["name"], "bundle_id": matching[0].get("bundle_id", "")}
    return None


def record_action_diagnostic(action: dict[str, Any], result: dict[str, Any]) -> None:
    """Persist only fields admitted by the private diagnostic schema."""
    try:
        folder = Path.home() / "Library/Application Support" / LEGACY_APPLICATION_SUPPORT_FOLDER
        folder.mkdir(parents=True, mode=0o700, exist_ok=True)
        path = folder / "automation-diagnostics.jsonl"
        entry = action_record(action, result, timestamp=time.time(), runtime_pid=os.getpid())
        entry = validate_action_record(entry)
        if entry is None:
            return
        line = (json.dumps(entry, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
        if len(line) > 4_096:
            return
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            status = os.fstat(descriptor)
            if not stat.S_ISREG(status.st_mode) or status.st_uid != os.getuid() or status.st_nlink != 1:
                return
            os.fchmod(descriptor, 0o600)
            if status.st_size + len(line) > 1_000_000:
                os.ftruncate(descriptor, 0)
            offset = 0
            while offset < len(line):
                written = os.write(descriptor, line[offset:])
                if written <= 0:
                    return
                offset += written
        finally:
            os.close(descriptor)
    except (OSError, TypeError, ValueError, OverflowError):
        pass


def observation_progress_signature(observation: dict[str, Any], pid: int | None = None) -> str:
    state = observation_state(observation)
    return state.memoize(("progress", pid), lambda: _observation_progress_signature(observation, pid))


def _observation_progress_signature(observation: dict[str, Any], pid: int | None = None) -> str:
    """Ignore revision churn, foreground restoration and tree enumeration order."""
    apps = []
    for app in observation.get("applications", []):
        if not isinstance(app, dict) or (pid is not None and app.get("pid") != pid): continue
        row = {key: app[key] for key in ("pid", "name", "window_count") if key in app}
        if "windows" in app:
            # Scoped window IDs and foreground flags aid selection, but change
            # between observations/restoration without a meaningful screen change.
            row["windows"] = observation_window_state(app)
        apps.append(row)
    elements = [{key: element[key] for key in
                ("pid", "role", "subrole", "title", "window_title", "value", "value_complete", "focused", "selection_range", "enabled", "busy", "frame", "sort_direction")
                if key in element}
                for element in observation.get("elements", []) if isinstance(element, dict)
                and (pid is None or element.get("pid") == pid)]
    return json.dumps({"applications": sorted(apps, key=lambda item: json.dumps(item, sort_keys=True)),
                       "elements": sorted(elements, key=lambda item: json.dumps(item, sort_keys=True))}, sort_keys=True)


class ScreenshotBuffer:
    """One immutable image read, with a lazy encoding for ACP requests only."""
    def __init__(self, path: Path) -> None:
        self._lock = threading.RLock()
        self._data: bytes | None = path.read_bytes()
        self._digest = hashlib.blake2b(self._data, digest_size=16).hexdigest()
        self._base64: str | None = None

    @property
    def digest(self) -> str:
        with self._lock:
            if self._data is None:
                raise RuntimeError("The observation image has been discarded")
            return self._digest

    @property
    def base64(self) -> str:
        with self._lock:
            if self._data is None:
                raise RuntimeError("The observation image has been discarded")
            if self._base64 is None:
                self._base64 = base64.b64encode(self._data).decode("ascii")
            return self._base64

    def evict_encoding(self) -> None:
        with self._lock: self._base64 = None

    def discard(self) -> None:
        with self._lock:
            self._data = self._base64 = None
            self._digest = ""


class ScreenshotBuffers:
    def __init__(self, generation: str | None) -> None:
        self._lock = threading.RLock()
        self.generation = generation
        self.images: dict[tuple[Path, str | None], ScreenshotBuffer] = {}
        self.current: dict[Path, tuple[Path, str | None]] = {}
        self.states: dict[tuple[Path, str | None], RevisionedJSONState] = {}

    def observation(self, observation: dict[str, Any]) -> RevisionedJSONState:
        with self._lock:
            if self.generation != _task_value('generation'):
                raise ActionRejected("Observation belongs to another task", "cancelled")
            path = Path(str(observation.get("screenshot_path") or "")).absolute()
            key = (path, observation.get("observation_revision"))
            if key not in self.states: self.states[key] = RevisionedJSONState()
            state = self.states[key]
            # Accepted observations are read-only in the loop. The content guard also
            # detects accidental edits and reused revisions without serializing them.
            state.update(coverage_cache_input(observation))
            return state

    def image(self, path: Path, revision: str | None = None) -> ScreenshotBuffer:
        with self._lock:
            if self.generation != _task_value('generation'):
                raise ActionRejected("Observation image belongs to another task", "cancelled")
            path = path.absolute()
            key = (path, revision) if revision is not None else self.current.get(path, (path, None))
            if key not in self.images:
                self.images[key] = ScreenshotBuffer(path)
            self.current[path] = key
            return self.images[key]

    def indexes(self, observation: dict[str, Any]) -> ObservationIndexes:
        if self.generation is not None and observation.get("task_generation_id") not in (None, self.generation):
            raise ActionRejected("Observation indexes belong to another task", "cancelled")
        state = self.observation(observation)
        return state.memoize(("lookup_indexes", OBSERVATION_INDEX_VERSION), lambda: ObservationIndexes(observation))

    def discard(self, path: Path, revision: str | None = None) -> bool:
        with self._lock:
            path = path.absolute()
            for key in list(self.states):
                if key[0] == path and (revision is None or key[1] == revision):
                    self.states.pop(key).clear()
            keys = [(path, revision)] if revision is not None else [key for key in self.images if key[0] == path]
            for key in keys:
                image = self.images.pop(key, None)
                if image is not None:
                    image.discard()
                if self.current.get(path) == key:
                    self.current.pop(path, None)
            # Native captures have unique paths. If a path was reused, discarding
            # an older revision must not unlink another live revision's image.
            return not any(key[0] == path for key in self.images) and not any(key[0] == path for key in self.states)

    def clear(self) -> None:
        with self._lock:
            for image in self.images.values():
                image.discard()
            self.images.clear()
            self.current.clear()
            for state in self.states.values(): state.clear()
            self.states.clear()

    def evict_disposable(self) -> None:
        with self._lock:
            for image in self.images.values(): image.evict_encoding()
            for state in self.states.values(): state.evict_memoized()


@contextmanager
def screenshot_buffer_scope():
    global _pressure_images
    images = ScreenshotBuffers(_task_value('generation'))
    context = current_task.get()
    previous_owned_images = context.images if context is not None else None
    if context is not None: context.images = images
    with _pressure_lock:
        previous = _pressure_images
        _pressure_images = images
    token = _screenshot_buffers.set(images)
    try:
        with observation_index_scope(images.indexes):
            yield images
    finally:
        with _pressure_lock:
            if _pressure_images is images: _pressure_images = previous
        images.clear()
        _screenshot_buffers.reset(token)
        if context is not None: context.images = previous_owned_images


def screenshot_buffer(path: Path, revision: str | None = None) -> ScreenshotBuffer:
    images = _screenshot_buffers.get()
    return images.image(path, revision) if images is not None else ScreenshotBuffer(path)


def observation_state(observation: dict[str, Any] | None) -> RevisionedJSONState:
    images = _screenshot_buffers.get()
    if images is not None and observation is not None:
        return images.observation(observation)
    state = RevisionedJSONState()
    state.update(coverage_cache_input(observation))
    return state


def observation_image_digest(observation: dict[str, Any]) -> str | None:
    path = Path(str(observation.get("screenshot_path") or ""))
    if not path.is_file():
        return None
    return screenshot_buffer(path, observation.get("observation_revision")).digest


def discard_observation_image(observation: dict[str, Any] | None) -> None:
    if observation:
        path = Path(str(observation.get("screenshot_path") or ""))
        images = _screenshot_buffers.get()
        if images is not None and not images.discard(path, observation.get("observation_revision")):
            return
        if path.is_file():
            path.unlink(missing_ok=True)


def screen_wait_limit(action_type: str) -> float:
    if action_type in TRUSTED_NATIVE_ACTIONS or action_type == "none":
        return 0.0
    return 5.0 if action_type == "navigate_browser" else 3.0 if action_type in {"launch_app", "open_route"} else 2.0


def observation_is_loading(observation: dict[str, Any], pid: int | None) -> bool:
    return any(e.get("busy") is True or e.get("role") == "AXProgressIndicator"
               or str(e.get("title") or e.get("value") or "").strip().casefold()
               in {"loading", "loading…", "loading..."}
               for e in observation.get("elements", []) if isinstance(e, dict) and (pid is None or e.get("pid") == pid))


def screen_operation_allowance(display_id, before, action, baseline_image=None, timeout=None, **_):
    # timeout=0 requests one accepted observation without subsequent polling.
    return max(5.0, timeout or 0)


@local_operation(screen_operation_allowance, 'screen_settling')
def wait_for_screen_change(display_id: int, before: dict[str, Any], action: dict[str, Any],
                           baseline_image: str | None = None, timeout: float | None = None,
                           target_pid: int | None = None,
                           expected_effect: ExpectedEffect | None = None) -> tuple[dict[str, Any], dict[str, Any]]:
    """Observe only; never replay an action or ask a model during settling.

    Retain the final screenshot and its revision for the next decision. A stable
    screen change is evidence to inspect, not proof of task/action completion.
    """
    pid = target_pid or action.get("pid")
    if pid is None and action.get("element_id"):
        pid = next((e.get("pid") for e in before.get("elements", [])
                    if isinstance(e, dict) and e.get("id") == action["element_id"]), None)
    baseline = observation_progress_signature(before, pid)
    baseline_image = baseline_image or observation_image_digest(before)
    limit = screen_wait_limit(str(action.get("type"))) if timeout is None else timeout
    start = time.monotonic()
    budget = current_budget.get()
    budget.check('screen_settling')
    deadline = min(start + limit, budget.deadline)
    latest = None
    stable_signature = None
    stable_since = start
    changed = False
    polls = 0
    effect_result = expected_effect.unknown() if expected_effect else None
    notifications = before.get("local_change_notifications") is True
    try:
        while True:
            if budget.remaining <= 0:
                if latest is None: raise LocalBudgetExpired(budget.phase)
                reason = 'local_budget_exhausted'
                break
            remaining = deadline - time.monotonic()
            used_notification_wait = False
            if latest is not None and remaining <= 0:
                reason = "bounded_wait_elapsed"
                break
            # Reserve time for an accepted screenshot/control pair at the end
            # of the bound. Watchers never leave planning with unpaired evidence.
            if notifications and remaining > 0.5 and latest is not None:
                current_target = latest or before
                check = None
                if expected_effect and expected_effect.kind == 'field_value':
                    matches = expected_effect.unique(expected_effect.field_candidates(current_target))
                    if len(matches) == 1:
                        check = {**expected_effect.spec, 'element_id': matches[0]['id'], 'pid': matches[0]['pid']}
                elif expected_effect and expected_effect.kind == 'dialog_appeared':
                    check = expected_effect.spec
                delay = max(0.05, SCREEN_STABLE_SECONDS - (time.monotonic() - stable_since)) if latest is not None else 0.05
                params = {'observation_revision': current_target.get('observation_revision'),
                          'timeout_ms': max(1, min(500, math.floor((remaining - 0.5) * 1000))),
                          'minimum_delay_ms': min(300, math.ceil(delay * 1000))}
                if pid is not None: params['pid'] = pid
                if check:
                    params['expected_result'] = check
                    params['pid'] = check.get('pid', params.get('pid'))
                try:
                    wake = bridge_call('wait_for_change', display_id, **params)
                    used_notification_wait = True
                    record_local_wake(wake)
                    if check and wake.get('effect_ready') is False and time.monotonic() < deadline:
                        continue  # A spurious notification is not a screen change.
                except ActionRejected as error:
                    if error.code == 'stale_target': pass  # Refresh; no action is replayed.
                    elif error.code in {'invalid_action', 'action_rejected'}:
                        notifications = False  # Unsupported native watcher; bounded polling.
                    else: raise
                remaining = deadline - time.monotonic()
            # The native consistency loop shares this wait's remaining budget.
            # An unstable capture is not a provider failure or permission to use
            # an older revision (native observation authority was invalidated).
            budget.check('screen_settling')
            current = bridge_call("observe", display_id,
                                  consistency_budget_ms=max(1, min(5000, math.ceil(remaining * 1000))))
            discard_observation_image(latest)
            latest = current
            polls += 1
            semantic = observation_progress_signature(current, pid)
            image = observation_image_digest(current)
            signature = (semantic, image)
            now = time.monotonic()
            changed = semantic != baseline or (baseline_image is not None and image is not None and image != baseline_image)
            elements = [e for e in current.get("elements", []) if isinstance(e, dict)
                        and (pid is None or e.get("pid") == pid)]
            loading = observation_is_loading(current, pid)
            if loading and timeout is None:
                deadline = min(budget.deadline, max(deadline, start + 5.0))
            if signature != stable_signature or loading:
                stable_signature, stable_since = signature, now
            if expected_effect:
                effect_result = expected_effect.observe(current)
            confirmed_effect = effect_result and effect_result['outcome'] == 'verified'
            ready = confirmed_effect if expected_effect and expected_effect.supported else changed
            if ready and not loading and now - stable_since >= SCREEN_STABLE_SECONDS:
                # Describe locally observed readiness without guessing what a
                # free-form expected_result means or claiming a mutation worked.
                reason = "expected_effect_verified" if confirmed_effect else "screen_changed"
                old = [e for e in before.get("elements", []) if isinstance(e, dict)
                       and (pid is None or e.get("pid") == pid)]
                dialogs = {"AXSheet", "AXMenu", "AXDialog"}
                if not confirmed_effect and any(e.get("role") in dialogs or e.get("subrole") == "AXDialog" for e in elements) and not any(
                        e.get("role") in dialogs or e.get("subrole") == "AXDialog" for e in old):
                    reason = "dialog_opened"
                elif not confirmed_effect and any(e.get("focused") is True and e.get("enabled", True) is True
                         and e.get("role") in {"AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"}
                         for e in elements):
                    reason = "field_ready"
                break
            if now >= deadline:
                reason = "bounded_wait_elapsed"
                break
            if not used_notification_wait:
                time.sleep(min(SCREEN_POLL_SECONDS, deadline - now))
        return latest, {"reason": reason, "changed": changed, "polls": polls,
                        **({'expected_effect': effect_result} if effect_result else {}),
                        "elapsed_seconds": round(time.monotonic() - start, 3)}
    except BaseException:
        discard_observation_image(latest)
        raise


def record_local_wake(wake: dict[str, Any]) -> None:
    """Aggregate diagnostics only; notifications never enter prompts or proof."""
    for field, metric in [('notifications', 'local_notifications'), ('targeted_checks', 'local_targeted_checks')]:
        count = wake.get(field)
        if type(count) is int and 0 <= count <= 10000:
            _task_value('local_change_metrics')[metric] += count
    polls = wake.get('poll_wakeups')
    if type(polls) is int and 0 <= polls <= 10000:
        _task_value('local_change_metrics')['local_poll_wakeups'] += polls
    elif polls is None and wake.get('reason') == 'poll_timeout':
        _task_value('local_change_metrics')['local_poll_wakeups'] += 1


def command_outcome_verified(action: dict[str, Any], result: dict[str, Any]) -> bool:
    try: validate_native_result(result, action)
    except NativeProtocolError: return False
    expected = action.get("checks")
    actual = result.get("checks")
    if (result.get("verified") is not True or result.get("verification_scope") != "requested_outcomes"
            or result.get("timed_out") is not False or type(result.get("exit_code")) is not int
            or result["exit_code"] != 0 or not isinstance(expected, list) or not expected
            or not isinstance(actual, list) or len(expected) != len(actual)):
        return False
    for check, evidence in zip(expected, actual):
        if not isinstance(check, dict) or not isinstance(evidence, dict) or evidence.get("verified") is not True:
            return False
        if check.get("type") != evidence.get("type"):
            return False
        if "path" in check and os.path.normpath(os.path.expanduser(check["path"])) != evidence.get("path"):
            return False
    return True


@local_operation(5.0, 'effect_verification')
def verify_expected_effect(display_id: int, before: dict[str, Any], action: dict[str, Any],
                           result: dict[str, Any], expectation: Any, baseline_image: str | None,
                           metrics: dict[str, Any]) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    effect = ExpectedEffect(expectation, before)
    checked = effect.unknown()
    observation = None
    budget = current_budget.get()
    try:
        if effect.kind in FILE_EFFECTS:
            checked = effect.reuse_native(action, result)
            if not checked or checked['outcome'] != 'verified':
                def count(): metrics['effect_checks'] = metrics.get('effect_checks', 0) + 1
                if before.get('local_change_notifications') is True:
                    response = bridge_call('wait_file_effect', display_id, check=effect.spec, timeout_ms=max(1, min(2000, math.floor(budget.check('file_effect') * 1000))))
                    wake = response.get('local_wait', {})
                    record_local_wake(wake)
                    checks = wake.get('targeted_checks')
                    metrics['effect_checks'] = metrics.get('effect_checks', 0) + (checks if type(checks) is int and 0 <= checks <= 10000 else 1)
                    checked = effect.native_check(response)
                else:
                    checked = effect.wait_file(lambda check: bridge_call('check_effect', display_id, check=check), count=count)
        screen_limit = screen_wait_limit(str(action.get('type')))
        if budget.remaining > 0 and (screen_limit > 0 or effect.kind in {'dialog_appeared', 'field_value'}):
            observation, settling = wait_for_screen_change(display_id, before, action, baseline_image,
                target_pid=result.get('pid'), timeout=0 if effect.kind in FILE_EFFECTS else (2.0 if screen_limit == 0 else None),
                expected_effect=effect if effect.kind not in FILE_EFFECTS else None)
            result = {**result, 'settling': settling}
            if effect.kind not in FILE_EFFECTS:
                checked = settling.get('expected_effect') or checked
                if effect.supported: metrics['effect_checks'] = metrics.get('effect_checks', 0) + settling['polls']
    except (LocalBudgetExpired, ActionRejected) as error:
        if getattr(error, 'code', None) != 'local_budget_exhausted': raise
        # Expiry of inspection leaves delivery certainty untouched. No retry,
        # negative proof, or completion shortcut follows from this result.
        checked = checked or effect.unknown()
        result = {**result, 'local_budget': {'reason': 'local_budget_exhausted', 'phase': budget.phase, 'message': str(error)}}
    # A check's scope is separate from acknowledgement of event delivery.
    # Unrelated changes never turn a supported unmet expectation into success.
    if budget.remaining <= 0 and 'local_budget' not in result:
        result = {**result, 'local_budget': {'reason': 'local_budget_exhausted', 'phase': budget.phase}}
    outcome = checked['outcome']
    if effect.supported:
        result = {**result, 'delivery_outcome': result.get('outcome'),
                  'outcome': 'verified' if outcome == 'verified' else 'delivered_unconfirmed', 'verified': outcome == 'verified',
                  'verification_scope': 'expected_effect' if outcome == 'verified' else 'expected_effect_unconfirmed'}
    key = 'verified_effects' if outcome == 'verified' else 'unconfirmed_effects'
    metrics[key] = metrics.get(key, 0) + 1
    return observation, {**result, 'expected_effect': checked}


def expected_effect_presentation_scope(result: Any) -> str | None:
    """Return only the named, supported check that actually passed."""
    if not isinstance(result, dict): return None
    effect = result.get('expected_effect')
    if not isinstance(effect, dict) or effect.get('outcome') != 'verified': return None
    scope = effect.get('check')
    return scope if isinstance(scope, str) and scope in {'dialog_appeared', 'field_value', 'file_contents', 'file_exists',
                                                         'directory_exists', 'path_absent'} else None


def trusted_native_history(
    task: str,
    observation: dict[str, Any],
    history: list[dict[str, Any]],
) -> bool:
    """Compatibility helper: history alone never establishes task coverage."""
    return False


def native_action_can_finish(
    task: str,
    decision: dict[str, Any],
    action: dict[str, Any],
    result: dict[str, Any],
    observation: dict[str, Any],
) -> bool:
    """A model's finish flag is a verification candidate, not proof."""
    return False


def secure_input_target(
    observation: dict[str, Any],
    history: list[dict[str, Any]],
) -> dict[str, Any] | None:
    """Find one empty visible secure field without exposing its future value."""
    handled = {
        str(entry.get("result", {}).get("target_signature") or "")
        for entry in history
        if isinstance(entry, dict) and isinstance(entry.get("result"), dict)
        and entry.get("action") == "user_input_entered"
    }
    elements = observation.get("elements")
    if not isinstance(elements, list):
        return None
    for element in elements:
        if not isinstance(element, dict):
            continue
        role = str(element.get("role") or "")
        subrole = str(element.get("subrole") or "")
        description = " ".join(str(element.get(key) or "") for key in (
            "title", "description", "placeholder"
        )).strip()
        is_secure = "securetextfield" in f"{role} {subrole}".casefold()
        sensitive_label = any(phrase in description.casefold() for phrase in (
            "password", "passcode", "verification code", "security code", "one-time code", "otp"
        ))
        if not is_secure and not (
            role == "AXTextField" and sensitive_label
        ):
            continue
        element_id = str(element.get("id") or "")
        try:
            pid = int(element.get("pid") or 0)
        except (TypeError, ValueError):
            pid = 0
        if not element_id or pid <= 0:
            continue
        raw_value = str(element.get("value") or "").strip()
        placeholder_value = raw_value.casefold() in {
            "password", "passcode", "verification code", "security code"
        }
        if raw_value and not placeholder_value:
            continue
        signature = f"{pid}|{description.casefold() or 'secure-field'}"
        if signature in handled:
            continue
        verification = any(word in description.casefold() for word in (
            "code", "otp", "verification"
        ))
        return {
            "element_id": element_id,
            "pid": pid,
            "input_kind": "verification_code" if verification else "password",
            "title": "Verification code required" if verification else "Password required",
            "message": description or (
                f"The waiting app needs a verification code before {PRODUCT_NAME} can continue."
                if verification else
                f"The waiting app needs a password that {PRODUCT_NAME} does not have."
            ),
            "target_signature": signature,
        }
    return None


def decision_user_input_target(decision: dict[str, Any]) -> dict[str, Any]:
    request = decision.get("user_input")
    action = decision.get("action")
    if not isinstance(request, dict) or not isinstance(action, dict):
        raise RuntimeError("OpenClaw requested user input without a target field")
    element_id = str(action.get("element_id") or "")
    try:
        pid = int(action.get("pid") or 0)
    except (TypeError, ValueError):
        pid = 0
    if not element_id or pid <= 0:
        raise RuntimeError("The password request requires a visible field id and app pid")
    input_kind = str(request.get("kind") or "password")
    if input_kind not in {"password", "verification_code", "secret"}:
        input_kind = "secret"
    return {
        "element_id": element_id,
        "pid": pid,
        "input_kind": input_kind,
        "title": str(request.get("title") or "Secure input required")[:120],
        "message": str(request.get("message") or "Enter the requested secure value to continue.")[:400],
        "target_signature": str(request.get("target_signature") or f"{pid}|{element_id}"),
    }


def wait_for_user_input(request_id: str, *, key=None) -> str:
    inbox = runtime_inbox()
    owns_key = key is None
    key = key or inbox.register('user_input_response', request_id, _task_value('generation'))
    try:
        context = current_task.get()
        control_keys = []
        if context is not None:
            if context.correction_key: control_keys.append(context.correction_key)
            if context.working_document_key: control_keys.append(context.working_document_key)
        while control_keys:
            inbox.start()
            selected, line = inbox.transport.get_any([*control_keys, key])
            if selected == key:
                response = json.loads(line)
                break
            try: message = json.loads(line)
            except (TypeError, ValueError) as error:
                raise RuntimeError("TaskPilot received malformed task-control data") from error
            if selected == context.correction_key:
                context.pending_correction_message = message
                raise InstructionSuperseded("A correction arrived while secure input was waiting")
            context.pending_working_document_message = message
            update = receive_pending_task_control(timeout=0)
            handler = context.working_document_update_handler
            if handler is None:
                raise WorkingDocumentSuperseded("The working document changed while secure input was waiting")
            # Apply the target change at this safe boundary while leaving the
            # secure-input request open. This preserves Pause/secure-input
            # state and avoids asking the user or model again for the same step.
            handler(update, preserve_secure_input=True)
        else:
            response = json.loads(runtime_line(key=key))
        value = response.get("value")
        if not isinstance(value, str) or not value:
            raise RuntimeError(f"{PRODUCT_NAME} did not receive the requested secure value")
        if len(value) > 4096:
            raise RuntimeError("The secure value is unexpectedly long")
        if context is not None and response.get("instruction_revision") != context.instruction_revision:
            raise InstructionSuperseded("Secure input was submitted for superseded instructions")
        if context is not None and response.get("working_document_revision") != context.working_document_revision:
            raise WorkingDocumentSuperseded("Secure input was submitted for a superseded working document")
        return value
    finally:
        if owns_key:
            inbox.transport.unregister(key)


def request_and_enter_user_input(
    target: dict[str, Any],
    display_id: int,
) -> dict[str, Any]:
    context = current_task.get()
    if context is not None: context.machine.require("secure_input")
    request_id = str(uuid.uuid4())
    inbox = runtime_inbox()
    key = inbox.register('user_input_response', request_id, _task_value('generation'))
    try:
        if context is not None:
            publish_task_progress(context.ledger, lifecycle="waiting_for_user", active_requirement_ids=[])
        emit("user_input_required", request_id=request_id, title=target["title"],
             message=target["message"], input_kind=target["input_kind"])
        secret = wait_for_user_input(request_id, key=key)
        while instruction_correction_pending():
            control = receive_pending_task_control(timeout=0)
            if control.get("control_kind") == "working_document_update":
                handler = context.working_document_update_handler if context is not None else None
                if handler is None:
                    raise WorkingDocumentSuperseded("The working document changed before secure input delivery")
                handler(control, preserve_secure_input=True)
                continue
            if context is not None:
                context.pending_task_control = control
            raise InstructionSuperseded("A correction arrived before secure input delivery")
    finally:
        inbox.transport.unregister(key)
    try:
        delivery = bridge_call(
            "act", display_id,
            action={"type": "type_text", "element_id": target["element_id"], "pid": target["pid"], "text": secret},
            private_input=True,
        )
    finally:
        secret = ""
    return {
        "message": f"{PRODUCT_NAME} delivered private input to the intended focused field; its value was not read back.",
        "outcome": delivery.get("outcome", "delivered_unconfirmed"),
        "target_signature": target["target_signature"],
        "input_kind": target["input_kind"],
        "secret_retained": False,
    }


def has_unresolved_stop_boundary_action(history: list[dict[str, Any]], boundaries: list[dict[str, Any]]) -> bool:
    if not boundaries:
        return False
    uncertain_outcomes = {"dispatched", "delivered_unconfirmed", "unknown"}
    for entry in history:
        if not isinstance(entry, dict):
            continue
        action, result = entry.get("action"), entry.get("result")
        if not isinstance(action, dict) or not isinstance(result, dict):
            continue
        if result.get("outcome") not in uncertain_outcomes and result.get("error_code") != "delivery_uncertain":
            continue
        kind = action.get("type")
        if kind in {"click", "double_click", "press", "key", "navigate_browser", "open_route"}:
            return True
        if kind == "run_command":
            operation = action.get("operation")
            if not isinstance(operation, dict) or operation.get("type") not in {
                "create_directory", "copy_file", "move_file", "remove_file", "remove_empty_directory", "print_text"
            }:
                return True
    return False


def complete_from_decision(decision: dict[str, Any], fallback: str, ledger: TaskEvidenceLedger,
                           history: list[dict[str, Any]] | None = None) -> bool:
    message = decision["output"] if isinstance(decision.get("output"), str) else str(fallback or "Task completed")
    if not ledger.can_complete(message):
        raise RuntimeError("TaskPilot cannot complete without evidence for every requested requirement")
    context = current_task.get()
    if context is not None and context.pending_target_choice is not None:
        raise RuntimeError("TaskPilot cannot complete while a consequential target choice is unresolved")
    if context is not None and has_unresolved_stop_boundary_action(history or [], context.stop_boundaries):
        raise RuntimeError("TaskPilot cannot claim the stop-before boundary was preserved until the uncertain action is reconciled")
    if context is not None:
        gate = None
        for attempt in range(2):
            gate = bridge_call("completion_gate", context.display_id)
            if gate.get("accepted") is True:
                break
            if gate.get("needs_working_document") is True:
                publish_task_wait("reconciling", "Choose the working document again",
                                  operation_key=f"working-document-reselect:{context.working_document_revision}", ledger=ledger)
                context.pending_task_control = receive_pending_task_control(timeout=None)
                return False
            if gate.get("needs_working_selection") is True:
                publish_task_wait("reconciling", "Choose the working selection again",
                                  operation_key=f"working-selection-reselect:{context.working_document_revision}", ledger=ledger)
                context.pending_task_control = receive_pending_task_control(timeout=None)
                return False
            if gate.get("pending_working_document") is True:
                publish_task_wait("reconciling", "Applying the selected working document",
                                  operation_key=f"working-document-update:{context.working_document_revision + 1}", ledger=ledger)
                context.pending_task_control = receive_pending_task_control(timeout=None)
                return False
            if gate.get("pending_correction") is not True:
                raise RuntimeError("TaskPilot could not atomically authorize completion for this instruction revision")
            try:
                context.pending_task_control = {
                    "control_kind": "instruction_correction",
                    **receive_instruction_correction(timeout=5.0),
                }
            except TimeoutError:
                # A persistence failure can revoke the temporary dispatch
                # barrier without sending a correction. Rechecking the native
                # gate lets the still-current instructions complete safely.
                if attempt == 0:
                    continue
                raise RuntimeError("TaskPilot could not resolve a pending correction before completion")
            raise InstructionSuperseded("Completion was held because a correction is pending")
        if gate is None or gate.get("accepted") is not True:
            raise RuntimeError("TaskPilot could not atomically authorize completion for this instruction revision")
        publish_task_wait("draining", "Finishing the task safely",
                          operation_key="task-draining", ledger=ledger)
        context.machine.complete()
        publish_task_progress(ledger, lifecycle="completed", active_requirement_ids=[])
    title = str(decision.get("output_title") or "OpenClaw result").strip()
    kind = str(decision.get("output_kind") or "result")
    if kind not in {"answer", "result", "completion"}:
        kind = "result"
    emit("complete", message=message, show_output=True, title=title, content=message,
         decided_by_agent=True, output_kind=kind)
    return True


def compact_observation(observation: dict[str, Any], task: str = "") -> dict[str, Any]:
    compact = {
        key: value for key, value in observation.items()
        if key not in {"screenshot_path", "agent_cursor", "installed_applications", "elements", "text_recognition",
                       "result_destinations", "save_panel_destinations", "working_document"}
    }
    working_document = observation.get("working_document")
    if isinstance(working_document, dict):
        # The native observation carries process/window identities for local
        # validation. Only descriptive fields and the binding state belong in
        # the model-facing observation.
        compact["working_document"] = {
            key: working_document[key]
            for key in ("state", "application", "title", "location", "revision", "selection_state", "selection_description")
            if key in working_document
        }
    context = current_task.get()
    if context is not None and context.ledger is not None:
        candidates = grounded_candidates(observation, context.ledger)
        if candidates:
            compact["target_choice_candidates"] = [
                {key: candidate[key] for key in ("id", "kind", "label", "detail")}
                for candidate in candidates
            ]
    if context is not None and context.target_bindings:
        compact["selected_targets"] = [
            {
                "reference": binding.get("reference"),
                "requirement_id": binding.get("requirement_id"),
                "scope": binding.get("scope"),
                "kind": binding.get("kind"),
                "label": binding.get("label"),
                "detail": binding.get("detail"),
                "path": (binding.get("binding") or {}).get("path"),
            }
            for binding in context.target_bindings
        ]
        compact["selected_target_rule"] = (
            "Use a selected target only for its listed requirement. Preserve its exact identity. "
            "Include the matching requirement_id in each related action's requirement_ids and name the selected target in intended_target. "
            "Do not apply it to unrelated requirements or substitute a similarly named target. "
            "File operations must use the matching selected path; opaque commands cannot stand in for it."
        )
    text = prompt_text_recognition(observation)
    if text is not None: compact['text_recognition'] = text
    installed = observation.get("installed_applications")
    if isinstance(installed, list):
        compact["installed_application_count"] = len(installed)
        # App discovery needs the full name/bundle inventory, but usage dates
        # and other metadata duplicate system_context and add thousands of
        # tokens to every visible desktop step.
        compact["installed_applications"] = [
            {
                key: app[key]
                for key in ("name", "bundle_id", "platform")
                if isinstance(app, dict) and key in app
            }
            for app in installed
            if isinstance(app, dict)
        ]
    elements = observation.get("elements")
    if isinstance(elements, list):
        compact["visible_element_count"] = len(elements)
        compact["elements"] = select_elements(observation, task, MAX_COMPACT_ELEMENTS)
        compact["observation_completeness"] = prompt_coverage(observation, compact["elements"], MAX_COMPACT_ELEMENTS)
        if elements: compact["target_relationships_version"] = RELATIONSHIPS_VERSION
        if len(elements) > len(compact["elements"]):
            compact["element_selection"] = {"strategy": "active_window_task_and_labels", "partial": True}
    return compact


def action_history_context(decision: dict[str, Any], action: dict[str, Any],
                           observation: dict[str, Any]) -> dict[str, Any]:
    context = {key: decision[key] for key in ("intended_target", "expected_result") if key in decision}
    element = observation_indexes(observation).element(action.get("element_id"))
    if element:
        context["target"] = {key: element[key] for key in ("app", "window_title", "title", "role", "subrole") if key in element}
    elif action.get("app") or action.get("bundle_id"):
        context["target"] = {key: action[key] for key in ("app", "bundle_id") if key in action}
    return context


def compact_history(history: list[dict[str, Any]]) -> list[dict[str, Any]]:
    recent = history[-MAX_RECENT_ACTIONS:]
    compact: list[dict[str, Any]] = []
    for offset, entry in enumerate(recent):
        if not isinstance(entry, dict):
            continue
        allowed = {
            "step", "action", "result", "completed_requirements", "remaining_requirements",
            "target", "intended_target", "expected_result"
        }
        # Only the two newest actions retain prose evidence; the current fresh
        # screenshot and Accessibility tree are the authoritative state.
        if offset >= max(0, len(recent) - 2):
            allowed.add("visual_evidence")
        row = {key: entry[key] for key in allowed if key in entry}
        if isinstance(row.get("action"), dict) and row["action"].get("operation"):
            # Recipes reconstruct these fields locally. In particular, native
            # source snapshots belong to the proof ledger, not model context.
            row["action"] = {k: v for k, v in row["action"].items() if k not in {"argv", "checks"}}
            if isinstance(row.get("result"), dict):
                row["result"] = {k: v for k, v in row["result"].items() if k != "outcome_checks"}
        compact.append(row)
    return compact


def task_capability_context(task: str, observation: dict[str, Any]) -> dict[str, Any]:
    """Map ordinary user wording to TaskPilot's concrete capabilities.

    This is advisory rather than an executor: the model still checks the live
    screen and action results, while stable routing rules keep simple requests
    from depending on a lucky interpretation of tool names.
    """
    lowered = " ".join(task.casefold().split())
    path_signal = bool(
        re.search(r"(?:^|\s)(?:~?/|/users/|\.{0,2}/)", lowered)
        or re.search(r"\b[\w -]+\.[a-z0-9]{1,10}\b", lowered)
        or any(re.search(rf"\b{re.escape(name)}\b", lowered) for name in STANDARD_LOCATIONS)
        or re.search(r"\b(file|folder|directory|path|document|download)\b", lowered)
    )
    file_read = path_signal and bool(re.search(
        r"\b(read|show|display|inspect|summari[sz]e|what(?:'s| is) in|what does|tell me (?:what|about)|contents?|open)\b",
        lowered,
    ))
    file_write = path_signal and bool(re.search(
        r"\b(create|make|write|save|append|add to|update|edit|overwrite|put|export)\b",
        lowered,
    ))
    shell = bool(
        re.search(r"\b(shell|terminal|command line|command|zsh|bash|script)\b", lowered)
        or re.search(
            r"\brun\s+(?:`|ls\b|pwd\b|git\b|npm\b|npx\b|pnpm\b|yarn\b|python\b|python3\b|swift\b|xcodebuild\b|make\b|cargo\b|go\b|ruby\b|node\b|find\b|grep\b|rg\b|curl\b)",
            lowered,
        )
    )
    shell = shell or (path_signal and any(re.search(recipe['intent_pattern'], lowered)
                                         for recipe in CONTRACT['command_operations'].values())) or bool(
        re.search(CONTRACT['command_operations']['print_text']['intent_pattern'], lowered))
    browser = bool(
        re.search(r"https?://|\b(browser|website|web page|webpage|internet|online|url|current tab|this page)\b", lowered)
        or re.search(r"\b(search|google|look up|browse)\b.*\b(web|online|internet|google|site)\b", lowered)
    )

    installed = observation.get("installed_applications")
    installed_apps = [
        str(item.get("name") or "").strip()
        for item in installed if isinstance(item, dict)
    ] if isinstance(installed, list) else []
    explicitly_named_apps = sorted({
        name for name in installed_apps
        if len(name) >= 3 and re.search(rf"\b{re.escape(name.casefold())}\b", lowered)
    })
    common_app_names = {
        "finder", "safari", "chrome", "notes", "mail", "calendar", "reminders",
        "contacts", "photos", "maps", "music", "calculator", "dictionary",
        "preview", "textedit", "messages", "slack", "teams", "zoom",
    }
    mentioned_common_apps = {
        name.title() for name in common_app_names
        if re.search(rf"\b{re.escape(name)}\b", lowered)
    }
    explicitly_named_apps = sorted(set(explicitly_named_apps) | mentioned_common_apps)

    applications = observation.get("applications")
    visible_apps = [
        str(item.get("name") or item.get("app") or "").strip()
        for item in applications if isinstance(item, dict)
    ] if isinstance(applications, list) else []
    visible_apps = [name for name in visible_apps if name]

    capabilities: list[str] = []
    if file_read:
        capabilities.append("file_read")
    if file_write:
        capabilities.append("file_write")
    if shell:
        capabilities.append("shell")
    if browser:
        capabilities.append("browser")
    if explicitly_named_apps or (browser and len(explicitly_named_apps) > 1):
        capabilities.append("app_automation")
    if not capabilities:
        capabilities.append("app_automation")

    mentioned_locations = {
        name: path for name, path in STANDARD_LOCATIONS.items()
        if re.search(rf"\b{re.escape(name)}\b", lowered)
    }
    examples = [json.dumps(action_example(kind), separators=(',', ':'))
                for kind, capability in ACTION_CAPABILITIES.items()
                if capability in capabilities and capability != "app_automation"]
    if "app_automation" in capabilities and len(explicitly_named_apps) >= 2:
        examples.append(
            "Example: 'Copy the total from Safari into Notes' -> read the visible Safari value, "
            "launch/focus Notes, enter that exact value, and verify Notes on a fresh screen."
        )

    return {
        "recommended_capabilities": capabilities,
        "home_directory": str(Path.home()),
        "mentioned_standard_locations": mentioned_locations,
        "explicitly_named_apps": explicitly_named_apps,
        "currently_visible_apps": visible_apps[:20],
        "context_rules": [
            "Resolve Desktop, Documents, and Downloads to the standard paths shown here; do not ask for an absolute path when the user already named one of them.",
            "Use read_file/write_file for direct file contents. Use run_command for an explicitly requested command or filesystem operation not covered by the file tools.",
            "Use navigate_browser for a URL or web search, then inspect and control the rendered page with Accessibility actions.",
            "For multi-app work, carry exact values forward in validated action history and verify the destination app before finishing.",
            "Words like 'this page', 'current tab', 'selected file', or 'that value' refer to the live observation and recent validated results; inspect them instead of guessing.",
            "If a filename is omitted but one visible/mentioned candidate clearly fits, inspect it. If multiple candidates fit, search or list them before choosing.",
        ],
        "relevant_examples": examples,
    }


def image_mime_type(path: Path) -> str:
    return "image/png" if path.suffix.lower() == ".png" else "image/jpeg"


def is_largest_downloads_file_task(task: str) -> bool:
    """Only a complete, supported request can take the native shortcut."""
    return re.fullmatch(LARGEST_PATTERN, task, re.I) is not None


def largest_top_level_file(directory: Path) -> dict[str, Any]:
    """Return an exact, non-recursive largest-file result for a user-named folder."""
    try:
        entries = list(os.scandir(directory))
    except OSError as error:
        raise RuntimeError(
            f"{PRODUCT_NAME} could not read {directory.name}. Check its macOS Files and Folders permission."
        ) from error
    largest: dict[str, Any] | None = None
    for entry in entries:
        try:
            if not entry.is_file(follow_symlinks=False):
                continue
            size = entry.stat(follow_symlinks=False).st_size
        except OSError:
            continue
        if largest is None or (size, entry.name.casefold()) > (
            int(largest["bytes"]), str(largest["name"]).casefold()
        ):
            largest = {"name": entry.name, "bytes": size}
    if largest is None:
        raise RuntimeError(f"No top-level files were found in {directory.name}.")
    return largest


def formatted_file_size(byte_count: int) -> str:
    units = ((1_000_000_000_000, "TB"), (1_000_000_000, "GB"),
             (1_000_000, "MB"), (1_000, "KB"))
    for threshold, suffix in units:
        if byte_count >= threshold:
            return f"{byte_count / threshold:.2f} {suffix}"
    return f"{byte_count} bytes"


def largest_downloads_guidance(task: str) -> str:
    if not is_largest_downloads_file_task(task):
        return ""
    return (
        "SPECIAL FINDER ACCURACY RULE: Answer this Downloads largest-file question only from a Finder "
        "window titled Downloads in list view. The Size column must visibly be sorted descending: a down "
        "sort arrow must be inside the Size column, not Date Added, Name, or another column. Clicking Size "
        "is not proof that sorting changed; inspect the next fresh observation. If the arrow is under another "
        "column or Size is ascending, click Size again. If a Size-header click does not move the arrow, use "
        "Finder's View > Sort By > Size menu, then recheck the arrow. If Downloads is not open yet, navigate "
        "there with Finder's visible sidebar (or launch Finder first); that is an act step, not a blocker. Skip "
        "Folder rows whose size is '--'. Only choose done "
        "when the first visible non-folder row after that proven descending sort shows both its filename and size."
    )


def _element_text(element: dict[str, Any]) -> str:
    for key in ("value", "title"):
        value = element.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def _frame_number(element: dict[str, Any], key: str) -> float | None:
    frame = element.get("frame")
    if not isinstance(frame, dict):
        return None
    value = frame.get(key)
    return float(value) if isinstance(value, (int, float)) else None


def _downloads_window_elements(observation: dict[str, Any]) -> list[dict[str, Any]]:
    elements = observation.get("elements")
    if not isinstance(elements, list):
        return []
    candidates = [element for element in elements if isinstance(element, dict)]
    for index, element in enumerate(candidates):
        if element.get("role") != "AXWindow" or _element_text(element).casefold() != "downloads":
            continue
        window_depth = element.get("depth")
        if not isinstance(window_depth, int):
            window_depth = 1
        end = len(candidates)
        for next_index in range(index + 1, len(candidates)):
            next_element = candidates[next_index]
            next_depth = next_element.get("depth")
            if next_element.get("role") == "AXWindow" and isinstance(next_depth, int) and next_depth <= window_depth:
                end = next_index
                break
        return candidates[index:end]
    return []


def _finder_size_sort_direction(elements: list[dict[str, Any]]) -> str:
    """Return descending/ascending/other from Finder's visible column geometry."""
    headers: dict[str, dict[str, Any]] = {}
    for element in elements:
        text = _element_text(element).casefold()
        if text in {"name", "size", "kind", "date added", "date modified"}:
            headers.setdefault(text, element)
    size_header = headers.get("size")
    if size_header is None:
        return "unavailable"

    explicit_direction = str(size_header.get("sort_direction") or "").casefold()
    if "descending" in explicit_direction:
        return "descending"
    if "ascending" in explicit_direction:
        return "ascending"

    size_x = _frame_number(size_header, "x")
    if size_x is None:
        return "unavailable"
    right_edges = [
        x for name, header in headers.items()
        if name != "size" and (x := _frame_number(header, "x")) is not None and x > size_x
    ]
    size_right = min(right_edges) if right_edges else size_x + 160
    size_y = _frame_number(size_header, "y")
    for element in elements:
        if element.get("role") != "AXImage":
            continue
        title = _element_text(element).casefold()
        if title not in {"go down", "go up", "descending", "ascending"}:
            continue
        indicator_x = _frame_number(element, "x")
        indicator_y = _frame_number(element, "y")
        if indicator_x is None or not size_x <= indicator_x < size_right:
            continue
        if size_y is not None and indicator_y is not None and abs(indicator_y - size_y) > 24:
            continue
        return "descending" if title in {"go down", "descending"} else "ascending"
    return "other"


_VISIBLE_FILE_SIZE = re.compile(r"^\s*[\d,.]+\s*(?:bytes?|[kmgt]b)\s*$", re.IGNORECASE)


def visible_largest_downloads_file(observation: dict[str, Any]) -> dict[str, str] | None:
    """Extract a largest file only after Finder visibly proves descending Size order."""
    elements = _downloads_window_elements(observation)
    if not elements or _finder_size_sort_direction(elements) != "descending":
        return None

    for index, element in enumerate(elements):
        if element.get("role") != "AXRow":
            continue
        row_depth = element.get("depth")
        if not isinstance(row_depth, int):
            continue
        end = len(elements)
        for next_index in range(index + 1, len(elements)):
            next_element = elements[next_index]
            next_depth = next_element.get("depth")
            if next_element.get("role") == "AXRow" and isinstance(next_depth, int) and next_depth <= row_depth:
                end = next_index
                break
        children = elements[index + 1:end]
        filename = next(
            (
                _element_text(child) for child in children
                if child.get("role") == "AXTextField" and _element_text(child)
            ),
            "",
        )
        values = [_element_text(child) for child in children if child.get("role") == "AXStaticText"]
        if not filename or any(value.casefold() == "folder" for value in values):
            continue
        size = next((value for value in values if _VISIBLE_FILE_SIZE.fullmatch(value)), "")
        if size:
            return {"name": filename, "size": size}
    return None


def largest_downloads_next_action(
    observation: dict[str, Any],
    history: list[dict[str, Any]],
) -> dict[str, Any] | None:
    """Return the next visible Finder action for the accuracy-critical workflow."""
    window_elements = _downloads_window_elements(observation)
    if not window_elements:
        elements = observation.get("elements")
        if not isinstance(elements, list):
            return None
        for element in elements:
            if not isinstance(element, dict) or element.get("app") != "Finder":
                continue
            if _element_text(element).casefold() != "downloads" or not element.get("id"):
                continue
            return {"type": "press", "element_id": str(element["id"])}
        return None

    sort_state = _finder_size_sort_direction(window_elements)
    if sort_state == "descending":
        return None
    size_header = next(
        (
            element for element in window_elements
            if _element_text(element).casefold() == "size" and element.get("id")
        ),
        None,
    )
    if size_header is None:
        return None
    if sort_state == "ascending":
        return {"type": "press", "element_id": str(size_header["id"])}

    prior_sort_attempts = sum(
        1 for entry in history
        if isinstance(entry, dict) and entry.get("accuracy_action") == "sort_downloads_by_size"
    )
    if prior_sort_attempts >= 1:
        pid = size_header.get("pid")
        if isinstance(pid, int) and pid > 0:
            # Finder's built-in Sort by Size shortcut avoids repeatedly
            # clicking a text-only column header that rejected AXPress.
            return {
                "type": "key",
                "key": "6",
                "modifiers": ["control", "command"],
                "pid": pid,
            }
    return {"type": "press", "element_id": str(size_header["id"])}


def refresh_managed_descriptor(state=None):
    path = Path(os.environ['TASKPILOT_MANAGED_DESCRIPTOR'])
    descriptor = managed_openclaw.activate_environment(path)
    context = current_task.get()
    state = state or (context.runtime_state if context else None)
    if state is not None:
        state.rebind_managed('OpenClaw ' + descriptor['openclaw_version'], model_configuration_fingerprint())
    return descriptor


def managed_acp_arguments():
    path = os.environ.get("TASKPILOT_MANAGED_DESCRIPTOR")
    if not path: return []
    descriptor = managed_openclaw.load_descriptor(Path(path))
    return ["--url", descriptor['endpoint'], "--token-file", descriptor['token_file']]


class ACPClient:
    def __init__(self, openclaw_path: str) -> None:
        connection_started = time.monotonic()
        initial_cause = None
        with configuration_transaction():
            descriptor_path = os.environ.get('TASKPILOT_MANAGED_DESCRIPTOR')
            if not descriptor_path:
                self._initialize(openclaw_path)
                return
            # Sequential only: _initialize drains a failed child before this
            # alternative is launched. Both use the current private descriptor.
            descriptor = managed_openclaw.activate_environment(Path(descriptor_path))
            try:
                self._initialize(descriptor['executable'])
                self.connection_method = 'wrapper'
            except Exception as error:
                cause = initial_cause = managed_openclaw.handshake_cause(error)
                if cause in {'authentication', 'incompatible'} or isinstance(error, ProviderRequestError): raise
                descriptor = managed_openclaw.activate_environment(Path(descriptor_path))
                try:
                    launch = managed_openclaw.direct_command(descriptor)
                    self._initialize(descriptor['executable'], launch=launch)
                except Exception as direct_error:
                    cause = managed_openclaw.handshake_cause(direct_error)
                    if cause in {'authentication', 'incompatible'} or isinstance(direct_error, ProviderRequestError): raise
                    raise managed_openclaw.ACPConnectionError(cause) from direct_error
                self.connection_method = 'direct_node'
            # Fixed codes/counts only; never keep a protocol response or prompt.
            try:
                managed_openclaw.atomic_json(Path(descriptor_path).parent / 'connection.json',
                    {'version':1, 'method':self.connection_method, 'checked_at':time.time(),
                     'elapsed_ms':round((time.monotonic()-connection_started)*1000), 'initial_cause':initial_cause})
            except OSError: pass  # A diagnostic write cannot break a connected client.

    def _initialize(self, openclaw_path: str, *, launch=None) -> None:
        environment = dict(os.environ)
        environment["OPENCLAW_HIDE_BANNER"] = "1"
        environment["OPENCLAW_SUPPRESS_NOTES"] = "1"
        # Disable silence-based retries: wait for the called model to finish.
        environment["OPENCLAW_GOOGLE_GEMINI_FIRST_RESPONSE_RETRY_MS"] = "0"
        self.process = subprocess.Popen(
            (launch or [openclaw_path]) + ["acp", "--no-prefix-cwd"] + managed_acp_arguments(),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=environment,
        )
        _set_task_value("active_acp_process", self.process)
        self.transport = ACPTransport()
        self.stderr_tail: deque[str] = deque(maxlen=12)
        self.next_request_id = 1
        self.accepting_prompt_updates = False
        self.pending_prompt_session_id = None
        self.agent_chunks: list[str] = []
        self.turn_errors: list[Any] = []
        self.openclaw_path = openclaw_path
        self.selected_model: str | None = None
        self._session_ids: set[str] = set()
        self.stdout_finished = threading.Event()
        self._send_lock = threading.Lock()
        threading.Thread(target=self._read_stdout, args=(self.process, self.transport, self.stdout_finished), daemon=True).start()
        threading.Thread(target=self._read_stderr, args=(self.process, self.stderr_tail), daemon=True).start()
        try:
            initialized = self.request(
                "initialize",
                {
                    "protocolVersion": 1,
                    "clientCapabilities": {
                        "fs": {"readTextFile": False, "writeTextFile": False},
                        "terminal": False,
                    },
                    "clientInfo": {"name": PRODUCT_NAME, "version": "2.0"},
                },
                timeout=30,
            )
            protocol_version = initialized.get("protocolVersion")
            if protocol_version not in (1, "1"):
                raise RuntimeError(f"OpenClaw negotiated an unsupported ACP version: {protocol_version}")
            self._new_session()
            self.prompt_calls = 0
            self.successful_provider_retries: int | None = None
            self.model_switches = 0
            self.reconnects = 0
            self.openclaw_path = openclaw_path
        except Exception:
            self.close()
            raise


    def _new_session(self, *, session_key: str | None = None) -> None:
        # A new gateway key isolates inference history. Reattaching a saved
        # planning key after reconnect restores routing without a generation.
        if self.accepting_prompt_updates:
            raise RuntimeError("Cannot change ACP sessions while a response is pending")
        self.session_id = None
        self.session_key = session_key or f"agent:main:taskpilot:{uuid.uuid4()}"
        self.agent_chunks = []
        self.turn_errors = []
        self.pending_prompt_request_id = None
        session = self.request("session/new", {
            "cwd": str(Path.home()), "mcpServers": [],
            "_meta": {"sessionKey": self.session_key},
        }, timeout=30)
        session_id = session.get("sessionId")
        if not isinstance(session_id, str) or not session_id or session_id in self._session_ids:
            raise RuntimeError(f"OpenClaw ACP did not create a fresh {PRODUCT_NAME} session")
        self._session_ids.add(session_id)
        self.session_id = session_id
        self._session_model = None
        self.config_options = session.get("configOptions") or []
        thought = next((o for o in self.config_options if o.get("category") == "thought_level" or o.get("id") == "thought_level"), None)
        if thought and any(o.get("value") == "off" for o in thought.get("options", [])):
            result = self.request("session/set_config_option", {
                "sessionId": self.session_id, "configId": thought["id"], "value": "off",
            }, timeout=30)
            options = result.get("configOptions") or []
            if not any(o.get("id") == thought["id"] and o.get("currentValue") == "off" for o in options):
                raise RuntimeError("OpenClaw did not acknowledge the thinking setting")
            self.config_options = options

    @contextmanager
    def verification_session(self):
        """One fresh context per verification decision, including its repair.

        The planner is idle and keeps its gateway history. Logical model/call
        counters belong to the task, while acknowledged settings are per session.
        """
        if self.accepting_prompt_updates:
            raise RuntimeError("Cannot verify while a planning response is pending")
        planning = (self.session_id, self.session_key, self.config_options, self._session_model)
        process = self.process
        finished = False
        try:
            self._new_session()
            yield
            finished = True
        finally:
            self.accepting_prompt_updates = False
            self.agent_chunks = []
            self.turn_errors = []
            self.pending_prompt_request_id = None
            if self.process is process:
                self.session_id, self.session_key, self.config_options, self._session_model = planning
            elif finished:
                # Reconnect replaces the ACP session store, not gateway history.
                # Only successful terminal verification may resume the planner;
                # cancellation/failure must not start further configuration work.
                self._new_session(session_key=planning[1])

    def _read_stdout(self, process, transport, finished) -> None:
        def receive(frame):
            try:
                message = json.loads(frame)
                if not isinstance(message, dict): raise ValueError()
            except (ValueError, RecursionError):
                transport.fail(TransportFailure('transport_malformed_frame'))
                return
            transport.route(message, len(frame))
        try:
            assert process.stdout is not None
            read_frames(process.stdout, receive, transport.fail)
        finally:
            transport.close()
            finished.set()

    def _read_stderr(self, process, tail) -> None:
        assert process.stderr is not None
        def receive(frame):
            cleaned = frame.decode('utf-8', errors='replace').strip()
            if cleaned:
                tail.append(cleaned)
        # Diagnostics have a separate tiny frame budget; oversized diagnostics
        # cannot starve stdout or allocate an unbounded tail/unfinished line.
        read_frames(process.stderr, receive, lambda _: None, frame_limit=4096)

    def _send(self, message: dict[str, Any]) -> None:
        if self.process.poll() is not None:
            detail = self.stderr_tail[-1] if self.stderr_tail else "Process ended"
            raise RuntimeError(f"OpenClaw ACP stopped: {detail}")
        assert self.process.stdin is not None
        with self._send_lock:
            write_frame(self.process.stdin, message,
                        timeout=0.1 if message.get('method') == 'session/cancel' else 5.0)

    def _handle_server_message(self, message: dict[str, Any]) -> None:
        method = message.get("method")
        if method == "session/update":
            params = message.get("params") or {}
            if not isinstance(params.get("sessionId"), str) or params["sessionId"] != getattr(self, "session_id", None):
                return
            request_id = params.get("requestId")
            if request_id is not None and request_id != getattr(self, "pending_prompt_request_id", request_id):
                return
            update = params.get("update") or {}
            update_kind = update.get("sessionUpdate")
            if update_kind in {"agent_message_chunk", "agent_message", "message", "error", "session_error", "agent_error"} and not getattr(self, "accepting_prompt_updates", True):
                return
            content = update.get("content") or {}
            if update_kind in {"agent_message_chunk", "agent_message", "message"}:
                if not isinstance(content, (dict, list)):
                    raise TransportFailure('transport_malformed_envelope')
                contents = content if isinstance(content, list) else [content]
                for part in contents:
                    if isinstance(part, dict):
                        text = part.get("text")
                        if isinstance(text, str):
                            self.response_bytes = getattr(self, 'response_bytes', 0) + len(text.encode('utf-8'))
                            self.response_events = getattr(self, 'response_events', 0) + 1
                            if self.response_bytes > FRAME_BYTES or self.response_events > 65536:
                                raise TransportFailure('transport_response_limit')
                            if update_kind == "agent_message_chunk":
                                self.agent_chunks.append(text)
                            else:
                                self.agent_chunks = [text]
            elif update_kind in {"error", "session_error", "agent_error"}:
                if update.get("message") or update.get("error") or update.get("code"):
                    self.response_bytes = getattr(self, 'response_bytes', 0) + len(json.dumps(update).encode())
                    if len(self.turn_errors) >= 128 or self.response_bytes > FRAME_BYTES:
                        raise TransportFailure('transport_response_limit')
                    self.turn_errors.append(update)
            elif update_kind == "tool_call":
                title = update.get("title") or "OpenClaw tool"
                emit("status", message=f"OpenClaw is checking {title}…")
            return

        if "id" in message and isinstance(method, str):
            # TaskPilot does not grant OpenClaw a hidden mutation path. The only
            # action route is the visible, validated JSON decision below.
            if method == "session/request_permission":
                self._send({
                    "jsonrpc": "2.0",
                    "id": message["id"],
                    "result": {"outcome": {"outcome": "cancelled"}},
                })
            else:
                self._send({
                    "jsonrpc": "2.0",
                    "id": message["id"],
                    "error": {"code": -32601, "message": f"{PRODUCT_NAME} does not expose that client method"},
                })

    def request(self, method: str, params: dict[str, Any], timeout: float | None) -> dict[str, Any]:
        request_id = self.next_request_id
        self.next_request_id += 1
        if method == "session/prompt":
            self.pending_prompt_request_id = request_id
            self.pending_prompt_session_id = params["sessionId"]
        transport = self.transport  # Reconnect cannot redirect an old waiter.
        transport.register(request_id, method=method, session=params.get('sessionId'))
        try:
            self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            deadline = None if timeout is None else time.monotonic() + timeout
            while True:
                remaining = None if deadline is None else max(0, deadline - time.monotonic())
                try:
                    message = transport.get(request_id, remaining)
                except TimeoutError as error:
                    raise TransportFailure('transport_request_timeout') from error
                if message.get("id") == request_id and ("result" in message or "error" in message) and 'method' not in message:
                    if method == "session/prompt":
                        self.pending_prompt_session_id = None
                    if "error" in message:
                        raise ProviderRequestError(message.get("error") or {}, getattr(self, "selected_model", None), "OpenClaw ACP request failed")
                    result = message.get("result")
                    return result if isinstance(result, dict) else {}
                self._handle_server_message(message)
        except TransportFailure:
            # A lost stream cannot be interpreted as complete output. Stop the
            # originating child; existing reconnect must also acknowledge the
            # Gateway abort before any inference can be retried.
            self.close()
            raise
        finally:
            transport.unregister(request_id)

    def _run_prompt(self, prompt: list[dict[str, Any]], timeout: float | None) -> tuple[dict[str, Any], str]:
        # ACP notifications carry session identity; request responses carry the
        # JSON-RPC request id. Unregistered/retired updates are discarded by
        # the reader, never buffered for a later decision.
        self.accepting_prompt_updates = False
        self.agent_chunks = []
        self.turn_errors = []
        self.response_bytes = 0
        self.response_events = 0
        self.accepting_prompt_updates = True
        started_at = time.time() * 1000
        cursor = session_transcript_cursor(self.session_id)
        try:
            result = self.request(
                "session/prompt",
                {
                    "sessionId": self.session_id,
                    "prompt": prompt,
                },
                timeout=timeout,
            )
        finally:
            self.accepting_prompt_updates = False
        stop_reason = str(result.get("stopReason") or "")
        selected = getattr(self, "selected_model", None)
        if stop_reason in {"cancelled", "error"}:
            if stop_reason == "cancelled":
                raise RuntimeError(f"OpenClaw cancelled the {PRODUCT_NAME} turn")
            detail = result if any(result.get(k) for k in ("error", "code", "data", "errorMessage", "errorDetails")) else self.turn_errors[-1] if self.turn_errors else openclaw_session_error(
                self.session_id, after_cursor=cursor, structured=True, started_at=started_at)
            if detail:
                raise ProviderRequestError(detail, selected)
            raise RuntimeError(
                "OpenClaw could not complete the Gemini request. Open Settings and click Reconfigure Gemini."
            )
        response = "".join(self.agent_chunks).strip()
        if not response and hasattr(self, "session_key"):
            recovered = self.gateway_configuration("sessions.get", {"key": self.session_key, "limit": 8})
            for item in reversed(recovered.get("messages") or []):
                message = item.get("message", item) if isinstance(item, dict) else {}
                if not current_transcript_message(message, item, started_at):
                    continue
                if message.get("role") == "custom" and message.get("customType") == "run-failed-before-reply":
                    detail = message.get("details")
                    if not isinstance(detail, dict) or not detail.get("error"):
                        raise ProviderRequestError({"code":"configuration", "message":"OpenClaw failed before returning a provider response"}, selected)
                    raise ProviderRequestError(detail["error"], selected)
                if message.get("role") != "assistant": continue
                if message.get("stopReason") == "error":
                    raise ProviderRequestError(message, selected, "OpenClaw recovery exhausted")
                content = message.get("content") or []
                if isinstance(content, list):
                    response = "".join(str(part.get("text") or "") for part in content if isinstance(part, dict)).strip()
                break
        if not response:
            response = str(result.get("message") or result.get("text") or "").strip()
        if not response:
            detail = self.turn_errors[-1] if self.turn_errors else openclaw_session_error(
                self.session_id, after_cursor=cursor, structured=True, started_at=started_at)
            if detail:
                raise ProviderRequestError(detail, selected)
        elif self.turn_errors:
            # A complete response can follow successful internal recovery. Partial
            # output plus an explicit provider error must not trigger format repair.
            try: extract_json_object(response)
            except ResponseValidationError:
                raise ProviderRequestError(self.turn_errors[-1], selected)
        return result, response

    def select_model(self, model: str) -> None:
        if model == getattr(self, "_session_model", self.selected_model):
            return
        option = next((o for o in self.config_options if o.get("category") == "model" or "model" in str(o.get("id", "")).lower()), None)
        if option is None:
            # OpenClaw 2026.9.5 bridge mode advertises thinking controls but no
            # model control. Use the acknowledged session configuration RPC
            # backing ACP controls; never send a prompt-based slash command.
            result = self.gateway_configuration("sessions.patch", {"key": self.session_key, "model": model})
            resolved = result.get("resolved") or {}
            accepted = f"{resolved.get('modelProvider', '')}/{resolved.get('model', '')}"
            if result.get("ok") is not True or accepted != model:
                raise RuntimeError(f"OpenClaw could not select {model}: session configuration was not acknowledged")
            self.model_switches += model != self.selected_model
            self.selected_model = self._session_model = model
            return
        result = self.request("session/set_config_option", {
            "sessionId": self.session_id, "configId": option["id"], "value": model,
        }, timeout=30)
        options = result.get("configOptions") or []
        acknowledged = next((o for o in options if o.get("id") == option["id"]), None)
        if acknowledged is None or acknowledged.get("currentValue") != model:
            raise RuntimeError(f"OpenClaw could not select {model}: model control was not acknowledged")
        self.config_options = options
        self.model_switches += model != self.selected_model
        self.selected_model = self._session_model = model

    def gateway_configuration(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        prefix = [self.openclaw_path]
        arguments = ["gateway", "call", method, "--params", json.dumps(params), "--json"]
        descriptor_path = os.environ.get('TASKPILOT_MANAGED_DESCRIPTOR')
        if descriptor_path:
            descriptor = managed_openclaw.activate_environment(Path(descriptor_path))
            self.openclaw_path = descriptor['executable']
            prefix = managed_openclaw.direct_command(descriptor) if getattr(self,'connection_method',None) == 'direct_node' else [descriptor['executable']]
            arguments += ['--expect-url', descriptor['endpoint']]
        status, output = managed_openclaw.bounded_run(prefix + arguments, env=dict(os.environ), timeout=30, result=True)
        if status:
            raise ProviderRequestError(output.strip(), getattr(self, "selected_model", None), "OpenClaw session configuration failed")
        try:
            value = json.loads(output)
            if response_error(value):
                raise ProviderRequestError(value, getattr(self, "selected_model", None))
            return value
        except ValueError as error:
            raise RuntimeError("OpenClaw returned invalid session configuration") from error

    def reconnect(self) -> None:
        now = time.monotonic()
        reconnect_times = [t for t in getattr(self, 'reconnect_times', []) if now - t < 600]
        if len(reconnect_times) >= 3:
            raise RuntimeError("OpenClaw reasoning reconnect budget exhausted; three reconnects were attempted in ten minutes.")
        reconnect_times.append(now)  # Failed attempts spend the same allowance.
        self.reconnect_times = reconnect_times
        reconnect_count = self.reconnects + 1
        self.reconnects = reconnect_count
        readiness_state = getattr(self, 'readiness_state', None)
        prompt_calls, switches = self.prompt_calls, self.model_switches
        selected = getattr(self, "selected_model", None)
        provider_retries = getattr(self, "successful_provider_retries", None)
        path = self.openclaw_path
        session_key = self.session_key
        self.close()  # First stop and wait for the disconnected ACP child.
        descriptor_path = os.environ.get("TASKPILOT_MANAGED_DESCRIPTOR")
        if descriptor_path:
            context = current_task.get()
            prior = context.machine.phase if context else None
            if context: context.machine.transition(Phase.RECOVERING)
            try:
                managed_openclaw.wait_for_health(Path(descriptor_path), force=True, status=lambda text: emit("status", message=text))
                refreshed = refresh_managed_descriptor(readiness_state)
                path = self.openclaw_path = refreshed['executable']
            except BaseException:
                # Keep execution suspended if recovery did not establish health.
                raise
            else:
                if context: context.machine.transition(prior, recovered=True)

        # The Gateway owns inference independently of the stdio child. Its
        # abort RPC waits for terminal persistence before acknowledging.
        ended = self.gateway_configuration("sessions.abort", {"key": session_key})
        if ended.get("ok") is not True or ended.get("status") not in {"aborted", "no-active-run"}:
            raise RuntimeError("TaskPilot could not confirm the previous OpenClaw request ended. Repair the Gateway before retrying.")
        try:
            self.__init__(path)
        finally:
            self.reconnects = reconnect_count
            self.reconnect_times = reconnect_times
        self.readiness_state = readiness_state
        self.prompt_calls = prompt_calls
        self.model_switches = switches
        self.selected_model = selected
        self.successful_provider_retries = provider_retries

    def prompt(self, instruction: str, screenshot_path: Path, *, detail_images: list[dict] | None = None) -> str:
        self.prompt_calls = getattr(self, "prompt_calls", 0) + 1
        image_data = screenshot_buffer(screenshot_path).base64
        mime_type = image_mime_type(screenshot_path)
        content = [
                {"type": "text", "text": instruction},
                {"type": "image", "data": image_data, "mimeType": mime_type},
            ]
        for index, crop in enumerate(detail_images or []):
            # Crops are already bounded/validated, from the accepted screenshot.
            # Standard ACP image blocks, in this same request and format repair.
            content.extend([{'type': 'text', 'text': f'Detail crop {index + 1}; use its image_to_global mapping in the observation.'},
                            {'type': 'image', 'data': crop['data'], 'mimeType': 'image/png'}])
        result, response = self._run_prompt(
            content,
            timeout=PROMPT_TIMEOUT_SECONDS,
        )
        # _run_prompt has reached a terminal result and already surfaced any
        # provider error. Empty terminal output belongs to format recovery.
        retries = provider_error_facts(result).get("provider_retries")
        self.last_prompt_provider_retries = retries
        if retries is not None:
            self.successful_provider_retries = (getattr(self, "successful_provider_retries", None) or 0) + retries
        return response

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self._send({
                    "jsonrpc": "2.0",
                    "method": "session/cancel",
                    "params": {"sessionId": getattr(self, "pending_prompt_session_id", None) or getattr(self, "session_id", "")},
                })
            except Exception:
                pass
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                stream.close()
        if _task_value("active_acp_process") is self.process:
            _set_task_value("active_acp_process", None)


def prompt_capability_context(context: dict[str, Any]) -> dict[str, Any]:
    # Rules and examples belong in one prompt section, not duplicated here.
    return {key: value for key, value in context.items()
            if key not in {"context_rules", "relevant_examples"} and value not in ([], {})}


def prompt_observation(observation: dict[str, Any], task: str = "") -> dict[str, Any]:
    compact = compact_observation(observation, task)
    compact.pop("agent_tools", None)
    compact.pop("local_change_notifications", None)
    compact.pop("command_capability_version", None)
    compact.pop("save_panel_destinations", None)
    return compact


def command_capability_summary(result: dict[str, Any]) -> dict[str, Any]:
    """Bounded, untrusted help data; never a binding, environment or proof."""
    tools = []
    for tool in result.get('tools', [])[:12]:
        if not isinstance(tool, dict): continue
        row = {key: str(tool[key])[:1800] for key in ('name', 'executable', 'context', 'option_status', 'reason', 'help_excerpt') if key in tool}
        for key in ('supported_long_options', 'supported_short_options', 'unadvertised_options'):
            if isinstance(tool.get(key), list): row[key] = [value[:100] for value in tool[key][:256] if isinstance(value, str)]
        for key in ('help_truncated', 'complete_option_list'):
            if type(tool.get(key)) is bool: row[key] = tool[key]
        tools.append(row)
    return {'tools': tools, 'resolution_complete': result.get('resolution_complete') is True,
            'limitations': [text[:400] for text in result.get('limitations', [])[:4] if isinstance(text, str)]}


def remember_command_capability(key: str, value: dict[str, Any]) -> None:
    capabilities = _task_value('command_capabilities')
    if len(capabilities) >= 8 and key not in capabilities:
        capabilities.pop(next(iter(capabilities)))
    capabilities[key] = value


def inspect_general_command(action: dict[str, Any], display_id: int, observation: dict[str, Any]) -> dict[str, Any]:
    if action.get('type') != 'run_command' or 'operation' in action: return {}
    # Older offline fixtures have no native inspection capability. Bundled
    # task processes must agree on this version before planning begins.
    version = observation.get('command_capability_version')
    if version is None: return {}
    if type(version) is not int or version != COMMAND_CAPABILITY_VERSION:
        raise RuntimeError('TaskPilot command inspection versions do not match; rebuild the bundled components together')
    result = bridge_call('inspect_command', display_id, action=action)
    if (type(result.get('ready')) is not bool or type(result.get('capability_version')) is not int or
            result['capability_version'] != COMMAND_CAPABILITY_VERSION or not isinstance(result.get('tools', []), list)):
        raise RuntimeError('TaskPilot returned incompatible command inspection data; no command was executed')
    _task_value('command_capability_metrics')['command_inspections'] += 1
    for field, metric in [('probes', 'command_probes'), ('cache_hits', 'command_probe_cache_hits')]:
        count = result.get(field, 0)
        if type(count) is int and 0 <= count <= 64: _task_value('command_capability_metrics')[metric] += count
    if result.get('cache_hit') is True: _task_value('command_capability_metrics')['command_probe_cache_hits'] += 1
    summary = command_capability_summary(result)
    for tool in summary['tools']:
        key = tool.get('executable', '') + ':' + tool.get('context', '')
        remember_command_capability(key, tool)
    if not summary['resolution_complete'] and summary['limitations']:
        remember_command_capability('shell:limits', {'name': '/bin/zsh', 'option_status': 'partial',
                                                    'reason': ' '.join(summary['limitations'])})
    if result['ready'] is not True:
        _task_value('command_capability_metrics')['command_preflight_rejections'] += 1
        raise ActionRejected(str(result.get('message') or 'Inspect the command capabilities before execution'),
            str(result.get('error_code') or 'command_options_unverified'), {'command_capabilities': summary})
    identifier = result.get('inspection_id')
    try:
        if not isinstance(identifier, str) or str(uuid.UUID(identifier)).lower() != identifier.lower(): raise ValueError()
    except ValueError as error:
        raise RuntimeError('TaskPilot returned an invalid command binding; no command was executed') from error
    return {'command_inspection_id': identifier}


def inspect_task_command_hints(task: str, display_id: int, observation: dict[str, Any]) -> None:
    """Inspect expressly named tools before flags are chosen. This cannot act."""
    if observation.get('command_capability_version') != COMMAND_CAPABILITY_VERSION or explicit_operation(task): return
    if 'shell' not in task_capability_context(task, observation)['recommended_capabilities']: return
    names = ('git', 'python3', 'python', 'node', 'ruby', 'perl', 'rg', 'jq', 'curl', 'tar', 'gzip', 'zip', 'unzip', 'swift', 'cargo', 'go', 'npm', 'pnpm', 'yarn', 'bun', 'rustc', 'make', 'xcodebuild')
    count = 0
    for name in names:
        match = re.search(r'(?<![\w./-])' + name + r'(?![\w.-])', task)
        if not match: continue
        if name in {'go', 'make'} and not re.search(r'\b(?:run|use|using|with)\s+`?' + name + r'\b', task, re.I): continue
        argv = [name]
        if name == 'git':
            subcommand = re.match(r'\s+(status|diff|log|show|add|commit|branch|checkout|switch|restore|fetch|push|pull|clone|remote|rev-parse|ls-files)\b', task[match.end():])
            if subcommand: argv.append(subcommand[1])
        try: inspect_general_command({'type': 'run_command', 'argv': argv}, display_id, observation)
        except ActionRejected as error:
            if error.code in {'cancelled', 'permission_denied', 'protected_target', 'secure_input'}: raise
            remember_command_capability(name, {'name': name, 'option_status': 'unavailable', 'reason': str(error)[:400]})
        count += 1
        if count >= 2: break


def relevant_action_examples(context: dict[str, Any], observation: dict[str, Any],
                             history: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Illustrations only: never select or construct an action to execute."""
    capabilities = set(context["recommended_capabilities"])
    families = ACTION_CAPABILITIES
    recent = [entry.get("action") for entry in history[-3:] if isinstance(entry, dict)]
    capabilities.update(families[action["type"]] for action in recent
                        if isinstance(action, dict) and action.get("type") in families)
    examples = []
    if "file_read" in capabilities:
        examples.append(action_example("read_file"))
    if "file_write" in capabilities:
        examples.append(action_example("write_file"))
    if "shell" in capabilities:
        examples.append(action_example("run_command"))
    if "browser" in capabilities:
        examples.append(action_example("navigate_browser"))
    elements = [e for e in observation.get("elements", []) if isinstance(e, dict)]
    apps = observation.get("applications", [])
    desktop = bool(apps or elements or capabilities & {"app_automation", "browser"})
    if desktop:
        if elements:
            examples.append(action_example("press"))
        if any(e.get("role") in {"AXRow", "AXOutline", "AXTable"} for e in elements):
            examples.append(action_example("double_click"))
        fields = [e for e in elements if e.get("role") in {"AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"}]
        if fields:
            examples.append(action_example("set_value"))
            examples.append(action_example("type_text"))
        if apps and (not elements or any(app.get("accessibility_available") is False for app in apps if isinstance(app, dict))):
            examples.append(action_example("click"))
        if "browser" in capabilities or any(e.get("role") in {"AXScrollArea", "AXTable", "AXOutline"} for e in elements):
            examples.append(action_example("scroll"))
        visible = {str(app.get("name") or "").casefold() for app in apps if isinstance(app, dict)}
        if not apps or any(name.casefold() not in visible for name in context["explicitly_named_apps"]):
            examples.append(action_example("launch_app"))
        if observation.get("system_context", {}).get("task_routes"):
            examples.append(action_example("open_route"))
    examples.append(action_example("wait"))
    return examples


def desktop_instruction(
    task: str,
    observation: dict[str, Any],
    history: list[dict[str, Any]],
    ledger: TaskEvidenceLedger | None = None,
) -> str:
    context = task_capability_context(task, observation)
    task_context = current_task.get()
    if task_context is not None and task_context.working_document:
        working_document = task_context.working_document
        context["working_document"] = {key: working_document[key] for key in ("state", "application", "title", "location", "revision", "selection_state", "selection_description") if key in working_document}
    if _task_value('command_capabilities'):
        context['command_capabilities'] = [_task_value('command_capabilities')[key] for key in sorted(_task_value('command_capabilities'))]
    examples = relevant_action_examples(context, observation, history)
    operation_kind = next((kind for kind, recipe in CONTRACT['command_operations'].items()
                           if re.search(recipe['intent_pattern'], task, re.I)), None)
    if operation_kind and ('shell' in context['recommended_capabilities'] or 'file_write' in context['recommended_capabilities']):
        template = operation_example(operation_kind)
        index = next((i for i, example in enumerate(examples) if example['type'] == 'run_command'), None)
        if index is None: examples.insert(0, template)
        else: examples[index] = template
        if not re.search(r'\b(?:write|append|overwrite|contents|containing)\b', task, re.I):
            examples = [example for example in examples if example['type'] != 'write_file']
    if (not observation.get('applications') and not observation.get('elements')
            and all(e['type'] in TRUSTED_NATIVE_ACTIONS | {'wait'} for e in examples)):
        examples = [e for e in examples if e['type'] != 'wait']
    types = {example["type"] for example in examples}
    illustrated = [{"status": "act", "intended_target": "<target>",
                    "expected_result": "<effect>", "action": examples[0]}, *examples[1:]]
    first = examples[0]
    if first['type'] == 'write_file':
        illustrated[0]['expected_result'] = {'type': 'file_contents', 'path': first['path'], 'content': first['content']}
    elif first['type'] == 'press' and observation.get('applications'):
        illustrated[0]['expected_result'] = {'type': 'dialog_appeared', 'pid': 1, 'title': 'Example dialog'}
    for index, example in enumerate(examples[1:], 1):
        if example['type'] == 'set_value' and any(e.get('role') in {'AXTextField', 'AXTextArea', 'AXComboBox', 'AXSearchField'}
                and 'secure' not in str(e.get('subrole', '')).casefold() for e in observation.get('elements', [])):
            illustrated[index] = {'status': 'act', 'intended_target': '<field>', 'action': example,
                                  'expected_result': {'type': 'field_value', 'element_id': '<current field_id>', 'value': example['text']}}
    if ledger is not None and not ledger.requirements:
        first = examples[0]
        if first["type"] in {"read_file", "write_file"}:
            check = {"type": "file_read" if first["type"] == "read_file" else "file_contents",
                     **{key: first[key] for key in ("path", "content") if key in first}}
        elif first["type"] == "run_command":
            check = ({'type': 'command_operation', 'operation': first['operation']} if 'operation' in first else
                     {"type": "command_executed", **{key: first[key] for key in ("argv", "command") if key in first}})
        else:
            check = {"type": "visual", "expected": "<outcome>"}
        illustrated[0]["requirements"] = [{"source": "<quote>", "description": "<goal>", "check": check}]
        if (first['type'] in {'press', 'focus', 'set_value', 'type_text', 'click', 'double_click', 'key', 'scroll'} and
                any(w.get('title') for a in observation.get('applications', []) for w in a.get('windows', []))):
            illustrated[0]['requirements'].insert(0, {'source': '<quote>', 'description': '<precondition>',
                'scope': 'prerequisite', 'check': {'type': 'window_active', 'pid': 1, 'title': '<current window title>'}})
            illustrated[0]['requirements'][1]['depends_on'] = ['r1']
            illustrated[0]['requirement_ids'] = ['r2']
    fields = [e for e in observation.get("elements", []) if isinstance(e, dict)
              and e.get("role") in {"AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"}]
    if fields and (any(e.get("role") == "AXSecureTextField" for e in fields) or
                   re.search(r"sign in|log ?in|password|verification code|secret", task, re.I)):
        illustrated.append({"status": "needs_user", "user_input": {"kind": "password"},
                            "action": {**action_example("focus"), "pid": 1}})
    recent = compact_history(history)
    condition = recovery_condition(history)
    if condition:
        # Classify against the complete owned result, then use the same safe
        # history projection as the evidence section (no native snapshots).
        condition = {**condition, "failed_action": recent[-1].get("action"), "result": recent[-1].get("result")}
    rules = decision_rules(bool(observation.get("elements")), condition,
                           bool(observation.get('text_recognition', {}).get('targets')),
                           len(grounded_candidates(observation, ledger)) if ledger is not None else 0)
    if re.search(r"sign in|log ?in|password|verification code|secret", task, re.I) or any(
            element.get("role") == "AXSecureTextField" for element in fields):
        rules += "Ask through needs_user for local credential entry without sending it to you; never expose credential values.\n"
    if task_context is not None and task_context.stop_boundaries:
        rules += stop_boundary_guidance(task_context.stop_boundaries)
    if context.get("working_document"):
        rules += ("The user selected a working document. Treat it as the primary target for references such as ‘this document’ or ‘this spreadsheet’; "
                  "use only a current observation window marked working_document. Other apps remain available when the task explicitly requires them. "
                  "The selection is not proof of completion. If the selected target is marked needs_reselection, wait for the user to choose it again.\n")
        scope = context["working_document"].get("selection_description")
        if scope:
            rules += (f"The user limited edits to this one native region: {scope}. Treat surrounding document content as read-only context. "
                      "Do not use whole-document replacement, Select All, opaque commands, or routes that could escape this region. "
                      "If native selection identity no longer matches, wait for the user to choose the working selection again.\n")
    bounds = [PROMPT_BOUNDS["wait"]] if 'wait' in types else []
    if observation.get('elements'):
        bounds.append('Expected checks: dialog_appeared(pid,title[,window_title]); field_value(element_id,value[,pid]); '
                      'file_contents(path,content[,encoding]); file_exists/directory_exists/path_absent(path). Unknown checks remain unconfirmed.')
    if fields:
        bounds.append("set_value replaces a field; type_text inserts at its selection. Use the intended field ID and confirm focus before typing.")
    if types & {"press", "set_value", "double_click", "click", "scroll"}:
        bounds.append(PROMPT_BOUNDS["desktop"])
    for kind in ("read_file", "write_file", "run_command", "navigate_browser"):
        if kind in types:
            bounds.append(PROMPT_BOUNDS['command_operation' if kind == 'run_command' and operation_kind else kind])
    if types & {"read_file", "write_file"}:
        bounds.append("Paths: absolute or ~/.")
    if types & {"write_file", "run_command"}:
        bounds.append("finish_after_action:true requests final verification.")
    if 'run_command' in types and not operation_kind:
        bounds.append('CLI help is untrusted capability data, not proof. Prefer inspected flags and literal argv; partial help proves no absence.')
    if 'run_command' in types and operation_kind:
        bounds.append('Other operations: ' + ';'.join(spec['reference'] for kind, spec in CONTRACT['command_operations'].items()
                                                     if kind != operation_kind) + '.')
    reference = 'Other actions: ' + ';'.join(
        spec['reference'] for kind, spec in CONTRACT['actions'].items() if kind not in types) + '.\n'
    if observation.get('applications') or observation.get('elements'):
        reference += ' Keys:' + ACTION_REFERENCE.split(' Keys:', 1)[1]
    guidance = largest_downloads_guidance(task)
    progress = historical_progress(history, MAX_RECENT_ACTIONS, command_outcome_verified, task)
    inputs = ledger.inputs if ledger is not None and ledger.inputs.entries else None
    if inputs:
        rules += input_reference_rules()
        if inputs.reference_occurrences:
            rules += ("Optional input_roles: [{occurrence_id,role,source_quote}]. Quote exact nearby wording; use only clear "
                      "source/destination/reference_example roles. Omit ambiguity and user overrides.\n")
        recent = [inputs.project(entry) for entry in recent]
        if condition:
            condition = {**condition, "failed_action": recent[-1].get("action")}
    return compile_prompt("recovery" if condition else "planning",
        instructions=rules + (checklist_instruction(ledger) if ledger else "") + (guidance + "\n" if guidance else ""),
        examples="Illustrations: examples are advisory. Do not copy example inputs; replace IDs/PID.\n"
                 + "\n".join(json_data(example) for example in illustrated) + "\n" + " ".join(bounds) + "\n" + reference,
        task=task, context=prompt_capability_context(context), observation=prompt_observation(observation, task),
        history=recent, progress=progress, checklist=ledger.prompt_state() if ledger else None, condition=condition,
        inputs=inputs.prompt_state(include_resource_inputs=bool(ledger and
            (ledger.batch_declaration_required_for() or ledger.batch_mode == "per_input"))) if inputs else None)


def verification_evidence(task: str, history: list[dict[str, Any]],
                          ledger: TaskEvidenceLedger | None) -> dict[str, Any]:
    # Runtime verification always has its task-owned ledger. Legacy prompt
    # callers get only facts accepted by the same native-result recorder.
    if ledger is None:
        ledger = TaskEvidenceLedger(task)
        for entry in history:
            if not isinstance(entry, dict) or not isinstance(entry.get("action"), dict): continue
            if entry.get("private_input") or entry["action"].get("private_input"): continue
            ledger.before_action(entry["action"])
            # History includes local waits, suppressed proposals and failures.
            # Untyped legacy success flags establish no native proof.
            if not isinstance(entry.get('result'), dict) or 'action_type' not in entry['result']: continue
            ledger.record_action(entry["action"], entry.get("result"))
    state = ledger.prompt_state()
    # Checklist definitions are useful; a previous proof/coverage conclusion
    # is not input to the independent audit. Evidence remains attributable.
    state["whole_request_coverage"] = "requires_independent_audit"
    state["requirements"] = {identifier: {k: v for k, v in requirement.items() if k not in {"state", "evidence_ids"}}
                             for identifier, requirement in state["requirements"].items()}
    return state


def verification_instruction(
    task: str,
    candidate: dict[str, Any],
    observation: dict[str, Any],
    history: list[dict[str, Any]],
    ledger: TaskEvidenceLedger | None = None,
) -> str:
    task_guidance = largest_downloads_guidance(task)
    examples = 'Examples illustrate shape, not evidence. Optional message/title are strings; kind is answer, result, or completion.\n'
    if not ledger:
        examples += 'Successful response example: {"verified":true,"message":"Verified result","kind":"completion"}.\n'
    examples += 'Unproven response example: {"verified":false,"missing":["Unproven requirement"]}.\n'
    if ledger:
        examples += ('Successful shape: {"verified":true,"coverage_complete":true,"message":"<exact requested result>",'
                     '"proofs":[{"requirement_id":"r1","evidence_ids":["e1"],"rationale":"<what the evidence proves>"}]}. '
                     'These IDs are illustrations; use supplied IDs.\n')
    inputs = ledger.inputs if ledger is not None and ledger.inputs.entries else None
    capability_context = task_capability_context(task, observation)
    task_context = current_task.get()
    if task_context is not None and task_context.working_document:
        capability_context["working_document"] = {key: task_context.working_document[key]
            for key in ("state", "application", "title", "location", "revision", "selection_state", "selection_description") if key in task_context.working_document}
    selection_scope = (capability_context.get("working_document") or {}).get("selection_description")
    selection_rules = (f"\nSELECTION LIMIT: The user allowed edits only within {selection_scope}. Audit all attributed changes against that one native region. "
                      "Context outside it is read-only; unrelated edits or an unresolved scope do not satisfy the request. "
                      "Selection binding alone proves no requested result.\n") if selection_scope else ""
    boundary_rules = stop_boundary_guidance(task_context.stop_boundaries, completion=True) if task_context is not None else ""
    return compile_prompt("completion",
        instructions=COMPLETION_RULES + (verification_checklist_instruction(ledger) if ledger else "")
                     + selection_rules
                     + boundary_rules
                     + ("Vision labels/crops are provisional text, not proof of control role, enabled state, focus or successful execution.\n"
                        if observation.get('text_recognition', {}).get('targets') else "")
                     + (task_guidance + "\n" if task_guidance else "")
                     + (input_reference_rules(completion=True) if inputs else ""), examples=examples,
        task=task, context=prompt_capability_context(capability_context),
        observation=prompt_observation(observation, task), history=[], progress={},
        checklist=verification_evidence(task, history, ledger),
        inputs=inputs.prompt_state(include_resource_inputs=bool(ledger and
            (ledger.batch_declaration_required_for() or ledger.batch_mode == "per_input"))) if inputs else None)


def stop_boundary_guidance(boundaries: list[dict[str, Any]], completion: bool = False) -> str:
    if not boundaries:
        return ""
    labels = ", ".join(dict.fromkeys(str(item.get("label") or "") for item in boundaries))
    sources = "\n".join(f'- User instruction: “{item["source"]}”' for item in boundaries if item.get("source"))
    if completion:
        return ("\nHARD USER STOP-BEFORE BOUNDARY: " + labels + ". The prohibition remains active regardless of any model interpretation. "
                "Verify only the permitted preparation. Do not claim a prohibited action occurred or that merely reaching its control completed the task. "
                "If a possibly finalizing action has an uncertain receipt, do not claim the boundary was preserved.\n" + sources + "\n")
    return ("\nHARD USER STOP-BEFORE BOUNDARY: " + labels + ". These restrictions come directly from the user's unquoted request and exact-input values are excluded. "
            "Prepare the requested work, but never deliver the prohibited final action. The visible presence of a Send/Publish/Submit/Purchase/Deploy control is not permission. "
            "Do not press Return/Enter or use shortcuts whose effect is uncertain; use direct text entry for line breaks. Do not attempt opaque commands, scripts, or unidentified controls that could cross a boundary; inspect read-only or choose a clearly safe preparation step. "
            "Do not count a rejected boundary action as progress or completion.\n" + sources + "\n")


class ResponseRepairBudget:
    def __init__(self) -> None:
        self.used = False


def checklist_instruction(ledger: TaskEvidenceLedger) -> str:
    contract = (
        "\nCHECKLIST: enumerate every requirement as source,description,check[,depends_on,supersedes]; quote exact clauses. "
        "Actions list outcome requirement_ids; scope is prerequisite/outcome. "
        "Checks: visual/answer(expected); file_read/file_exists/directory_exists/path_absent(path); "
        "file_contents(path,content[,encoding]); file_written(path,content,mode); stdout_equals(text); "
        "command_executed(argv|command[,working_directory]); command_operation(operation)."

    ) if not ledger.requirements else ("\nCHECKLIST: fulfill all active entries; superseded entries are historical and cannot be reported proven. "
        "Pending/invalidated need evidence, not uncertain repeats. "
        "Sources are narrow exact clauses with punctuation and qualifiers; each action lists advanced requirement_ids. "
        + (("Original clauses remain unless the latest correction conflicts. For replacements, quote the correction and set supersedes:[old IDs]; "
            "replace active dependents too. ") if ledger.instruction_revision > 0 else "")
        + ("Prove direct depends_on with fresh checks before acting. "
           if any(r.get("state") != "superseded" and r.get("depends_on") for r in ledger.requirements.values()) else ""))
    if ledger.instruction_revision > 0:
        contract += ("After a correction changes completed work, inspect its current result first; revise only if fresh evidence requires it. "
                     "Never repeat a mutation solely because a correction arrived; retain historical action attribution. ")
    if ledger.batch_declaration_required_for() or ledger.batch_mode == "per_input":
        resource_ids = [entry.identifier for entry in ledger.inputs.resource_inputs]
        contract += (
            "\nBATCH INPUTS: resource IDs are listed in inputs.resource_inputs and their exact values are in inputs.values. "
            "When at least two exist, include a batch object in this planning response with exactly mode, items, "
            "source_input_ids, excluded_inputs, global_requirement_ids. Modes are per_input, combined, or none. "
            "Classify every resource ID exactly once as a source or excluded input; use excluded reason "
            "output_destination only for a stated output location, otherwise incidental. For per_input, map every "
            "source ID in original request order to a nonempty set of active outcome requirement_ids; list all "
            "remaining outcome requirements in global_requirement_ids. Never include output destinations in items. "
            "Repeated references to the same exact input are one item. A comparison or merged result is combined, "
            "not per_input. Current resource IDs: " + json.dumps(resource_ids, separators=(",", ":")) + "."
        )
        if requests_per_input_work(ledger.task):
            contract += " The request asks for separate work on each input, so mode must be per_input and every source must be mapped."
        contract += (
            ' Example shape: {"mode":"per_input","items":[{"input_id":"<supplied resource ID>",'
            '"requirement_ids":["r1"]}],"source_input_ids":["<supplied resource ID>"],'
            '"excluded_inputs":[],"global_requirement_ids":[]}. Replace illustrative IDs with supplied IDs.'
        )
    if ledger.current_observation and ledger.current_observation.get("elements"):
        contract += ("Local checks: window_active(pid,title), field_value(element_id,value[,pid]), "
                     "dialog_present(pid,title[,window_title]). Preconditions must use local checks, not visual claims. ")
    return contract


def verification_checklist_instruction(ledger: TaskEvidenceLedger) -> str:
    instruction = (
        "\nAudit the checklist against the COMPLETE ORIGINAL TASK plus every applied correction, including destinations, contents, constraints, "
        "ordering, and requested returned output. If anything was omitted, return verified:false and "
        "uncovered_requirements in the planning checklist shape. Cite proof for EACH requirement using runtime IDs. "
        "Audit prerequisite ordering and keep final outcomes distinct from historical preconditions. "
        "Native facts prove only their stated scope; "
        "a file existence check cannot prove contents, and delivery/focus cannot prove a save/send. "
        "Visual proof must cite the fresh observation; explain the visible outcome. An answer needs relevant "
        "evidence and its requested output, never an unsupported result. For file_read/stdout_equals include "
        "the full verified output verbatim OR output_evidence_ids to have TaskPilot return it exactly. "
        "Excerpts cannot substitute for full contents.\n"
    )
    if ledger.batch_mode == "per_input":
        instruction += (
            "The batch roster in the checklist is mandatory: audit every listed input separately, confirm all associated "
            "outcome requirements have currently valid matching evidence, and report any omitted or unverified input as "
            "uncovered. A successful whole-request coverage claim cannot skip an item.\n"
        )
    if ledger.continuation_checkpoint is not None:
        instruction += (
            "\nThis is a fresh continuation run. Previous result summaries are hints only. "
            "TaskPilot has locally rechecked only requirements listed as rechecked in the continuation state; "
            "all other requirements remain unfinished. Use fresh observations and new evidence IDs, never reuse "
            "a prior click, command, receipt, or completion claim. Inspect uncertain prior work before any overlapping mutation, "
            "and finish by auditing the complete request, corrections, dependencies, and every batch item.\n"
        )
    return instruction


@local_operation(5.0, 'completion_readback')
def refresh_completion_evidence(display_id: int, ledger: TaskEvidenceLedger,
                                evidence_guard: EvidenceConsistency, router: TaskModelRouter) -> dict:
    rechecks = ledger.recheck_actions()
    effect_checks = ledger.recheck_effects()
    prior_evidence = [e for e in ledger.evidence.values() if e["valid"] and e["mutable"]]
    ledger.invalidate(lambda e: e["mutable"])
    for action in rechecks:
        try:
            result = bridge_call("recheck", display_id, action=action)
        except ActionRejected as error:
            if error.code in {"cancelled", "permission_denied", "protected_target", "secure_input"}: raise
            # A failed readback leaves its requirements unproven. No mutation
            # or command is repeated to obtain proof.
            continue
        known = set(ledger.evidence)
        ledger.record_action(action, result, recheck=True)
        for check, actual in zip(result.get("requested_checks", []), result.get("checks", [])):
            prior = next((e for e in reversed(prior_evidence) if ledger.matches(check, {**e, "valid": True})), None)
            evidence_guard.note_native_check(check, {"requested_checks": [check], "checks": [actual],
                "outcome": actual['outcome'], "verified": actual['verified'], "verification_scope": "requested_outcomes"}, prior)
        if action.get("type") == "read_file":
            fresh = next((e for key, e in reversed(list(ledger.evidence.items())) if key not in known and e["valid"] and e["fact"].get("type") == "file_read"), None)
            prior = next((e for e in reversed(prior_evidence) if e["fact"].get("path") == path_key(action["path"]) and e["fact"].get("content_sha256")), None)
            evidence_guard.note_native_read(action, prior, fresh)
    for check in effect_checks:
        effect = ExpectedEffect(check, {})
        captured = []
        def read_check(value):
            raw = bridge_call('check_effect', display_id, check=value)
            captured.append(raw)
            return raw
        checked = effect.wait_file(read_check, timeout=0)
        prior = next((e for e in reversed(prior_evidence) if ledger.matches(check, {**e, "valid": True})), None)
        if captured: evidence_guard.note_native_check(check, captured[-1], prior)
        router.metrics['effect_checks'] = router.metrics.get('effect_checks', 0) + 1
        if checked['outcome'] == 'verified': ledger.record_effect(check, checked['evidence'])
    observation = bridge_call("observe", display_id)
    return observation


def verify_task_completion(task: str, candidate: dict[str, Any], display_id: int,
                           history: list[dict[str, Any]], router: TaskModelRouter,
                           client: ACPClient, ledger: TaskEvidenceLedger,
                           evidence_guard: EvidenceConsistency | None = None) -> bool:
    emit("status", message="Checking evidence for every requested requirement…")
    evidence_guard = evidence_guard or EvidenceConsistency()
    context = current_task.get()
    if context is not None and has_unresolved_stop_boundary_action(history, context.stop_boundaries):
        history.append({"action": "boundary_reconciliation_required", "result": {
            "outcome": "rejected", "error_code": "stop_boundary_uncertain",
            "message": "An earlier action has an uncertain delivery result; inspect its effect before claiming the boundary was preserved."}})
        emit("status", message="Checking whether an earlier action crossed the stop-before boundary…")
        return False
    try:
        observation = refresh_completion_evidence(display_id, ledger, evidence_guard, router)
    except (LocalBudgetExpired, ActionRejected) as error:
        if error.code != 'local_budget_exhausted': raise
        history.append({'action': 'completion_rejected', 'result': {'error_code': error.code,
            'phase': getattr(error, 'phase', 'completion_readback'), 'message': str(error)}})
        emit('status', message=str(error))
        return False
    path = Path(str(observation.get("screenshot_path") or ""))
    try:
        if not path.is_file(): raise RuntimeError(f"{PRODUCT_NAME} could not capture the completion check")
        ledger.observe(observation)
        conflicts = evidence_guard.conflicts({"status": "done"}, observation, ledger)
        if conflicts:
            fresh, report = inspect_evidence(evidence_guard, conflicts, observation, display_id, ledger, router.metrics)
            discard_observation_image(fresh)
            history.append({"action": "evidence_inspection", "result": report})
            return False  # Reconsider; never certify a conflicted candidate.
        verification = routed_json_prompt(router, client,
            verification_instruction(task, candidate, observation, history, ledger), path,
            purpose="verification", observation=observation, ledger=ledger)
        conflicts = evidence_guard.conflicts(verification, observation, ledger)
        if conflicts:
            fresh, report = inspect_evidence(evidence_guard, conflicts, observation, display_id, ledger, router.metrics)
            discard_observation_image(fresh)
            history.append({"action": "evidence_inspection", "result": report})
            return False
    finally:
        discard_observation_image(observation)
    if not ledger.audit(verification):
        publish_task_progress(ledger, active_requirement_ids=[])
        missing = verification.get("missing") or []
        missing += [r["description"] for r in ledger.requirements.values()
                    if r["state"] not in {"proven", "superseded"}]
        history.append({"action": "completion_rejected", "result": missing or ["Whole-request coverage is not proven"]})
        emit("status", message="The evidence check found more work — continuing…")
        return False
    publish_task_progress(ledger, active_requirement_ids=[])
    message = verification.get("message") or "Task completed"
    for ref in verification.get("output_evidence_ids", []):
        fact = ledger.evidence[ref]["fact"]
        exact = (("[Binary file; base64 encoded]\n" if fact["encoding"] == "base64" else "") + fact["content"]
                 if fact["type"] == "file_read" else fact["text"])
        if exact not in message: message += "\n\n" + exact
    publish_task_metrics(router, client, ledger)
    return complete_from_decision(
        {"output": message, "output_title": verification.get("title") or candidate.get("output_title") or "OpenClaw result",
         "output_kind": verification.get("kind") or candidate.get("output_kind") or "result"},
        message, ledger, history=history)


@local_operation(5.0, 'dependency_inspection')
def prepare_dependency_action(decision: dict, display_id: int, ledger: TaskEvidenceLedger,
                              metrics: dict, evidence_guard: EvidenceConsistency | None = None) -> dict | None:
    """Read-only prerequisite preflight; no model request or action receipt."""
    identifiers = ledger.action_requirements(decision)
    direct = {ref for identifier in identifiers for ref in ledger.requirements[identifier].get("depends_on", [])}
    seen = set()
    for ref in ledger.prerequisites(identifiers):
        requirement = ledger.requirements[ref]
        if (ref not in direct and requirement.get("scope") == "prerequisite" and
                any(ledger.requirement_matches(ref, e) and e["fact"]["type"] == "prerequisite_checked"
                    for e in ledger.evidence.values())):
            continue
        check = requirement["check"]
        if check["type"] not in FILE_EFFECTS: continue
        fingerprint = evidence_digest(check)
        if fingerprint in seen: continue
        seen.add(fingerprint)
        prior = next((e for e in reversed(list(ledger.evidence.values())) if e["mutable"] and ledger.matches(check, e)), None)
        ledger.invalidate(lambda e: e["mutable"] and ledger.matches(check, e))
        captured = []
        def read_check(value):
            raw = bridge_call("check_effect", display_id, check=value)
            captured.append(raw)
            return raw
        checked = ExpectedEffect(check, {}).wait_file(read_check, timeout=0)
        if evidence_guard and captured: evidence_guard.note_native_check(check, captured[-1], prior)
        metrics["dependency_checks"] = metrics.get("dependency_checks", 0) + 1
        if checked["outcome"] == "verified": ledger.record_effect(check, checked["evidence"])
    return ledger.check_prerequisites(decision, retain=True)


@local_operation(5.0, 'evidence_inspection')
def inspect_evidence(guard: EvidenceConsistency, conflicts: list, observation: dict,
                     display_id: int, ledger: TaskEvidenceLedger, metrics: dict) -> tuple[dict, dict]:
    def observe(pid, budget):
        return bridge_call("observe", display_id, consistency_budget_ms=budget,
                           **({"evidence_inspection_pid": pid} if pid is not None else {}))
    fresh, report = guard.inspect(conflicts, observation, ledger, observe=observe,
        readback=lambda method, payload: bridge_call(method, display_id,
            **{"action" if method == "recheck" else "check": payload}),
        discard=discard_observation_image, now=time.monotonic, sleep=time.sleep)
    metrics.update(conflict_inspections=guard.inspections, evidence_conflicts=guard.rejections)
    return fresh, report


def publish_task_metrics(router: TaskModelRouter, client: ACPClient, ledger: TaskEvidenceLedger) -> None:
    # Terminal events revoke the native lease. Publish aggregate diagnostics
    # before completion so the originating invocation can still accept them.
    router.metrics.update(evidence_checks=ledger.checks, coverage_rejections=ledger.rejections,
        requirements_proven=sum(r["state"] == "proven" for r in ledger.requirements.values()),
        dependency_rejections=ledger.dependency_rejections, **_task_value('receipt_metrics'), **_task_value('local_change_metrics'), **_task_value('command_capability_metrics'))
    router.metrics.update(prompt_calls=client.prompt_calls, model_switches=client.model_switches)
    emit("request_metrics", **router.metrics)


def validated_prompt(client: ACPClient, instruction: str, screenshot_path: Path,
                     purpose: str, budget: ResponseRepairBudget,
                     observation: dict[str, Any] | None = None,
                     metrics: dict[str, Any] | None = None,
                     ledger: TaskEvidenceLedger | None = None) -> dict[str, Any]:
    images = detail_images(observation)
    def request(text: str) -> str:
        return client.prompt(text, screenshot_path, detail_images=images) if images else client.prompt(text, screenshot_path)
    def prompt(text: str) -> str:
        before = getattr(client, "successful_provider_retries", None)
        try:
            return request(text)
        except Exception as error:
            if instruction_correction_pending():
                raise InstructionSuperseded("A correction arrived while the previous model request was finishing") from error
            if classify_failure(error, time.time()).kind != "transport":
                raise
            selected = client.selected_model
            client.reconnect()
            if metrics is not None:
                metrics["reconnects"] += 1
                metrics[purpose] += 1
            if instruction_correction_pending():
                raise InstructionSuperseded("A correction arrived during Gateway recovery")
            client.select_model(selected)
            return request(text)
        finally:
            after = getattr(client, "successful_provider_retries", None)
            if metrics is not None and type(after) is int:
                metrics["provider_retries"] = (metrics["provider_retries"] or 0) + after - (before if type(before) is int else 0)

    def validate(response: str) -> dict[str, Any]:
        try:
            value = extract_json_object(response)
        except ResponseValidationError:
            # Only non-JSON provider errors use provider recovery. Invalid
            # decision fields containing words like "quota" are still repaired.
            if response.lstrip().startswith(("{", "[", "```")):
                raise
            failure = classify_failure(RuntimeError(response), time.time())
            details = {
                "credentials": "OpenClaw rejected an invalid API key; repair credentials in Settings.",
                "quota": "OpenClaw reported exhausted quota; wait for the reported reset.",
                "temporary": "OpenClaw reported temporary capacity limits; retry after cooldown.",
                "unavailable": "OpenClaw reported the selected model unavailable.",
                "transport": "OpenClaw reported a transport failure.",
                "cancelled": "OpenClaw cancelled the TaskPilot turn.",
            }
            if failure.kind in details:
                raise ModelAttemptError.from_failure(failure)
            raise
        envelope = response_error(value)
        if envelope is not None:
            failure = classify_failure(ProviderRequestError(envelope, getattr(client, "selected_model", None)), time.time())
            failure.provider_retries_counted = metrics is not None and type(getattr(client, "last_prompt_provider_retries", None)) is int
            raise ModelAttemptError.from_failure(failure)
        return validate_response(value, purpose, observation, ledger)

    response = prompt(instruction)
    if instruction_correction_pending():
        raise InstructionSuperseded("The model response was superseded by a task correction")
    try:
        return validate(response)
    except ResponseValidationError as error:
        if instruction_correction_pending():
            raise InstructionSuperseded("The response became invalid only after its instruction revision was superseded") from error
        if budget.used:
            raise ModelAttemptError(str(error)) from error
        budget.used = True
        if metrics is not None:
            metrics["repairs"] += 1
            metrics[purpose] += 1
        emit("status", message="Correcting the response format before changing models…")
        repair = compile_repair(instruction, response, str(error), purpose)
        repaired = prompt(repair)
        if instruction_correction_pending():
            raise InstructionSuperseded("The repaired response was superseded by a task correction")
        try:
            return validate(repaired)
        except ResponseValidationError as error:
            raise ModelAttemptError(str(error)) from error


def routed_json_prompt(
    router: TaskModelRouter,
    client: ACPClient,
    instruction: str,
    screenshot_path: Path,
    purpose: str = "planning",
    observation: dict[str, Any] | None = None,
    ledger: TaskEvidenceLedger | None = None,
) -> dict[str, Any]:
    context = current_task.get()
    if instruction_correction_pending():
        raise InstructionSuperseded("A task correction is waiting to be applied")
    if context is not None: context.machine.require("verify" if purpose == "verification" else "plan")
    image = screenshot_buffer(screenshot_path, (observation or {}).get("observation_revision"))
    identity = (STATE_FINGERPRINT_VERSION, STOP_BOUNDARY_POLICY_VERSION, _task_value('generation'),
        context.instruction_revision if context is not None else 0, VALIDATION_VERSION, CONTRACT_HASH,
        TARGET_CHOICE_PROTOCOL_VERSION,
        context.target_binding_revision if context is not None else 0,
        json.dumps(context.target_bindings, sort_keys=True, separators=(",", ":")) if context is not None else None,
        context.working_document_revision if context is not None else 0,
        json.dumps(context.working_document, sort_keys=True, separators=(",", ":")) if context is not None and context.working_document else None,
        CHECKLIST_VERSION, BATCH_PROGRESS_VERSION, EXPECTED_EFFECT_VERSION, LOCAL_CHANGE_VERSION, COMMAND_CAPABILITY_VERSION,
        PROMPT_COMPILER_VERSION, VERIFICATION_SESSION_VERSION, COORDINATE_MAPPING_VERSION,
        OBSERVATION_COMPLETENESS_VERSION, TEXT_RECOGNITION_VERSION, EVIDENCE_CONSISTENCY_VERSION,
        RECOVERY_CYCLE_VERSION, TASK_INPUT_VERSION, ledger.fingerprint() if ledger else None,
        purpose, os.environ.get('TASKPILOT_MANAGED_FINGERPRINT', ''), instruction, observation_state(observation).fingerprint, image.digest)
    previous = getattr(client, "_decision_fingerprint", None)
    if isinstance(previous, tuple) and len(previous) == 2 and previous[0] == identity:
        key = previous[1]
    else:
        key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        client._decision_fingerprint = (identity, key)
    cached = getattr(client, "decision_cache", {})
    if cached.get("key") == key:
        value = validate_response(json.loads(json.dumps(cached["decision"])), purpose, observation, ledger)
        router.metrics["cache_hits"] += 1
        return value
    budget = ResponseRepairBudget()
    def request_with_model(model: str) -> dict[str, Any]:
        client.select_model(model)
        return validated_prompt(client, instruction, screenshot_path, purpose, budget, observation, router.metrics, ledger)

    session = client.verification_session() if purpose == "verification" else nullcontext()
    with session:
        result = router.execute(request_with_model, purpose=purpose)
    action = result.get("action") or {}
    if not action or action.get("type") in {"none", "wait"}:
        client.decision_cache = {"key": key, "decision": result}
    else:
        client.decision_cache = {}
    router.metrics["model_switches"] = getattr(client, "model_switches", 0)
    emit("request_metrics", **router.metrics)
    return result


def run_task(task: str, display_id: int, openclaw_path: str | None, api_key: str) -> None:
    if current_task.get() is not None:
        raise ExecutionStateError("A task already owns this execution context")
    context = TaskContext(task, display_id, _task_value('generation'),
                          exact_input_references=list(_exact_input_references),
                          stop_boundaries=detect_stop_boundaries(task, list(_exact_input_references)),
                          original_task=task, original_input_references=list(_exact_input_references),
                          correction_key=_task_value('correction_key'),
                          working_document_revision=_task_value('working_document_revision'),
                          working_document_key=_task_value('working_document_key'),
                          continuation_checkpoint=_task_value('continuation_checkpoint'))
    token = current_task.set(context)
    try:
        with screenshot_buffer_scope():
            _run_task(task, display_id, openclaw_path, api_key)
    finally:
        current_task.reset(token)


def _run_task(task: str, display_id: int, openclaw_path: str | None, api_key: str) -> None:
    context = current_task.get()
    if context is None:
        raise ExecutionStateError("Task execution requires an owned context")
    TaskExecution(context).run(openclaw_path, api_key)


class TaskExecution:
    """Phase handlers share one owned context; only the dispatcher advances work.

    Native delivery/receipt and model boundaries independently enforce the phase
    permissions, so a helper cannot accidentally execute during verification.
    SIGSTOP freezes this process (including recovery waits); SIGCONT continues
    the same phase and pending receipt. Native leases still gate real delivery.
    """
    def __init__(self, context: TaskContext):
        self.c = context
        context.working_document_update_handler = self.apply_working_document_update

    def run(self, openclaw_path: str | None, api_key: str) -> None:
        c = self.c
        try:
            c.ledger = TaskEvidenceLedger(c.task, c.generation,
                                          exact_input_references=c.exact_input_references)
            if c.continuation_checkpoint is not None:
                c.ledger.initialize_continuation(c.continuation_checkpoint)
            publish_planned_destination(c.ledger)
            publish_task_wait("starting",
                              "Checking previous results…" if c.continuation_checkpoint is not None else "Connecting to the app",
                              operation_key="continuation-checking" if c.continuation_checkpoint is not None else "task-startup",
                              ledger=c.ledger)
            publish_task_progress(c.ledger, force=True)
            c.recovery = ActionRecovery()
            c.recovery_cycles = RecoveryCycles(rejection_limit=MAX_IDENTICAL_ACTIONS)
            c.evidence_guard = EvidenceConsistency()
            c.machine.require("configure")
            resolved = find_openclaw(openclaw_path)
            if c.continuation_checkpoint is None and (is_largest_downloads_file_task(c.task) or c.ledger.local_complete_grammar):
                c.runtime_state = prepare_runtime(resolved, api_key)
                api_key = ""
                try:
                    if self.local_task(): return
                except InstructionSuperseded:
                    if not instruction_correction_pending(): raise
                    if c.machine.phase == Phase.VERIFYING:
                        c.machine.transition(Phase.OBSERVING)
                    self.apply_pending_correction()
            c.runtime_state = prepare_runtime(resolved, api_key)
            api_key = ""
            c.observation_keywords = sorted(w for w in words(c.task) if len(w) <= 64 and w.isalnum())[:48]
            c.machine.require("connect")
            descriptor_path = os.environ.get("TASKPILOT_MANAGED_DESCRIPTOR")
            if descriptor_path:
                managed_openclaw.wait_for_health(Path(descriptor_path), status=lambda text: emit("status", message=text))
                resolved = refresh_managed_descriptor()['executable']
            try:
                try:
                    c.client = ACPClient(resolved)
                except Exception as error:
                    if not descriptor_path or classify_failure(error,time.time()).kind != 'transport': raise
                    c.machine.transition(Phase.RECOVERING)
                    publish_task_wait('reconciling','Waiting for private Gateway recovery',
                                      operation_key='gateway-startup-recovery',ledger=c.ledger)
                    managed_openclaw.wait_for_health(Path(descriptor_path),force=True,
                        status=lambda text: emit('status',message=text))
                    c.machine.transition(Phase.STARTING,recovered=True)
                    resolved = refresh_managed_descriptor()['executable']
                    c.client = ACPClient(resolved)
            except Exception as error:
                c.runtime_state.record_failure(PRIMARY_MODELS[0], classify_failure(error, time.time()))
                emit("model_health", model=PRIMARY_MODELS[0], state="repair", detail=str(error))
                raise
            c.router = TaskModelRouter(state=c.runtime_state)
            c.machine.transition(Phase.OBSERVING)
            emit("status", message=f"OpenClaw is connecting to the {PRODUCT_NAME} screen…")
            handlers = {
                Phase.OBSERVING: self.observe, Phase.PLANNING: self.plan,
                Phase.RECONCILING: self.reconcile, Phase.EXECUTING: self.execute,
                Phase.WAITING_INPUT: self.secure_input, Phase.WAITING_CHOICE: self.resolve_target_choice,
                Phase.VERIFYING: self.verify,
            }
            while c.machine.phase != Phase.DRAINING:
                handlers[c.machine.phase]()
        except BaseException as error:
            c.machine.drain()  # Includes Stop/SystemExit, not just provider errors.
            stopped = isinstance(error, KeyboardInterrupt) or (isinstance(error, SystemExit) and error.code in {130, 143})
            publish_task_wait("draining", "Finishing the task safely",
                              operation_key="task-draining", ledger=c.ledger)
            publish_task_progress(c.ledger, lifecycle="stopped" if stopped else "failed", active_requirement_ids=[])
            if c.runtime_state is not None:
                c.runtime_state.invalidate()
            raise
        finally:
            c.machine.drain()
            try:
                discard_observation_image(c.pending_observation)
                discard_observation_image(c.observation)
                c.pending_observation = c.observation = None
                c.observation_keywords.clear()
                c.command_capabilities.clear()
                if c.router is not None:
                    c.router.metrics.update(recovery_cycles=c.recovery_cycles.detections,
                                            cycle_suppressions=c.recovery_cycles.suppressions)
                    publish_task_metrics(c.router, c.client, c.ledger)
            finally:
                if c.client is not None: c.client.close()
            c.machine.transition(Phase.FINISHED, cleanup=True)

    def local_task(self) -> bool:
        c = self.c
        if is_largest_downloads_file_task(c.task):
            c.machine.transition(Phase.OBSERVING)
            publish_task_wait("observing", "Checking file details",
                              operation_key="local-downloads-check", ledger=c.ledger)
            emit("status", message=f"{PRODUCT_NAME} is checking exact file sizes in Downloads…")
            largest = largest_top_level_file(Path.home() / "Downloads")
            message = (f"The largest file in your Downloads folder is '{largest['name']}', "
                       f"which is {formatted_file_size(int(largest['bytes']))} ({int(largest['bytes']):,} bytes).")
            c.ledger.local_answer(message)
            publish_task_progress(c.ledger)
            c.machine.transition(Phase.VERIFYING, local_request=True)
            self.local_metrics()
            completed = complete_from_decision(
                {"output": message, "output_title": "Largest File in Downloads", "output_kind": "answer"},
                message, c.ledger, history=c.history)
            if not completed:
                self.apply_pending_correction()
                return False
            return True
        if not c.ledger.local_complete_grammar:
            return False
        c.machine.transition(Phase.OBSERVING)
        publish_task_wait("observing", "Checking the requested file",
                          operation_key="local-file-read", ledger=c.ledger)
        c.machine.transition(Phase.EXECUTING, local_request=True)
        check = next(iter(c.ledger.requirements.values()))["check"]
        action = {"type": "read_file", "path": check["path"], "max_bytes": action_default("read_file", "max_bytes")}
        result = bridge_call("act", c.display_id, action=action)
        c.ledger.record_action(action, result)
        publish_task_progress(c.ledger)
        if result.get("truncated") is not False:
            raise RuntimeError("The requested full file contents exceed the bounded 128 KiB read limit; the task is incomplete")
        output = c.ledger.exact_output(check, next(iter(c.ledger.requirements.values()))["evidence_ids"])
        if output is None:
            raise RuntimeError("TaskPilot could not verify the requested file contents; the task is incomplete")
        c.machine.reconcile()
        # The entire local grammar and deterministic evidence replace planning.
        c.machine.transition(Phase.OBSERVING)
        c.machine.transition(Phase.VERIFYING, local_request=True)
        self.local_metrics()
        completed = complete_from_decision(
            {"output": output, "output_title": "File contents", "output_kind": "result"},
            str(result.get("message") or "Read file"), c.ledger, history=c.history)
        if not completed:
            self.apply_pending_correction()
            return False
        return True

    def local_metrics(self) -> None:
        emit("request_metrics", planning=0, verification=0, retries=0, model_switches=0,
             cache_hits=0, reconnects=0, provider_retries=None, **self.c.receipt_metrics)

    def observe(self) -> None:
        c = self.c
        if instruction_correction_pending():
            self.apply_pending_correction()
        c.step += 1
        if c.step > MAX_STEPS:
            raise RuntimeError(f"{PRODUCT_NAME} reached its {MAX_STEPS}-step safety limit")
        c.decision = c.action = c.result = c.recovered_result = c.input_target = c.failure = None
        if c.continuation_checkpoint is not None and not c.continuation_recheck_started:
            publish_task_wait("observing", "Checking previous results…",
                              operation_key="continuation-recheck", ledger=c.ledger)
            self.recheck_continuation_file_results()
            c.continuation_recheck_started = True
            publish_task_progress(c.ledger, active_requirement_ids=[])
        publish_task_wait("observing", "Checking the current screen",
                          operation_key=f"observation:{c.step}", ledger=c.ledger)
        discard_observation_image(c.observation)
        c.observation = c.pending_observation if c.pending_observation is not None else bridge_call("observe", c.display_id)
        c.pending_observation = None
        publish_observed_destination(c.observation, c.task, c.step)
        while instruction_correction_pending():
            discard_observation_image(c.observation)
            c.observation = None
            self.apply_pending_correction()
            c.observation = bridge_call("observe", c.display_id)
        while isinstance(c.observation.get("working_document"), dict) and (
                c.observation["working_document"].get("state") == "needs_reselection" or
                c.observation["working_document"].get("selection_state") == "needs_reselection"):
            missing_document = c.observation["working_document"]
            selection_missing = missing_document.get("selection_state") == "needs_reselection"
            publish_planned_destination(c.ledger)
            emit("working_document_needs_reselection",
                 binding_revision=missing_document.get("revision"),
                 application=str(missing_document.get("application") or "Unknown app")[:120],
                 title=str(missing_document.get("title") or "Untitled window")[:240],
                 selection=selection_missing)
            wait_text = "Choose the working selection again" if selection_missing else "Choose the working document again"
            operation_suffix = "selection" if selection_missing else "document"
            publish_task_wait("reconciling", wait_text,
                operation_key=f"working-document-reselect:{c.working_document_revision}:{operation_suffix}", ledger=c.ledger)
            c.pending_task_control = receive_pending_task_control(timeout=None)
            discard_observation_image(c.observation)
            c.observation = None
            self.apply_pending_correction()
            c.observation = bridge_call("observe", c.display_id)
        observed_document = c.observation.get("working_document")
        if isinstance(observed_document, dict):
            c.working_document = observed_document
            if observed_document.get("state") == "needs_reselection" or observed_document.get("selection_state") == "needs_reselection":
                emit("working_document_needs_reselection",
                     binding_revision=observed_document.get("revision"),
                     application=str(observed_document.get("application") or "Unknown app")[:120],
                     title=str(observed_document.get("title") or "Untitled window")[:240],
                     selection=observed_document.get("selection_state") == "needs_reselection")
        c.screenshot_path = Path(str(c.observation.get("screenshot_path") or ""))
        if not c.screenshot_path.is_file():
            raise RuntimeError(f"{PRODUCT_NAME} did not provide a readable screen image")
        c.ledger.observe(c.observation)
        publish_task_progress(c.ledger, active_requirement_ids=[])
        cycle_report = c.recovery_cycles.observe(c.observation, c.ledger)
        c.router.metrics.update(recovery_cycles=c.recovery_cycles.detections, cycle_suppressions=c.recovery_cycles.suppressions)
        if cycle_report:
            c.history.append({"step": c.step, "action": "recovery_cycle", "result": cycle_report})
        c.input_target = secure_input_target(c.observation, c.history)
        if c.input_target is not None:
            discard_observation_image(c.observation)
            c.machine.transition(Phase.WAITING_INPUT, secure_target=True)
            return
        if c.loading_pid is not None:
            if observation_is_loading(c.observation, c.loading_pid):
                publish_task_wait("reconciling", "The page to finish loading",
                                  operation_key=f"loading:{c.step}:{c.loading_pid}", ledger=c.ledger)
                c.reconcile_reason = "loading"
                c.machine.transition(Phase.RECONCILING, observation=True)
                return
            c.loading_pid, c.loading_waits = None, 0
        c.machine.transition(Phase.PLANNING, observation=True)

    def recheck_continuation_file_results(self) -> None:
        c = self.c
        ledger = c.ledger
        if ledger is None:
            return
        for identifier in sorted(ledger.continuation_prior_verified_ids):
            requirement = ledger.requirements.get(identifier)
            if not requirement or requirement.get("state") == "superseded":
                continue
            check = requirement.get("check", {})
            if check.get("type") not in FILE_CHECKS:
                continue
            try:
                raw = bridge_call("check_effect", c.display_id, check=check)
                checks = raw.get("checks", []) if isinstance(raw, dict) else []
                if (raw.get("outcome") == "verified" and raw.get("verified") is True and
                        len(checks) == 1 and isinstance(checks[0], dict)):
                    ledger.record_effect(check, checks[0])
            except ActionRejected as error:
                if error.code in {"cancelled", "permission_denied", "protected_target", "secure_input"}:
                    raise
            except (RuntimeError, ValueError):
                # An unavailable or changed result stays unfinished; it is
                # never recreated from the old action or receipt.
                continue

    def plan(self) -> None:
        c = self.c
        try:
            publish_task_wait("planning", "Choosing the next step",
                              operation_key=f"planning:{c.step}", ledger=c.ledger)
            c.screenshot_digest = observation_image_digest(c.observation)
            if not c.command_hints_inspected:
                inspect_task_command_hints(c.task, c.display_id, c.observation)
                c.command_hints_inspected = True
            emit("status", message=f"OpenClaw is planning visible step {c.step}…")
            c.decision = routed_json_prompt(c.router, c.client,
                desktop_instruction(c.task, c.observation, c.history, c.ledger), c.screenshot_path,
                observation=c.observation, ledger=c.ledger)
        except InstructionSuperseded:
            c.decision = None
            c.reconcile_reason = "correction"
            c.machine.transition(Phase.RECONCILING, correction=True)
        finally:
            discard_observation_image(c.observation)
            c.observation = None if c.machine.phase == Phase.RECONCILING and c.reconcile_reason == "correction" else c.observation
        if c.reconcile_reason == "correction":
            return
        c.ledger.accept_plan(c.decision, c.observation)
        publish_task_input_roles(c.ledger)
        publish_planned_destination(c.ledger)
        active_ids = c.ledger.action_requirements(c.decision) if effective_decision_status(c.decision) == "act" else []
        publish_task_progress(c.ledger, lifecycle="running", active_requirement_ids=active_ids)
        publish_task_wait("reconciling", "Preparing the next step",
                          operation_key=f"decision:{c.step}", ledger=c.ledger)
        emit("status", message=str(c.decision.get("summary") or "OpenClaw inspected the screen"))
        c.reconcile_reason = "decision"
        c.machine.transition(Phase.RECONCILING, decision=True)

    def defer_for_evidence(self) -> bool:
        c = self.c
        conflicts = c.evidence_guard.conflicts(c.decision, c.observation, c.ledger)
        if not conflicts: return False
        publish_task_wait("reconciling", "Checking the intended target",
                          operation_key=f"evidence:{c.step}", ledger=c.ledger)
        c.pending_observation, report = inspect_evidence(c.evidence_guard, conflicts, c.observation,
                                                       c.display_id, c.ledger, c.router.metrics)
        c.history.append({"step": c.step, "action": "evidence_inspection", "result": report})
        c.consecutive_evidence_conflicts += 1
        if c.consecutive_evidence_conflicts >= 3:
            raise RuntimeError("TaskPilot could not reconcile the target's conflicting evidence after three fresh decisions; no dependent action was dispatched")
        emit("status", message="Inspecting conflicting evidence before continuing…")
        return True

    def defer_for_dependencies(self) -> bool:
        c = self.c
        publish_task_wait("reconciling", "Checking required prerequisites",
                          operation_key=f"dependencies:{c.step}", ledger=c.ledger)
        blocked = prepare_dependency_action(c.decision, c.display_id, c.ledger, c.router.metrics, c.evidence_guard)
        if self.defer_for_evidence(): return True
        if blocked is None:
            c.consecutive_dependency_blocks = 0
            return False
        c.consecutive_dependency_blocks += 1
        c.ledger.dependency_rejections += 1
        c.history.append({"step": c.step, "action": c.decision.get("action"),
            "result": {"outcome": "rejected", "error_code": "prerequisite_unproven",
                       "message": "No action delivered; prove the prerequisite before advancing", **blocked},
            "requirement_ids": c.ledger.action_requirements(c.decision)})
        if c.consecutive_dependency_blocks >= 3:
            raise RuntimeError("TaskPilot could not prove the required prerequisites after three fresh decisions; no dependent action was delivered")
        emit("status", message="Checking the required prerequisites before continuing…")
        return True

    def reconcile(self) -> None:
        c = self.c
        if c.reconcile_reason == "correction":
            self.apply_pending_correction()
        elif c.reconcile_reason == "loading":
            publish_task_wait("reconciling", "The page to finish loading",
                              operation_key=f"loading:{c.step}:{c.loading_pid}", ledger=c.ledger)
            if c.loading_waits >= 2:
                raise RuntimeError("The target app is still loading after bounded local recovery; no action was repeated while it was busy.")
            c.loading_waits += 1
            try:
                c.pending_observation, settling = wait_for_screen_change(c.display_id, c.observation,
                    {"type": "wait", "pid": c.loading_pid}, timeout=5.0)
            finally:
                discard_observation_image(c.observation)
            c.history.append({"step": c.step, "action": {"type": "wait", "seconds": 5},
                "result": {"message": "Waited locally for the loading app", "recovery": "wait_for_loading", "settling": settling}})
        elif c.reconcile_reason == "secure_settle":
            c.pending_observation, _ = wait_for_screen_change(c.display_id, c.observation,
                {"type": "type_text", "pid": c.input_target["pid"]})
            c.loading_pid, c.loading_waits = None, 0
        elif c.reconcile_reason == "failure":
            self.reconcile_failure()
        elif c.reconcile_reason == "effect":
            publish_task_wait("reconciling", f"Checking for {expected_wait_description(c.decision)}",
                              operation_key=f"effect:{c.step}", ledger=c.ledger)
            with local_scope(5.0, 'effect_verification', budget=c.local_budget):
                c.pending_observation, c.result = verify_expected_effect(c.display_id, c.observation, c.action,
                    c.result, c.decision.get("expected_result"), c.screenshot_digest, c.router.metrics)
            scope = expected_effect_presentation_scope(c.result)
            if scope and c.presentation_action_id:
                emit("action_presentation", action_id=c.presentation_action_id, state="confirmed",
                     verification_scope=scope)
            if c.result.get("outcome") == "verified": c.recovery.succeeded(c.action, c.observation)
            if c.result.get("outcome") == "delivered_unconfirmed":
                c.router.metrics["unconfirmed_actions"] += 1
                c.recovery.unconfirmed(c.action, c.observation)
                c.result = {**c.result, "recovery": "inspect_effect"}
            record_action_diagnostic(c.action, c.result)
            self.record_result()
            return
        elif c.reconcile_reason == "decision":
            self.prepare_decision()
            return
        else:
            raise ExecutionStateError("Unknown task reconciliation reason")
        if c.machine.phase != Phase.OBSERVING:
            c.machine.transition(Phase.OBSERVING)

    def prepare_decision(self) -> None:
        c = self.c
        if instruction_correction_pending():
            self.apply_pending_correction()
            if c.machine.phase != Phase.OBSERVING:
                c.machine.transition(Phase.OBSERVING)
            return
        if self.defer_for_evidence():
            c.machine.transition(Phase.OBSERVING)
            return
        status = effective_decision_status(c.decision)
        if status == "needs_user":
            if self.defer_for_dependencies():
                c.machine.transition(Phase.OBSERVING)
                return
            c.input_target = decision_user_input_target(c.decision)
            c.machine.transition(Phase.WAITING_INPUT, secure_target=True, preflight=True)
            return
        if status == "needs_choice":
            self.begin_target_choice()
            c.machine.transition(Phase.WAITING_CHOICE, decision=True, preflight=True)
            return
        if status == "blocked":
            reason = str(c.decision.get("reason") or c.decision.get("summary") or "OpenClaw is blocked")
            if re.search(r"credential|password|verification code|permission denied|not authorized|cancelled|destructive|irreversible", reason, re.I):
                raise RuntimeError(reason)
            launch = blocked_recovery_action(c.task, c.observation, c.history)
            if launch:
                c.decision = {"status": "act", "action": launch, "summary": "Opening the requested installed app"}
                status = "act"
            elif c.blocked_recoveries < 1:
                c.blocked_recoveries += 1
                c.history.append({"step": c.step, "action": "blocked_recovery", "result": {
                    "message": "Reconsider on a fresh screen: check app launch, visible coordinate targets, menus, and prior rejection codes before declaring this task blocked.",
                    "previous_reason": reason}})
                c.machine.transition(Phase.OBSERVING)
                return
            else: raise RuntimeError(reason)
        if status == "done":
            publish_task_wait("verifying", "Checking the requested results",
                              operation_key=f"completion:{c.step}", ledger=c.ledger)
            c.machine.transition(Phase.VERIFYING, decision=True)
            return
        if status != "act":
            raise RuntimeError("OpenClaw returned neither an action, completion, nor a blocker")
        c.action = normalized_action(c.decision.get("action"))
        action_type = str(c.action["type"])
        signature = action_identity(c.action, c.observation)
        c.recovered_result = c.recovery.check(c.action, c.observation)
        if c.recovered_result and c.recovered_result["outcome"] == "suppressed":
            c.history.append({"step": c.step, "action": "repeat_suppressed", "result": c.recovered_result})
            c.machine.transition(Phase.OBSERVING)
            return
        target_pid = action_target_pid(c.action, c.observation)
        if action_type in {"press", "focus", "set_value", "type_text", "click", "double_click", "key", "scroll"} and target_pid is not None and observation_is_loading(c.observation, target_pid):
            c.loading_pid, c.loading_waits = target_pid, 1
            c.pending_observation, settling = wait_for_screen_change(c.display_id, c.observation,
                c.action, c.screenshot_digest, timeout=5.0, target_pid=target_pid)
            c.history.append({"step": c.step, "action": {"type": "wait", "seconds": 5},
                "result": {"message": "Discarded the busy-target action and waited locally; select a fresh target",
                           "recovery": "wait_for_loading", "settling": settling}})
            c.machine.transition(Phase.OBSERVING)
            return
        if action_type == "wait": c.identical_action_count = 0
        elif signature == c.last_action_signature and c.screenshot_digest == c.last_screen_digest:
            c.identical_action_count += 1
        else: c.identical_action_count = 1
        c.last_action_signature, c.last_screen_digest = signature, c.screenshot_digest
        if c.identical_action_count > MAX_IDENTICAL_ACTIONS:
            raise RuntimeError(f"OpenClaw repeated the same desktop action on an unchanged screen; {PRODUCT_NAME} stopped the loop safely")
        if c.stop_boundaries and c.observation is not None:
            try:
                validate_action_against_boundaries(c.action, c.observation, c.stop_boundaries)
            except BoundaryViolation as error:
                failure = {"message": str(error), "outcome": "rejected", "error_code": error.code,
                           "recovery": action_failure_recovery(error.code)}
                c.consecutive_action_failures += 1
                c.recovery.rejected(c.action, c.observation, error.code)
                c.recovery_cycles.record(c.action, c.observation, failure, c.ledger, c.screenshot_digest)
                record_action_diagnostic(c.action, failure)
                c.history.append({"step": c.step, "action": c.action, "result": failure,
                    **action_history_context(c.decision, c.action, c.observation),
                    "completed_requirements": c.decision.get("completed_requirements") or [],
                    "remaining_requirements": c.decision.get("remaining_requirements") or []})
                publish_task_progress(c.ledger, active_requirement_ids=[])
                emit("status", message="Rechecking the target and continuing with safe preparation…")
                c.machine.transition(Phase.OBSERVING)
                c.reconcile_reason = "stop_boundary"
                return
        if not c.recovered_result and action_type not in {"wait", "none"}:
            if self.defer_for_dependencies():
                c.machine.transition(Phase.OBSERVING)
                return
            rejection = c.recovery_cycles.check(c.action, c.observation, c.ledger, c.screenshot_digest)
            c.router.metrics.update(recovery_cycles=c.recovery_cycles.detections, cycle_suppressions=c.recovery_cycles.suppressions)
            if rejection:
                c.history.append({"step": c.step, "action": c.action, "result": rejection})
                record_action_diagnostic(c.action, rejection)
                emit("status", message="Reconsidering the recovery strategy after repeated states…")
                c.machine.transition(Phase.OBSERVING)
                return
        publish_task_wait("executing", expected_wait_description(c.decision),
                          operation_key=f"action:{c.step}:{action_type}", ledger=c.ledger)
        c.machine.transition(Phase.EXECUTING, decision=True, preflight=True)

    def begin_target_choice(self) -> None:
        c = self.c
        choice = c.decision.get("choice")
        if not isinstance(choice, dict):
            raise RuntimeError("A target choice is missing its validated request")
        candidates = grounded_candidates(c.observation or {}, c.ledger)
        by_id = {candidate["id"]: candidate for candidate in candidates}
        identifiers = choice.get("candidate_ids")
        selected = [by_id.get(identifier) for identifier in identifiers] if isinstance(identifiers, list) else []
        if len(selected) < 2 or len(selected) > 8 or any(candidate is None for candidate in selected):
            raise RuntimeError("The target candidates changed before TaskPilot could ask you to choose")
        compatible_kinds = {"document"} if choice["scope"] == "document" else {"file", "folder"}
        # Inspection is bounded per unchanged ambiguity, not per model-selected
        # subset. A model cannot evade the one-inspection limit by returning a
        # different subset of the same native candidates on its next decision.
        fingerprint = candidate_fingerprint(
            choice["reference"], choice["scope"],
            [candidate for candidate in candidates if candidate["kind"] in compatible_kinds],
        )
        request_id = str(uuid.uuid4()).lower()
        key = runtime_inbox().register_target_choice(request_id, c.generation)
        c.target_choice_key = key
        c.target_choice_fingerprint = fingerprint
        c.pending_target_choice = {
            "request_id": request_id, "instruction_revision": c.instruction_revision,
            "working_document_revision": c.working_document_revision,
            "binding_revision": c.target_binding_revision + 1,
            "reference": choice["reference"], "requirement_id": choice["requirement_id"],
            "scope": choice["scope"], "candidate_ids": list(identifiers),
            "candidate_map": {candidate["id"]: candidate for candidate in selected},
            "fingerprint": fingerprint,
        }
        publish_task_wait("reconciling", "Choose which target to use",
                          operation_key=f"target-choice:{request_id}", ledger=c.ledger)
        emit("status", message=f"Waiting for you to choose: {choice['reference']}")
        emit("target_choice_required", version=TARGET_CHOICE_PROTOCOL_VERSION,
             request_id=request_id, instruction_revision=c.instruction_revision,
             working_document_revision=c.working_document_revision,
             binding_revision=c.target_binding_revision + 1, reference=choice["reference"],
             requirement_id=choice["requirement_id"], scope=choice["scope"],
             candidates=public_candidates(candidates, identifiers),
             inspect_again_allowed=fingerprint not in c.target_choice_inspections)

    def resolve_target_choice(self) -> None:
        c = self.c
        pending = c.pending_target_choice
        if not isinstance(pending, dict):
            raise RuntimeError("TaskPilot entered target-choice wait without an owned request")
        publish_task_wait("reconciling", "Waiting for your target choice",
                          operation_key=f"target-choice:{pending['request_id']}", ledger=c.ledger)
        while True:
            if instruction_correction_pending():
                control = receive_pending_task_control(timeout=0)
                c.pending_target_choice = None
                runtime_inbox().clear_target_choice()
                if control.get("control_kind") == "working_document_update":
                    self.apply_working_document_update(control)
                else:
                    c.pending_task_control = control
                    self.apply_pending_correction()
                return
            try:
                response = receive_target_choice_response(timeout=0.25)
                break
            except TimeoutError:
                continue
        if response["inspect_again"]:
            c.target_choice_inspections.add(pending["fingerprint"])
            c.pending_target_choice = None
            c.target_choice_fingerprint = ""
            runtime_inbox().clear_target_choice()
            c.decision = None
            c.machine.transition(Phase.OBSERVING)
            return

        candidate_id = response["candidate_id"]
        candidate = pending["candidate_map"][candidate_id]
        result = bridge_call(
            "bind_task_target_choice", c.display_id,
            protocol_version=TARGET_CHOICE_PROTOCOL_VERSION,
            choice_id=pending["request_id"], candidate_id=candidate_id,
            binding_revision=pending["binding_revision"], scope=pending["scope"],
            reference=pending["reference"], requirement_id=pending["requirement_id"],
            label=candidate["label"], detail=candidate["detail"],
            candidate=candidate["binding"],
        )
        if result.get("applied") is not True:
            emit("target_choice_rejected", version=TARGET_CHOICE_PROTOCOL_VERSION,
                 request_id=pending["request_id"],
                 instruction_revision=pending["instruction_revision"],
                 working_document_revision=pending["working_document_revision"],
                 binding_revision=pending["binding_revision"],
                 message="That target changed before it could be selected. Inspect again or choose another candidate.")
            c.pending_target_choice = None
            c.target_choice_fingerprint = ""
            runtime_inbox().clear_target_choice()
            c.decision = None
            c.machine.transition(Phase.OBSERVING)
            return

        binding = {
            "reference": pending["reference"], "requirement_id": pending["requirement_id"],
            "scope": pending["scope"], "candidate_id": candidate_id,
            "label": candidate["label"], "detail": candidate["detail"],
            "kind": candidate["kind"], "binding": candidate["binding"],
            "binding_revision": pending["binding_revision"],
        }
        c.target_bindings = [item for item in c.target_bindings
                             if not (item.get("reference") == binding["reference"] and
                                     item.get("scope") == binding["scope"] and
                                     item.get("requirement_id") == binding["requirement_id"])]
        c.target_bindings.append(binding)
        c.target_binding_revision = pending["binding_revision"]
        if candidate["kind"] == "document":
            c.working_document = result.get("working_document")
            c.working_document_revision = int((c.working_document or {}).get("revision", c.working_document_revision))
        emit("target_choice_applied", version=TARGET_CHOICE_PROTOCOL_VERSION,
             request_id=pending["request_id"], instruction_revision=c.instruction_revision,
             working_document_revision=c.working_document_revision,
             candidate_id=candidate_id, binding_revision=pending["binding_revision"],
             label=candidate["label"], detail=candidate["detail"],
             **({"working_document": c.working_document} if candidate["kind"] == "document" else {}))
        c.pending_target_choice = None
        c.target_choice_fingerprint = ""
        runtime_inbox().clear_target_choice()
        c.decision = c.action = c.result = None
        if c.client is not None:
            c.client.decision_cache = {}
        c.bridge_observation_revision = None
        c.machine.transition(Phase.OBSERVING)

    def secure_input(self) -> None:
        c = self.c
        publish_task_wait("secure_input", "Secure input in TaskPilot", attention="secure_input",
                          operation_key=f"secure-input:{c.step}", ledger=c.ledger)
        emit("status", message=f"{PRODUCT_NAME} paused because the waiting app needs secure input…")
        c.ledger.before_action({"type": "type_text"})
        try:
            result = request_and_enter_user_input(c.input_target, c.display_id)
        except InstructionSuperseded:
            c.reconcile_reason = "correction"
            c.machine.reconcile()
            return
        except ActionRejected as error:
            if error.code != 'runtime_recovering' or error.details.get('outcome') != 'rejected': raise
            c.machine.transition(Phase.RECOVERING)
            managed_openclaw.wait_for_health(Path(os.environ['TASKPILOT_MANAGED_DESCRIPTOR']),
                status=lambda text: emit('status', message=text))
            refresh_managed_descriptor()
            c.machine.transition(Phase.RECONCILING, recovered=True)
            c.reconcile_reason = 'secure_settle'  # Refresh target; never retain/replay the secret.
            return
        decision = c.decision or {}
        c.history.append({"step": c.step, "action": "user_input_entered", "result": result,
            "completed_requirements": decision.get("completed_requirements") or [],
            "remaining_requirements": decision.get("remaining_requirements") or []})
        c.reconcile_reason = "secure_settle"
        c.machine.reconcile()

    def execute(self) -> None:
        c = self.c
        descriptor_path = os.environ.get('TASKPILOT_MANAGED_DESCRIPTOR')
        if descriptor_path:
            c.machine.transition(Phase.RECOVERING)
            publish_task_wait('reconciling', 'Checking private Gateway connectivity',
                              operation_key=f'gateway-preflight:{c.step}', ledger=c.ledger)
            managed_openclaw.wait_for_health(Path(descriptor_path), status=lambda text: emit('status', message=text))
            refresh_managed_descriptor()
            c.machine.transition(Phase.EXECUTING, recovered=True)
            if instruction_correction_pending():
                c.machine.reconcile(); c.reconcile_reason = 'correction'; return
        seconds = 30.0 + (float(c.action.get('timeout_seconds', action_default('run_command', 'timeout_seconds')))
                          if c.action.get('type') == 'run_command' else 0)
        c.local_budget = LocalBudget(seconds, 'action_preparation', cancelled=lambda: c.machine.phase in {Phase.DRAINING, Phase.FINISHED})
        with local_scope(seconds, 'action_preparation', budget=c.local_budget):
            self.execute_local()

    def execute_local(self) -> None:
        c = self.c
        action_type = str(c.action["type"])
        if c.recovered_result:
            c.result = c.recovered_result
            c.consecutive_action_failures = c.consecutive_evidence_conflicts = 0
        elif action_type == "wait":
            c.machine.reconcile()
            seconds = float(c.action.get("seconds", action_default("wait", "seconds")))
            c.pending_observation, settling = wait_for_screen_change(c.display_id, c.observation, c.action,
                                                                     c.screenshot_digest, timeout=seconds)
            c.result = {"message": "Observed locally while waiting", "settling": settling}
        elif action_type == "none":
            c.result = "No action was performed"
        else:
            try:
                command_params = inspect_general_command(c.action, c.display_id, c.observation)
                c.ledger.before_action(c.action)
                publish_task_progress(c.ledger)
                publish_action_destination(c.action, c.task, c.observation, c.step)
                result = bridge_call("act", c.display_id, action=c.action, **command_params)
            except InstructionSuperseded:
                c.machine.reconcile()
                c.reconcile_reason = "correction"
                return
            except RuntimeError as error:
                if not isinstance(error, ActionRejected) or error.code in {"cancelled", "permission_denied", "protected_target", "secure_input"}:
                    raise
                if error.code == 'runtime_recovering' and error.details.get('outcome') == 'rejected':
                    c.machine.transition(Phase.RECOVERING)
                    managed_openclaw.wait_for_health(Path(os.environ['TASKPILOT_MANAGED_DESCRIPTOR']),
                        status=lambda text: emit('status', message=text))
                    refresh_managed_descriptor()
                    c.machine.transition(Phase.RECONCILING, recovered=True)
                    c.reconcile_reason = 'failure'
                    c.failure = {'message':'Private runtime recovered; inspect before proceeding',
                                 'outcome':'rejected', 'error_code':'runtime_recovering', 'recovery':'fresh_observation'}
                    return
                self.action_rejected(error)
                return
            publish_action_destination(c.action, c.task, c.observation, c.step, delivered=True)
            c.consecutive_action_failures = c.consecutive_evidence_conflicts = 0
            c.action = bind_command_outcomes(c.action, result)
            c.evidence_guard.remember_native(c.action, c.observation, result)
            c.ledger.record_action(c.action, result)
            publish_task_progress(c.ledger)
            c.result = result
            c.router.metrics["action_deliveries"] += 1
            c.reconcile_reason = "effect"
            c.machine.reconcile()
            return
        c.machine.reconcile()
        self.record_result()

    def action_rejected(self, error: ActionRejected) -> None:
        c = self.c
        c.machine.reconcile()
        c.consecutive_action_failures += 1
        uncertain = error.code == "delivery_uncertain" or error.details.get("outcome") == "delivered_unconfirmed"
        code = "delivery_uncertain" if uncertain else error.code
        c.router.metrics["action_rejections"] += 1
        c.failure = {"message": str(error), "outcome": "delivered_unconfirmed" if uncertain else "rejected",
                     "error_code": error.code, "recovery": action_failure_recovery(code), **error.details}
        if uncertain:
            mark_continuation_receipt_uncertain(c.action)
        publisher = current_task.get().destination_publisher if current_task.get() else None
        if not uncertain and publisher and publisher.current and publisher.current.get("state") == "preparing":
            publish_planned_destination(c.ledger)
        c.recovery.rejected(c.action, c.observation, code)
        c.recovery_cycles.record(c.action, c.observation, c.failure, c.ledger, c.screenshot_digest)
        record_action_diagnostic(c.action, c.failure)
        publish_task_progress(c.ledger, active_requirement_ids=[])
        if uncertain: c.router.metrics["unconfirmed_actions"] += 1
        c.history.append({"step": c.step, "visual_evidence": str(c.decision.get("visual_evidence") or ""),
            "action": c.action, "result": c.failure, **action_history_context(c.decision, c.action, c.observation),
            "completed_requirements": c.decision.get("completed_requirements") or [],
            "remaining_requirements": c.decision.get("remaining_requirements") or []})
        if c.consecutive_action_failures >= 3:
            raise RuntimeError("OpenClaw could not produce a valid action after three fresh screen checks") from error
        c.reconcile_reason = "failure"

    @local_operation(5.0, 'failure_inspection')
    def reconcile_failure(self) -> None:
        c = self.c
        c.pending_observation = bridge_call("observe", c.display_id)
        target_pid = action_target_pid(c.action, c.observation)
        uncertain = c.failure["outcome"] == "delivered_unconfirmed"
        if target_pid is not None and (uncertain or observation_is_loading(c.pending_observation, target_pid)):
            fresh, c.pending_observation = c.pending_observation, None
            try:
                c.pending_observation, settling = wait_for_screen_change(c.display_id, fresh, c.action,
                    timeout=5.0 if observation_is_loading(fresh, target_pid) else 2.0, target_pid=target_pid)
                c.failure["settling"] = settling
            finally:
                discard_observation_image(fresh)
            if observation_is_loading(c.pending_observation, target_pid):
                c.loading_pid, c.loading_waits = target_pid, 1
        c.presentation_action_id = None
        emit("status", message="Checking fresh evidence and the action failure before continuing…")

    def record_result(self) -> None:
        c = self.c
        if isinstance(c.result, dict):
            expected_effect = c.result.get("expected_effect")
            uncertain_effect = (c.result.get("outcome") == "delivered_unconfirmed" or
                                isinstance(expected_effect, dict) and expected_effect.get("outcome") == "delivered_unconfirmed")
            if uncertain_effect:
                mark_continuation_receipt_uncertain(c.action)
        c.history.append({"step": c.step, "visual_evidence": str(c.decision.get("visual_evidence") or ""),
            "action": c.action, "result": c.result, **action_history_context(c.decision, c.action, c.observation),
            "completed_requirements": c.decision.get("completed_requirements") or [],
            "remaining_requirements": c.decision.get("remaining_requirements") or []})
        if isinstance(c.result, dict):
            effect = c.result.get("expected_effect", {})
            if effect.get("outcome") == "verified" and effect.get("check") in FILE_EFFECTS:
                c.ledger.record_effect(c.decision["expected_result"], effect["evidence"], c.action)
                publish_task_progress(c.ledger)
            if not c.recovered_result:
                c.recovery_cycles.record(c.action, c.observation, c.result, c.ledger, c.screenshot_digest)
        c.presentation_action_id = None
        publish_task_progress(c.ledger, active_requirement_ids=[])
        if (c.decision.get("finish_after_action") is True and c.action["type"] in {"write_file", "run_command"}
                and isinstance(c.result, dict) and c.result.get("verification_scope") != "expected_effect_unconfirmed"):
            discard_observation_image(c.pending_observation)
            c.pending_observation = None
            c.machine.transition(Phase.VERIFYING, decision=True)
        else:
            c.machine.transition(Phase.OBSERVING)

    def verify(self) -> None:
        c = self.c
        publish_task_wait("verifying", "Checking the requested results",
                          operation_key=f"completion:{c.step}", ledger=c.ledger)
        try:
            completed = verify_task_completion(c.task, c.decision, c.display_id, c.history, c.router, c.client, c.ledger, c.evidence_guard)
        except InstructionSuperseded:
            c.machine.transition(Phase.OBSERVING)
            return
        if completed:
            c.machine.drain()
        else:
            # A failed audit is a request to reconsider the current task state,
            # not a reason to ask the same completion question repeatedly.
            c.machine.transition(Phase.OBSERVING)
            return

    def apply_pending_correction(self) -> None:
        c = self.c
        control = receive_pending_task_control()
        if control.get("control_kind") == "working_document_update":
            self.apply_working_document_update(control)
            return
        correction = control
        if correction.get("duplicate") is True:
            return
        request = correction["request"]
        references = list(c.exact_input_references)
        amendment = correction.get("role_amendment")
        if amendment is not None:
            matches = []
            for index, reference in enumerate(references):
                kind, start, length, value = reference.get("kind"), reference.get("utf8_start"), reference.get("utf8_length"), reference.get("value")
                if (f"{start}:{length}:{kind}" == amendment["occurrence_id"] and kind == amendment["kind"] and
                        start == amendment["utf8_start"] and length == amendment["utf8_length"] and
                        value == amendment["value"]):
                    matches.append(index)
            if len(matches) != 1:
                raise RuntimeError("The exact input occurrence changed before its role correction could be applied")
            updated = dict(references[matches[0]])
            updated["version"] = EXACT_INPUT_REFERENCE_VERSION
            if amendment["role"] is None:
                updated.pop("role_override", None)
            else:
                updated["role_override"] = amendment["role"]
            references[matches[0]] = updated
        revised_task = c.task
        if request or correction["exact_input_references"]:
            header = "\n\nUser correction: "
            source_start = len(c.task.encode("utf-8")) + len(header.encode("utf-8"))
            for reference in correction["exact_input_references"]:
                references.append({**reference, "utf8_start": source_start + reference["utf8_start"]})
            revised_task = c.task + header + request
        if len(references) > 128:
            raise RuntimeError("The correction exceeds the task’s limit of 128 exact inputs")
        TaskInputBindings(revised_task, exact_input_references=references)
        c.task = revised_task
        c.exact_input_references = references
        global _exact_input_references
        _exact_input_references = references
        c.target_bindings.clear()
        c.stop_boundaries = detect_stop_boundaries(revised_task, references)
        c.instruction_revision = correction["revision"]
        global _instruction_revision
        _instruction_revision = correction["revision"]
        c.instruction_corrections.append(correction)
        c.ledger.apply_instruction_revision(revised_task, references)
        publish_task_input_roles(c.ledger)
        publish_planned_destination(c.ledger)
        c.observation_keywords = sorted(w for w in words(revised_task) if len(w) <= 64 and w.isalnum())[:48]
        c.bridge_observation_revision = None
        c.command_hints_inspected = False
        c.decision = c.action = c.result = c.recovered_result = c.input_target = c.failure = None
        if c.client is not None: c.client.decision_cache = {}
        c.recovery = ActionRecovery()
        c.recovery_cycles = RecoveryCycles(rejection_limit=MAX_IDENTICAL_ACTIONS)
        c.evidence_guard = EvidenceConsistency()
        c.identical_action_count = 0
        c.last_action_signature = c.last_screen_digest = ""
        discard_observation_image(c.pending_observation)
        discard_observation_image(c.observation)
        c.pending_observation = c.observation = None
        c.screenshot_path = None
        c.screenshot_digest = ""
        c.reconcile_reason = ""
        emit("instruction_correction_applied", correction_id=correction["id"],
             instruction_revision=correction["revision"])
        if c.history and isinstance(c.history[-1].get("result"), dict) and c.history[-1]["result"].get("error_code") == "evidence_conflict":
            c.consecutive_evidence_conflicts += 1
            if c.consecutive_evidence_conflicts >= 3:
                raise RuntimeError("TaskPilot could not reconcile completion evidence after three fresh decisions; completion remains unconfirmed")
        if c.machine.phase != Phase.OBSERVING:
            c.machine.transition(Phase.OBSERVING)

    def apply_working_document_update(self, update: dict[str, Any], *, preserve_secure_input: bool = False) -> bool:
        c = self.c
        if update.get("control_kind") != "working_document_update":
            raise RuntimeError("Invalid working-document update")
        result = bridge_call(
            "bind_working_document", c.display_id,
            update_id=update["id"], binding_revision=update["revision"],
            selection_id=update.get("selection_id"),
            selection_scope_id=update.get("selection_scope_id"),
            remove_selection_limit=update.get("remove_selection_limit", False),
            _working_document_revision=update["revision"],
        )
        if result.get("applied") is not True:
            emit("working_document_update_rejected", update_id=update["id"],
                 binding_revision=update["revision"],
                 message="The document or selected region changed before it could be bound. Choose it again in Live View.")
            if not preserve_secure_input and c.machine.phase != Phase.OBSERVING:
                c.machine.transition(Phase.OBSERVING)
            return False
        binding = result.get("working_document")
        if update.get("selection_id") is not None or update.get("remove_selection_limit") is True:
            if not isinstance(binding, dict) or binding.get("state") != "active" or type(binding.get("revision")) is not int or binding["revision"] != update["revision"]:
                raise NativeProtocolError("The native working-document acknowledgement is malformed")
        if binding is not None:
            if (not isinstance(binding, dict) or binding.get("state") != "active" or
                    type(binding.get("revision")) is not int or binding["revision"] != update["revision"] or
                    not isinstance(binding.get("application"), str) or not isinstance(binding.get("title"), str)):
                raise NativeProtocolError("The native working-document acknowledgement is malformed")
            description = binding.get("selection_description")
            state = binding.get("selection_state")
            if description is not None and (not isinstance(description, str) or not description or len(description.encode("utf-8")) > 512 or
                                            state not in {"active", "needs_reselection"}):
                raise NativeProtocolError("The native working-selection acknowledgement is malformed")
            if description is None and state is not None:
                raise NativeProtocolError("The native working-selection acknowledgement is inconsistent")
            if update.get("selection_scope_id") is not None and description is None:
                raise NativeProtocolError("The native working-selection acknowledgement omitted the selected region")
            if update.get("remove_selection_limit") is True and description is not None:
                raise NativeProtocolError("The native working-selection removal was not acknowledged")
        c.working_document_revision = update["revision"]
        c.target_bindings = [binding for binding in c.target_bindings
                             if binding.get("scope") != "document"]
        global _working_document_revision
        _working_document_revision = update["revision"]
        c.working_document = binding
        c.ledger.apply_working_document_revision()
        publish_planned_destination(c.ledger)
        c.bridge_observation_revision = None
        c.action = c.result = c.recovered_result = c.failure = None
        if not preserve_secure_input:
            c.decision = c.input_target = None
        if c.client is not None:
            c.client.decision_cache = {}
        c.recovery = ActionRecovery()
        c.recovery_cycles = RecoveryCycles(rejection_limit=MAX_IDENTICAL_ACTIONS)
        c.evidence_guard = EvidenceConsistency()
        c.identical_action_count = 0
        c.last_action_signature = c.last_screen_digest = ""
        if not preserve_secure_input:
            discard_observation_image(c.pending_observation)
            discard_observation_image(c.observation)
            c.pending_observation = c.observation = None
            c.screenshot_path = None
            c.screenshot_digest = ""
        c.reconcile_reason = ""
        presentation = ({key: binding[key] for key in ("state", "application", "title", "location", "revision", "selection_state", "selection_description") if key in binding}
                        if isinstance(binding, dict) else None)
        emit("working_document_applied", update_id=update["id"], binding_revision=update["revision"],
             working_document=presentation)
        if not preserve_secure_input and c.machine.phase != Phase.OBSERVING:
            c.machine.transition(Phase.OBSERVING)
        return True


def _stop_handler(_signal_number: int, _frame: Any) -> None:
    context = current_task.get()
    if context is not None: context.machine.drain()
    if _task_value("active_acp_process") is not None and _task_value("active_acp_process").poll() is None:
        _task_value("active_acp_process").terminate()
    raise SystemExit(143)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=f"{PRODUCT_NAME} OpenClaw runtime")
    parser.add_argument("--managed-openclaw", choices=("ensure", "relocate", "rollback", "audit", "repair"))
    parser.add_argument("--managed-resources")
    parser.add_argument("--managed-descriptor")
    parser.add_argument("--force-integrity-audit", action="store_true")
    parser.add_argument("--managed-acp-probe", action="store_true")
    parser.add_argument("--configuration-command", nargs=argparse.REMAINDER)
    parser.add_argument("--task")
    parser.add_argument("--display-id", type=int)
    parser.add_argument("--openclaw-path")
    parser.add_argument("--check-models", action="store_true")
    parser.add_argument("--read-readiness", action="store_true")
    return parser.parse_args()


def read_runtime_configuration(require_generation: bool = False) -> str:
    global _task_generation_id, _instruction_revision, _bridge_observation_revision, _observation_keywords, _exact_input_references, _instruction_correction_key, _working_document_revision, _working_document_update_key, _continuation_checkpoint, _target_choice_protocol_version
    _task_generation_id = None
    _instruction_revision = 0
    _bridge_observation_revision = None
    _observation_keywords = []
    _exact_input_references = []
    _instruction_correction_key = None
    _working_document_revision = 0
    _working_document_update_key = None
    _target_choice_protocol_version = 0
    _continuation_checkpoint = None
    raw_line = runtime_line()
    try:
        configuration = json.loads(raw_line)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{PRODUCT_NAME} did not provide the secure runtime configuration") from error
    if not isinstance(configuration, dict) or configuration.get("kind") != "runtime_configuration":
        raise RuntimeError(f"{PRODUCT_NAME} did not provide the secure runtime configuration")
    if configuration.get("action_contract_hash") != CONTRACT_HASH or type(configuration.get("action_contract_version")) is not int or configuration.get("action_contract_version") != CONTRACT_VERSION:
        raise RuntimeError("TaskPilot backend action contracts do not match; rebuild the bundled app and runtime together")
    generation = configuration.get("task_generation_id")
    if require_generation:
        try:
            if not isinstance(generation, str) or str(uuid.UUID(generation)).lower() != generation.lower():
                raise ValueError("Invalid generation")
        except (ValueError, AttributeError):
            raise RuntimeError("TaskPilot did not provide a valid task generation ID")
        _task_generation_id = generation
        if type(configuration.get("instruction_revision")) is not int or configuration["instruction_revision"] != 0:
            raise RuntimeError("TaskPilot instruction revision protocol does not match; rebuild the bundled components together")
        _instruction_revision = configuration["instruction_revision"]
        if type(configuration.get("task_protocol_version")) is not int or configuration["task_protocol_version"] != TASK_PROTOCOL_VERSION:
            raise RuntimeError("TaskPilot task ownership protocol does not match; rebuild the bundled components together")
        if type(configuration.get("stop_boundary_policy_version")) is not int or configuration["stop_boundary_policy_version"] != STOP_BOUNDARY_POLICY_VERSION:
            raise RuntimeError("TaskPilot stop-before boundary policies do not match; rebuild the bundled components together")
        if type(configuration.get("coordinate_mapping_version")) is not int or configuration["coordinate_mapping_version"] != COORDINATE_MAPPING_VERSION:
            raise RuntimeError("TaskPilot screen coordinate mapping versions do not match; rebuild the bundled components together")
        if type(configuration.get("observation_completeness_version")) is not int or configuration["observation_completeness_version"] != OBSERVATION_COMPLETENESS_VERSION:
            raise RuntimeError("TaskPilot observation completeness versions do not match; rebuild the bundled components together")
        if type(configuration.get("text_recognition_version")) is not int or configuration["text_recognition_version"] != TEXT_RECOGNITION_VERSION:
            raise RuntimeError("TaskPilot text recognition versions do not match; rebuild the bundled components together")
        if type(configuration.get("evidence_consistency_version")) is not int or configuration["evidence_consistency_version"] != EVIDENCE_CONSISTENCY_VERSION:
            raise RuntimeError("TaskPilot evidence inspection versions do not match; rebuild the bundled components together")
        if type(configuration.get("wait_presentation_version")) is not int or configuration["wait_presentation_version"] != WAIT_PRESENTATION_VERSION:
            raise RuntimeError("TaskPilot wait presentation versions do not match; rebuild the bundled components together")
        if type(configuration.get('command_capability_version')) is not int or configuration['command_capability_version'] != COMMAND_CAPABILITY_VERSION:
            raise RuntimeError('TaskPilot command inspection versions do not match; rebuild the bundled components together')
        if type(configuration.get("exact_input_reference_version")) is not int or configuration["exact_input_reference_version"] != EXACT_INPUT_REFERENCE_VERSION:
            raise RuntimeError("TaskPilot exact-input reference versions do not match; rebuild the bundled components together")
        if (type(configuration.get("continuation_checkpoint_version")) is not int or
                configuration["continuation_checkpoint_version"] != CONTINUATION_CHECKPOINT_VERSION):
            raise RuntimeError("TaskPilot continuation checkpoint protocol does not match; rebuild the bundled components together")
        continuation = configuration.get("continuation_checkpoint")
        if continuation is not None:
            if (not isinstance(continuation, dict) or continuation.get("eligible") is not True or
                    continuation.get("version") != CONTINUATION_CHECKPOINT_VERSION or
                    type(continuation.get("instruction_revision")) is not int or
                    type(continuation.get("revision")) is not int or
                    not isinstance(continuation.get("task_sha256"), str) or
                    not re.fullmatch(r"[0-9a-f]{64}", continuation["task_sha256"])):
                raise RuntimeError("TaskPilot provided a stale or malformed continuation checkpoint")
            _continuation_checkpoint = continuation
        references = configuration.get("exact_input_references")
        if type(references) is not list or len(references) > 128:
            raise RuntimeError("TaskPilot provided invalid exact-input reference metadata")
        _exact_input_references = references
        if type(configuration.get("working_document_protocol_version")) is not int or configuration["working_document_protocol_version"] != WORKING_DOCUMENT_PROTOCOL_VERSION:
            raise RuntimeError("TaskPilot working-document protocol does not match; rebuild the bundled components together")
        if type(configuration.get("target_choice_protocol_version")) is not int or configuration["target_choice_protocol_version"] != TARGET_CHOICE_PROTOCOL_VERSION:
            raise RuntimeError("TaskPilot target-choice protocol does not match; rebuild the bundled components together")
        _target_choice_protocol_version = TARGET_CHOICE_PROTOCOL_VERSION
        _instruction_correction_key = runtime_inbox().register_instruction_corrections(generation)
        _working_document_update_key = runtime_inbox().register_working_document_updates(generation)
    api_key = configuration.get("gemini_api_key")
    if not isinstance(api_key, str):
        raise RuntimeError(f"{PRODUCT_NAME} did not provide the secure runtime configuration")
    if api_key.strip() and len(api_key.strip()) < 20:
        raise RuntimeError(
            f"Add and save a complete Gemini API key in {PRODUCT_NAME} Settings before running a task."
        )
    return api_key.strip()


def main() -> int:
    try:
        # Native task launches establish this before exec. Standalone/readiness
        # launches must establish it explicitly, never silently lose ownership.
        if os.getpgrp() != os.getpid():
            os.setpgrp()
        if os.getpgrp() != os.getpid():
            raise OSError("process group was not established")
    except OSError as error:
        sys.stderr.write(f"TaskPilot process-group setup failed ({error.errno})\n")
        return 1
    signal.signal(signal.SIGTERM, _stop_handler)
    signal.signal(signal.SIGINT, _stop_handler)
    args = parse_args()
    try:
        if args.managed_openclaw:
            return managed_openclaw.command(args.managed_openclaw, args.managed_resources,
                                            args.managed_descriptor, force_integrity=args.force_integrity_audit)
        if args.managed_descriptor:
            managed_openclaw.activate_environment(Path(args.managed_descriptor))
        if args.managed_acp_probe:
            try:
                client = ACPClient(find_openclaw(args.openclaw_path))
                client.close()
                print(json.dumps({'ok':True, 'method':client.connection_method}))
                return 0
            except Exception as error:
                print(json.dumps({'ok':False, 'cause':managed_openclaw.handshake_cause(error)}))
                return 1
        if args.configuration_command:
            with configuration_transaction() as lease:
                # Descendants retain the lease if the wrapper exits first.
                return subprocess.call(args.configuration_command, stdin=subprocess.DEVNULL, pass_fds=(lease,))
        api_key = read_runtime_configuration(require_generation=args.task is not None)
        if args.check_models or args.read_readiness:
            return 0 if check_models(find_openclaw(args.openclaw_path), api_key, read_only=args.read_readiness) else 1
        if args.task is None or args.display_id is None:
            raise RuntimeError("TaskPilot requires a task and target display")
        emit("runtime_ready", memory_pressure_version=1)
        run_task(args.task, args.display_id, args.openclaw_path, api_key)
        return 0
    except KeyboardInterrupt:
        return 130
    except Exception as error:
        failure = classify_failure(error, time.time())
        fields = failure.metadata()
        if isinstance(error, RecoveryExhaustedError):
            fields["model_failures"] = [{"model": model, **f.metadata()} for model, f in error.failures]
        message = failure.summary() if isinstance(error, ProviderRequestError) else str(error)
        emit("error", message=message, **fields)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
