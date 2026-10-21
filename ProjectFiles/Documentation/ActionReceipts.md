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
Retirement discards in-memory replies after the existing drainage and cleanup;
it retains unresolved durable crash barriers.

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
action. A disconnected pipe cannot support receipt lookup.

## Private crash journal

The controller records `prepared`, `dispatched`, and `terminal` barriers in
`ActionRecovery/receipts.json` under its private Application Support directory.
Preparation is durable before a delivery token is returned; dispatch is durable
inside the task-ownership commit boundary, before the first side effect. A
validated terminal reply is exposed only after its terminal barrier is durable.
Later native commits for that same action check the journal's health without
rewriting the dispatched marker.

The journal contains opaque task/action UUIDs, domain-separated HMAC-SHA256
fingerprints, phase, and terminal category only. A private random 256-bit key
also authenticates the entire snapshot. Raw requests, commands, paths, target
labels, entered text, screenshots, credentials, replies, and execution generation
IDs are excluded. Directories are mode 0700; key, lock, journal, and temporary
files are mode 0600 from creation. Writes synchronize the file before atomic
rename and synchronize the directory afterward. macOS full synchronization is
used where available. One controller holds an exclusive OS file lock; file
symlinks and hardlinks are rejected. A missing key or journal, authentication
failure, unsupported version, oversized file, or write failure stops execution
instead of resetting protection.

The existing private task ledger separately retains the active task's original
authorization before runtime launch. Removing a queued task and recording this
authorization share one durable ledger write. On restart, a matching keyed
authorization is required to record that task as **interrupted**, exactly once,
using existing history. The interrupted task is not automatically requeued,
resumed, or marked complete. Its original request remains recoverable in history;
any subsequent explicit task uses the normal observation, action, and evidence
flow. A lost authorization cannot be reconstructed from journal entries.

A restored prepared action cannot acquire a delivery token. A restored dispatched
action remains uncertain, including a crash after the dispatch barrier but before
the actual effect. Even a restored confirmed marker has no retained native reply
and cannot prove a requirement. Receipt lookup returns no reconstructed proof;
reusing a restored action ID is a protocol error before any executor access.
Outcome inspection must use fresh observations or validated read-only results;
the journal provides no replay, completion, or reconciliation shortcut.

Retirement compacts safe terminal records to the latest 128. Interrupted
dispatched and terminal-unconfirmed entries are never evicted. Startup seals
orphaned authorizations without turning uncertain effects into confirmed results.
The bounds are 4096 receipts, 256 retained authorizations, and a 2 MiB file. If
unresolved work exhausts these limits, new dispatch stops rather than dropping
duplicate protection. Failed writes poison the current journal instance; future
actions cannot proceed through it. These barriers prevent automatic crash replay,
but do not provide distributed exactly-once execution or undo delivered effects.
No payload/result contents are added to persisted diagnostic metrics.

Offline tests cover concurrent duplicate claims, append execution once,
distinct repeated intent, changed-payload conflicts, pending and lost replies,
partial output, stale wire replies, uncertain GUI outcomes, revocation,
Pause/Resume, generation isolation, and diagnostic compatibility. A runtime
fixture recovers a lost mutation reply with one planning call and the existing
final verifier. Isolated XCTest subprocesses exit abruptly at preparation,
dispatch, pre-confirmation, and post-confirmation boundaries. They verify no
duplicate execution, no restored completion authority, and once-only interrupted
history. Further cases cover private permissions, authentication, file loss,
corruption, capacity exhaustion, storage failures, and unsafe path redirection.
No fixer, Chrome, live-control tester, desktop tasks, or provider
requests are used; live accuracy validation remains incomplete.
