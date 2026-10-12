# Native action receipts

The runtime assigns a fresh UUID when a validated logical action is ready for
execution. This private ID accompanies the bridge request, including local
secure-input delivery. It is separate from the transport request ID, observation
revision, generated action schema, model prompt, and task history.

Each task lease owns an in-memory receipt table. Native validation and an atomic
claim occur before dispatch. The table binds the ID to a fingerprint of the
normalized action and its original bridge context. Reusing it with different
parameters is rejected. Identical parameters with a new ID represent new intent;
the backend does not deduplicate unrelated actions by guessing from their text.
This caller-intent distinction follows the
[AWS guidance on idempotent retries](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/).

Receipt states are:

- `pending`: admitted, without a native delivery boundary yet.
- `dispatched`: a native commit began; the operation has not returned.
- `confirmed`: a terminal native result was retained.
- `unconfirmed`: delivery or its effects remain uncertain, with a terminal
  result or error retained.
- `rejected`: a terminal failure occurred before dispatch.

Dispatch recording shares the existing task-ownership lock with short native
delivery/commit operations. Revocation and generation checks still apply. A
duplicate ID returns the existing result or pending status and never invokes
the executor again. Terminal receipts settle once; late results cannot replace
them or affect another task's table. Pause/Resume retains the same receipts.
Retirement discards them after the existing drainage and cleanup.

Normal actions make no receipt-query or additional model request. Native reply
waiting is bounded to 30 seconds plus the configured command timeout. A missing,
partial, or inconsistent acknowledgement triggers a read-only receipt lookup,
with up to five seconds of local polling for an operation to end. Old transport
replies and cross-task responses are ignored. One stdin reader retains complete
protocol lines across configuration, bridge, and secure-input waits.

A terminal receipt recovers an acknowledgement, not whole-task completion.
Returned verification scope remains unchanged. Uncertain GUI effects require
fresh accepted observations and the existing bounded action recovery; an
attempted send, submission, or other mutation cannot be replayed just because its
effect is unclear. The requirement-evidence gate still controls completion.

Unknown or still-running operations stop the task without dispatching another
action. A disconnected pipe cannot support receipt lookup. Receipts are not
durable across process restart or a new task and do not provide distributed
exactly-once execution guarantees. Only query, recovery, and unresolved counts
are added to private persisted diagnostics; IDs, fingerprints, payloads, and
receipt contents are not persisted.

Offline tests cover concurrent duplicate claims, append execution once,
distinct repeated intent, changed-payload conflicts, pending and lost replies,
partial output, stale wire replies, uncertain GUI outcomes, revocation,
Pause/Resume, generation isolation, and diagnostic compatibility. A runtime
fixture recovers a lost mutation reply with one planning call and the existing
final verifier. No fixer, Chrome, live-control tester, desktop tasks, or provider
requests are used; live accuracy validation remains incomplete.
