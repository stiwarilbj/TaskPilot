"""Private execution phases. Structural validity never grants native authority.

The native task lease remains the atomic delivery gate. This gate limits which
operations the Python controller may request, including after a lost reply.
No task contents, transitions, or action identifiers are persisted here.
"""
from __future__ import annotations

from contextvars import ContextVar
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class Phase(str, Enum):
    STARTING = "starting"
    OBSERVING = "observing"
    PLANNING = "planning"
    EXECUTING = "executing"
    RECONCILING = "reconciling"
    RECOVERING = "recovering"
    WAITING_INPUT = "waiting_input"
    VERIFYING = "verifying"
    DRAINING = "draining"
    FINISHED = "finished"


@dataclass(frozen=True)
class Transition:
    prerequisites: frozenset[str] = frozenset()


# Every nonterminal phase may be stopped, including after rejected completion.
# An execution edge leaves reconciliation only with a validated decision and
# completed preflight. A lost acknowledgement must be resolved first.
TRANSITIONS = {
    (Phase.STARTING, Phase.OBSERVING): Transition(),
    (Phase.OBSERVING, Phase.PLANNING): Transition(frozenset({"observation"})),
    (Phase.OBSERVING, Phase.WAITING_INPUT): Transition(frozenset({"secure_target"})),
    (Phase.OBSERVING, Phase.RECONCILING): Transition(frozenset({"observation"})),
    (Phase.OBSERVING, Phase.EXECUTING): Transition(frozenset({"local_request"})),
    (Phase.OBSERVING, Phase.VERIFYING): Transition(frozenset({"local_request"})),
    (Phase.PLANNING, Phase.RECONCILING): Transition(frozenset({"decision"})),
    (Phase.RECONCILING, Phase.OBSERVING): Transition(),
    (Phase.RECONCILING, Phase.EXECUTING): Transition(frozenset({"decision", "preflight"})),
    (Phase.RECONCILING, Phase.WAITING_INPUT): Transition(frozenset({"secure_target", "preflight"})),
    (Phase.RECONCILING, Phase.VERIFYING): Transition(frozenset({"decision"})),
    (Phase.EXECUTING, Phase.RECONCILING): Transition(),
    (Phase.WAITING_INPUT, Phase.RECONCILING): Transition(),
    (Phase.VERIFYING, Phase.OBSERVING): Transition(),
    **{(phase, Phase.RECOVERING): Transition() for phase in (Phase.STARTING, Phase.PLANNING, Phase.VERIFYING, Phase.RECONCILING, Phase.EXECUTING, Phase.WAITING_INPUT)},
    **{(Phase.RECOVERING, phase): Transition(frozenset({"recovered"})) for phase in (Phase.STARTING, Phase.PLANNING, Phase.VERIFYING, Phase.RECONCILING, Phase.EXECUTING)},
    **{(phase, Phase.DRAINING): Transition() for phase in Phase
       if phase not in {Phase.DRAINING, Phase.FINISHED}},
    (Phase.DRAINING, Phase.FINISHED): Transition(frozenset({"cleanup"})),
}

# These effects are checked at the actual bridge/model/output boundaries, not
# just by the dispatch loop. Receipt lookup is read-only and cannot redispatch.
EFFECTS = {
    Phase.STARTING: frozenset({"configure", "connect"}),
    Phase.OBSERVING: frozenset({"observe", "read"}),
    Phase.PLANNING: frozenset({"plan", "read"}),
    Phase.EXECUTING: frozenset({"execute", "read"}),
    Phase.RECOVERING: frozenset({"connect", "read", "receipt"}),
    Phase.RECONCILING: frozenset({"observe", "read", "receipt"}),
    Phase.WAITING_INPUT: frozenset({"secure_input", "execute", "read"}),
    Phase.VERIFYING: frozenset({"observe", "read", "verify", "complete"}),
    Phase.DRAINING: frozenset({"cleanup"}),
    Phase.FINISHED: frozenset(),
}


class ExecutionStateError(RuntimeError):
    pass


@dataclass
class ExecutionMachine:
    phase: Phase = Phase.STARTING
    pending_action: str | None = None
    completion_published: bool = False
    execution_consumed: bool = False

    def transition(self, destination: Phase, **facts: bool) -> None:
        rule = TRANSITIONS.get((self.phase, destination))
        if rule is None:
            raise ExecutionStateError(f"Invalid task transition: {self.phase.value} -> {destination.value}")
        correction_interrupt = (self.phase == Phase.PLANNING and destination == Phase.RECONCILING
                                and facts.get("correction") is True)
        missing = [] if correction_interrupt else sorted(
            name for name in rule.prerequisites if facts.get(name) is not True
        )
        if missing:
            raise ExecutionStateError("Task transition requires " + ", ".join(missing))
        if self.pending_action is not None and destination not in {Phase.RECONCILING, Phase.RECOVERING, Phase.DRAINING, Phase.FINISHED}:
            raise ExecutionStateError("The dispatched action must be reconciled before advancing")
        self.phase = destination
        if destination in {Phase.EXECUTING, Phase.WAITING_INPUT}:
            self.execution_consumed = False

    def require(self, effect: str) -> None:
        if effect not in EFFECTS[self.phase]:
            raise ExecutionStateError(f"Task phase {self.phase.value} forbids {effect}")
        if self.pending_action is not None and effect not in {"receipt", "observe", "read", "cleanup"}:
            raise ExecutionStateError("The dispatched action must be reconciled before further work")
        if effect == "execute" and self.execution_consumed:
            raise ExecutionStateError("This phase has already dispatched its single action")

    def dispatch(self, action_id: str) -> None:
        self.require("execute")
        if not isinstance(action_id, str) or not action_id:
            raise ExecutionStateError("An action needs a stable receipt ID")
        self.pending_action = action_id
        self.execution_consumed = True

    def reconcile(self) -> None:
        if self.phase != Phase.RECONCILING:
            self.transition(Phase.RECONCILING)

    def resolve(self, action_id: str) -> None:
        if self.pending_action != action_id:
            raise ExecutionStateError("The action receipt does not belong to the pending work")
        self.pending_action = None

    def drain(self) -> None:
        if self.phase not in {Phase.DRAINING, Phase.FINISHED}:
            self.transition(Phase.DRAINING)

    def complete(self) -> None:
        self.require("complete")
        if self.completion_published:
            raise ExecutionStateError("Task completion was already published")
        self.completion_published = True
        self.drain()  # Revoke further planning/execution before terminal output.


@dataclass
class TaskContext:
    task: str
    display_id: int
    generation: str | None
    exact_input_references: list[dict] = field(default_factory=list)
    stop_boundaries: list[dict] = field(default_factory=list)
    original_task: str = ""
    original_input_references: list[dict] = field(default_factory=list)
    instruction_corrections: list[dict] = field(default_factory=list)
    instruction_revision: int = 0
    correction_key: Any = None
    pending_correction_message: dict | None = None
    working_document_revision: int = 0
    working_document_key: Any = None
    pending_working_document_message: dict | None = None
    pending_task_control: dict | None = None
    working_document: dict | None = None
    working_document_update_handler: Any = None
    machine: ExecutionMachine = field(default_factory=ExecutionMachine)
    ledger: Any = None
    runtime_state: Any = None
    client: Any = None
    router: Any = None
    recovery: Any = None
    recovery_cycles: Any = None
    evidence_guard: Any = None
    inbox: Any = None
    images: Any = None
    active_acp_process: Any = None
    bridge_observation_revision: str | None = None
    presentation_action_id: str | None = None
    progress_lifecycle: str = "running"
    progress_active_requirement_ids: list[str] = field(default_factory=list)
    progress_revision: int = 0
    progress_fingerprint: str = ""
    wait_publisher: Any = None
    destination_publisher: Any = None
    wait_request_sequence: int = 0
    observation_keywords: list = field(default_factory=list)
    receipt_metrics: dict = field(default_factory=lambda: dict(receipt_queries=0, receipt_recoveries=0, receipt_unresolved=0))
    local_change_metrics: dict = field(default_factory=lambda: dict(local_notifications=0, local_targeted_checks=0, local_poll_wakeups=0))
    command_capability_metrics: dict = field(default_factory=lambda: dict(command_inspections=0, command_probes=0, command_probe_cache_hits=0, command_preflight_rejections=0))
    command_capabilities: dict = field(default_factory=dict)
    history: list = field(default_factory=list)
    step: int = 0
    observation: dict | None = None
    pending_observation: dict | None = None
    screenshot_path: Any = None
    screenshot_digest: str = ""
    decision: dict | None = None
    action: dict | None = None
    result: Any = None
    local_budget: Any = None
    recovered_result: Any = None
    input_target: dict | None = None
    failure: Any = None
    reconcile_reason: str = ""
    last_action_signature: str = ""
    last_screen_digest: str = ""
    identical_action_count: int = 0
    consecutive_action_failures: int = 0
    blocked_recoveries: int = 0
    loading_pid: int | None = None
    loading_waits: int = 0
    consecutive_dependency_blocks: int = 0
    consecutive_evidence_conflicts: int = 0
    command_hints_inspected: bool = False


class InstructionSuperseded(RuntimeError):
    """A terminal provider response belongs to an instruction revision that was superseded."""
    superseded_instructions = True


class WorkingDocumentSuperseded(InstructionSuperseded):
    """A response or action belongs to a prior selected-document binding."""


current_task: ContextVar[TaskContext | None] = ContextVar("task_execution_context", default=None)
