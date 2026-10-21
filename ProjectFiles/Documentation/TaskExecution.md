# Private task execution phases

`AgentRuntime/task_execution.py` defines the execution graph, transition
prerequisites and permitted effects. `TaskExecution` in `openclaw_runtime.py`
dispatches one handler for the current phase. A task-owned `TaskContext` contains
the evidence ledger, observations, decision, receipt state, recovery guards,
history, counters, command capabilities, transport and ACP process reference.
Context-local helper access preserves standalone readiness processes without
sharing mutable task state. A nested task cannot replace its current owner.

| Phase | Permitted work | Exit conditions |
| --- | --- | --- |
| starting | Runtime preparation and ACP connection | Startup succeeds, or drain |
| observing | Accepted observation and read-only inspection | Observation for planning/recovery; secure target; or recognized whole local request |
| planning | Existing routed planning request, including its existing repair budget | Validated decision before reconciliation |
| reconciling | Read-only inspection, receipt lookup, settling, dependency/evidence/recovery checks | Resolved receipt; validated decision and successful preflight before execution |
| executing | One validated action and command preflight | Reconcile its result, rejection or lost response |
| waiting_input | Existing private secure-input exchange and delivery | Reconcile delivery and inspect the resulting screen |
| verifying | Read-only outcome checks and existing independent final verifier | Coverage gate passes, or return to observing |
| draining | Release owned images, publish aggregate metrics, close ACP | Local cleanup finishes |
| finished | No further effects | Terminal |

The transition table rejects undeclared edges and missing prerequisites. The
bridge and routed model boundary also enforce phase permissions. For example,
verification cannot dispatch an action, and reconciliation cannot ask for a
planning response. An execution phase admits only one action, even after its
receipt resolves. Every live phase can drain on Stop or failure. Completion
revokes execution before publishing terminal output; a rejected completion
returns to observing and remains stoppable.

Before sending an action, the controller retains its stable receipt ID. A lost
reply enters reconciliation with that ID still pending. Only a validated
terminal result/rejection for the matching action releases the pending gate.
Nonterminal replies, malformed results, unknown receipts and disconnected
transport cannot authorize another action or completion. The existing receipt
lookup budget applies unchanged. A terminal receipt with an uncertain GUI
effect still requires local inspection and the existing mutation replay guard;
receipt recovery is not proof that the intended effect occurred.

The existing native Pause sends SIGSTOP to the runtime process group. This
freezes the current phase and receipt wait, including its reader threads. Resume
uses SIGCONT and continues that same context; it does not restart planning or
reset recovery budgets. The native task lease remains the atomic authority for
macOS events, command launches, cleanup and queue handoff. Python `finished`
means local controller cleanup finished, not that native descendant drainage or
resource cleanup can be skipped. An unresolved receipt is retained until this
context is discarded; it never authorizes replay.

No phases or identifiers enter prompts, public controls or task history. Model
order, prompt content, repair/routing budgets, step bounds, completion coverage,
single-action execution and native authorization checks remain in their existing
implementations. Exact, fully recognized local requests retain zero model calls.

Offline tests enumerate every phase pair and prerequisite, enforce boundary
permissions, exercise healthy and lost-response tasks through fake ACP/native
peers, reject malformed/nonterminal receipts, stop after rejected completion,
and pause/resume a disposable recovery process with the native signals. The
fixtures do not perform desktop actions or provider requests. Live accuracy
validation remains incomplete.
