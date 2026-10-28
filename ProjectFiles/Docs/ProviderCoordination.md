# Provider health and configuration coordination

`RuntimeState` uses a stable `runtime-readiness.lock` inode and short exclusive
`flock` transactions. Each operation reloads the latest document, applies only
its own update, increments the revision, and atomically replaces the private
0600 JSON file. Unique temporary filenames also avoid same-process collisions.
No model request, CLI invocation, or cooldown wait runs inside a state transaction.

Health is scoped to a hashed credential fingerprint, independently of runtime
version and model configuration. Verification remains keyed by the complete
existing validation/configuration identity and expires after ten minutes.
Applicable credential cooldowns survive configuration/version changes and cannot
be cleared by a sibling success before their known reset. Longer cooldowns win
concurrent cooldown updates. A successful explicit probe can clear an older
unknown-reset failure, but never a failure recorded after that probe started.
Invalidation and configuration updates also prevent older in-flight successes
from restoring verification. Persisted details contain sanitized machine facts,
not raw provider messages, credentials, prompts, or task inputs.

Planning takes an atomic health/revision snapshot immediately before each
TaskPilot attempt. Successful responses carry that revision when refreshing
verification. A useful response can still finish its decision if a concurrent
failure wins; it cannot falsely publish the credential as verified.

Explicit readiness checks have a separate identity-scoped single-flight lease.
Followers detect the leader's completed-check revision and read current results
without generating, including after a failed check. The state lock remains free
while the leader waits for ACP. Ordinary readiness refreshes do not take the
single-flight lease, construct ACP, modify OpenClaw configuration, or generate.
Locks are released by the OS after owner exit; a lock alone never establishes
verification. A crashed check has no successful completion record.

`openclaw-configuration.lock` serializes TaskPilot's model migration, credential
synchronization, setup configuration phase, and ACP initialization (including
reconnection). The model-configuration version marker is scoped to the configured
OpenClaw pathname and is committed only after the complete migration succeeds.
Task startup holds one lease from preparation through session initialization;
local file shortcuts and model generations execute outside it. Native
configuration probes use the same inode with a shared lease and a bounded
five-second wait. They report existing configuration activity through the usual
status path rather than reading half a migration.

Setup invokes the bundled runtime's private `--configuration-command` entry point
for its installation/configuration phase. Its child inherits the lease, so a
wrapper crash cannot release ownership while that child still changes settings.
The phase returns the actual executable path through a disposable local file,
then releases the lease before the separate ACP verification check. No credential
is sent to this phase. Other OpenClaw clients do not participate in these advisory
locks; this coordinates TaskPilot processes, not arbitrary external writers.

Lock ordering is single-flight (10) → configuration (20) → installation (30) →
short state transaction (40). Python's `private_lock`, configuration transaction,
and managed installation lock reserve their rank before filesystem setup or
waiting on `flock`. A lower-ranked acquisition while a higher rank is held throws
the fixed `internal_lock_order` error. Reentrant configuration transactions reuse
their already-owned descriptor without a new acquisition. Equal ranks remain
permitted, including native shared configuration readers; this is an ordering
guard for these lock categories, not detection of every possible deadlock.

Python bookkeeping belongs to the synchronous thread operation and resets after
fork. Native synchronous operations use a thread context; asynchronous operations
retaining leases across suspension bind `BackendLockOrder.operation` for the
operation's lifetime. The private native configuration lease owns both its file
descriptor and rank reservation, releasing both on explicit release or deinit.
Failed opens, failed waits, and exceptional exits release reservations too.
The two languages use identical fixed ranks. Each retains at most 128 wait
samples in memory, containing only a fixed lock category and wait duration.
No path, request, credential, owner identity, or task content is recorded.

Initial configuration preparation completes before acquiring single-flight. No code
waits for a model response while holding the configuration or state lock.

Offline coverage includes real multiprocess merge races, late success versus
quota/invalidation, failed/successful check coalescing, read-only refresh during
checks, leader exit, inherited setup leases, and Python/native lock compatibility.
No live provider or desktop validation is implied by these fixtures.
