# Execution-phase prompt compilation

The private Python runtime compiles distinct planning, recovery and completion
templates from `AgentRuntime/prompt_compiler.py`. Selection is local and pure;
it makes no provider requests, desktop observations or actions. Existing model
defaults, permissions, single-action execution and recovery limits are unchanged.

Planning supplies the next-step decision contract, safety rules and contextual
examples. Recovery adds one corrective rule for the latest owned result and
includes its exact failed condition as quoted data. Earlier failures remain
history evidence, rather than accumulating corrective instructions. A verified
result without unresolved expectations or a completed local wait returns to
planning. Unconfirmed named
expectations, uncertain delivery, rejected actions, unmet command checks,
suppressed repetitions and rejected completion claims select recovery. Genuine
permission, cancellation and secure-input stops still end or pause work in the
existing executor; a prompt cannot override them.

Completion uses its own proof contract and response examples, without executable
action examples or recovery instructions. It audits the complete original task
against the requirement/evidence ledger. Delivery acknowledgement and an
unrelated screen change remain insufficient proof of the intended outcome.

All templates use a fixed order: phase instructions, response examples, original
task, capability context, current observation, phase-specific failed condition or
completion claim, recent validated results, checklist evidence, then earlier
confirmed facts. Task and data sections use canonical JSON serialization, with
sorted object keys and preserved array order and contents. Embedded newlines or
instruction-like screen text cannot introduce raw instruction sections. Labels,
window relationships, routes, task wording and validated evidence are preserved.

The existing one-request format-repair budget reuses the exact applicable phase
contract and screenshot. Invalid output and the precise validation error are
quoted separately. Repair performs no actions or fresh observations and does
not create another recovery cycle. Recovery decisions remain planning calls in
existing private metrics; completion remains verification.

The compiler version participates in the private decision-cache identity and
offline regression prompt packs. The build script notices compiler changes when
bundling the runtime. Offline prompt overrides are independently scoped to
planning, recovery and completion, preserving phase-specific data and examples.

Tests cover phase transitions, precise failures, instruction/data boundaries,
canonical ordering, preserved evidence, cache invalidation, unchanged repair
budgets and actual task-loop fixture replay. These are offline controls with
scripted responses; they do not measure live model accuracy. No fixer,
live-control tester, Chrome interaction or live desktop task is run.
