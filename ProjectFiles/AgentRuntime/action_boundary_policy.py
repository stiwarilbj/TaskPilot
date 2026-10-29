"""Ordered, typed action-boundary policy decisions shared with Swift.

This module does not own individual safety rules. It makes their ordering and
the outcome vocabulary explicit so Python preflight and native delivery cannot
silently disagree about whether a failed check means reject or refresh.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

NATIVE_ACTION_POLICY_VERSION = 1
STAGE_ORDER = (
    "ownership", "instruction_revision", "working_document_revision",
    "stop_before", "target_choice", "document_binding", "selection_scope",
    "destination_identity", "resolved_target",
)
DISPOSITIONS = {"allow", "reject", "refresh_evidence"}
REASONS = {
    "none", "task_revoked", "instruction_superseded", "working_document_changed",
    "stop_boundary_rejected", "stop_boundary_uncertain", "target_choice_stale",
    "target_choice_conflict", "selection_scope_changed", "destination_identity_changed",
    "stale_target", "ambiguous_target", "action_policy_rejected", "policy_protocol_error",
}


@dataclass(frozen=True)
class Decision:
    disposition: str
    reason: str

    @property
    def allowed(self) -> bool:
        return self.disposition == "allow"

    def as_dict(self) -> dict[str, str]:
        return {"disposition": self.disposition, "reason": self.reason}


@dataclass(frozen=True)
class Evaluation:
    decision: Decision
    failure: BaseException | None = None


ALLOW = Decision("allow", "none")
PROTOCOL_ERROR = Decision("reject", "policy_protocol_error")


def decision_for_probes(probes: list[dict[str, Any]]) -> Decision:
    """Apply the fixed stage ordering to normalized check outcomes.

    This entry point is also exercised by the shared Swift/Python fixtures.
    Malformed probes fail closed with one fixed reason.
    """
    if not isinstance(probes, list) or len(probes) > 64:
        return PROTOCOL_ERROR
    checked: list[tuple[int, int, Decision]] = []
    for index, probe in enumerate(probes):
        if not isinstance(probe, dict) or set(probe) != {"stage", "disposition", "reason"}:
            return PROTOCOL_ERROR
        stage, disposition, reason = probe["stage"], probe["disposition"], probe["reason"]
        if (not isinstance(stage, str) or stage not in STAGE_ORDER or
                not isinstance(disposition, str) or disposition not in DISPOSITIONS or
                not isinstance(reason, str) or reason not in REASONS or
                (disposition == "allow") != (reason == "none")):
            return PROTOCOL_ERROR
        checked.append((STAGE_ORDER.index(stage), index, Decision(disposition, reason)))
    for _, _, decision in sorted(checked):
        if not decision.allowed:
            return decision
    return ALLOW


def decision_for_failure(error: BaseException, stage: str) -> Decision:
    """Map existing typed policy errors to the shared fixed decision codes."""
    code = getattr(error, "code", None)
    mapped = {
        "stop_boundary_rejected": Decision("reject", "stop_boundary_rejected"),
        "stop_boundary_uncertain": Decision("refresh_evidence", "stop_boundary_uncertain"),
        "target_choice_stale": Decision("refresh_evidence", "target_choice_stale"),
        "instruction_superseded": Decision("refresh_evidence", "instruction_superseded"),
        "working_document_superseded": Decision("refresh_evidence", "working_document_changed"),
        "target_choice_conflict": Decision("reject", "target_choice_conflict"),
        "target_choice_opaque_command": Decision("reject", "target_choice_conflict"),
        "working_document_lost": Decision("refresh_evidence", "working_document_changed"),
        "working_document_target_mismatch": Decision("refresh_evidence", "working_document_changed"),
        "working_selection_lost": Decision("refresh_evidence", "selection_scope_changed"),
        "working_selection_target_mismatch": Decision("refresh_evidence", "selection_scope_changed"),
        "stale_target": Decision("refresh_evidence", "stale_target"),
        "ambiguous_target": Decision("refresh_evidence", "ambiguous_target"),
    }
    if code in mapped:
        return mapped[code]
    fallback = {
        "ownership": "task_revoked",
        "instruction_revision": "instruction_superseded",
        "working_document_revision": "working_document_changed",
        "stop_before": "stop_boundary_uncertain",
        "target_choice": "target_choice_stale",
        "document_binding": "working_document_changed",
        "selection_scope": "selection_scope_changed",
        "destination_identity": "destination_identity_changed",
        "resolved_target": "stale_target",
    }
    if stage not in fallback:
        return PROTOCOL_ERROR
    if isinstance(error, (KeyboardInterrupt, SystemExit)):
        return Decision("reject", "task_revoked")
    reason = fallback[stage]
    disposition = "refresh_evidence" if reason in {
        "instruction_superseded", "working_document_changed", "stop_boundary_uncertain",
        "target_choice_stale", "selection_scope_changed", "destination_identity_changed",
        "stale_target",
    } else "reject"
    return Decision(disposition, reason)


def evaluate_checks(checks: dict[str, Callable[[], Any]]) -> Evaluation:
    """Run registered checks in policy order and stop at the first failure."""
    if (not isinstance(checks, dict) or len(checks) > len(STAGE_ORDER) or
            any(stage not in STAGE_ORDER for stage in checks) or
            any(not callable(check) for check in checks.values())):
        return Evaluation(PROTOCOL_ERROR)
    for stage in STAGE_ORDER:
        check = checks.get(stage)
        if check is None:
            continue
        try:
            check()
        except Exception as error:
            return Evaluation(decision_for_failure(error, stage), error)
    return Evaluation(ALLOW)
