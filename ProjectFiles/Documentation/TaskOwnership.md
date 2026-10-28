# Task ownership

Every desktop task receives an immutable generation UUID through the private
startup pipe. Python includes it in runtime envelopes; Swift binds it to the
invocation, native bridge, observation revision, secure-input request, and native
execution context. Replies must match both generation and request ID. The token
is not an action parameter, model prompt field, or persisted history value.
Readiness processes do not acquire an execution lease. The private protocol
version is included in the contract fingerprint, so older bundled components
fail their startup contract check before making provider requests.
Protocol version 2 also requires private action IDs and binds
[native receipts](ActionReceipts.md) to the same lease. Receipt lookup has no
execution authority, and retirement discards the table after drainage.

`TaskLease` serializes revocation with native commits. Running work can deliver;
Pause retains the generation and suspends delivery; draining and retired work
cannot deliver. The task-local context follows asynchronous Swift operations.
Dispatch callbacks capture the lease explicitly. Existing Accessibility identity,
focus, window, permission, protected-target, and secure-input checks still apply.

Paused asynchronous checkpoints park in checked continuations; background native
commits park in one-shot semaphore waits. Registration shares the lease's lock
with state transitions, preventing missed Resume or Stop signals. Resume wakes
all registered workers. Revocation and retirement wake them to reject further
work. Cancellation removes an asynchronous wait directly; the bridge and task
tool entry points also install cancellation wakeups for synchronous commits.
Workers recheck their own cancellation and ownership after every wake, including
spurious wakeups or an immediate new Pause. No Pause timers or periodic wakeups
remain. The main run loop still rejects a paused commit instead of blocking, and
the recursive delivery lock still protects nested native mutations. Private wait
counts contain no task inputs and are not persisted in history.

Runtime pipes, buffers, event handlers, terminal state, and pending bridge tasks
belong to one invocation. Stop revokes its lease before cancelling workers and
terminating command groups. A non-cancellable macOS operation may settle later;
its result cannot publish task responses or deliver follow-up input. Late launch
results may add resources only to that invocation's teardown ledger. Retired
screenshot files are removed. No attempted mutation is replayed by this layer.

The runtime drains pending operations and process output before delivering one
terminal event on the main actor. The terminal handler completes the existing
resource cleanup synchronously before the lease retires and the queue advances.
Cleanup retains the existing preference and foreground-ownership checks. A
five-second monotonic deadline reports continued shutdown through existing status
text; it never authorizes overlap or discards queued work. Private discarded-work
counts live on the lease and contain no payloads or secrets.

Offline tests exercise delayed callbacks, atomic delivery boundaries, protocol
mismatches, secure-input isolation, command cancellation, screenshot disposal,
startup failure, duplicate completion, Stop during queued output, and drainage
before handoff. Controlled callbacks model macOS operations; they do not establish
live desktop accuracy. Do not launch the fixer, live-control tester, Chrome, or a
live desktop task to validate this change.

Pause regressions cover mixed workers parking once, Resume during registration,
Stop and retirement, cancellation before and after parking, concurrent wakeups,
reparking without authority, generation isolation, nested delivery, bridge
cancellation, and cancellation between command preflight and native launch. The
fixtures add no provider requests and do not interact with live desktop apps.


Capture retention accounting refreshes every registered path through the pinned
capture-directory descriptor, including artifacts with reader holds. Device,
inode and birth time distinguish the original object from a replacement; size
changes on that same object update its charge in either direction. Full original
metadata remains required for a new reader or identity-bound deletion: refreshing
bytes never accepts changed pixels as the original observation.

A replacement retains the last known original charge plus its observed size,
using a high-water mark so repeated inspection does not double count it or free
capacity when uncertain metadata shrinks. Metadata errors preserve the previous
charge. Confirmed absence removes an entry only after all reader holds end;
restoring the original version permits ordinary expired-file cleanup. Changed
versions stay charged instead of silently disappearing from the ledger. All
arithmetic saturates at Int64.max and totals are recomputed from the bounded
ledger so resolved entries can release capacity even after saturation. These
checks read metadata only, never image contents, directory listings or user
outputs. They do not broaden cleanup authority or add provider requests.

Offline accounting regressions: `swift test --filter CaptureArtifactLedgerTests`.

Startup checks the known TaskScratch root before managed-runtime readiness.
Missing scratch storage is created privately; an existing root must be owned by
this user and must not be a symlink. Mode drift is repaired under a local lock
through a checked directory descriptor, with `0700` readback. Unopenable,
foreign-owned, replaced or symlinked storage fails closed with a classified
private-directory attention error. No user output path enters this repair path.

After permission validation, startup checks the scratch volume's replacement and
directory-sync capabilities. A bounded in-memory profile is shared by directories
on the same device/filesystem identity and mount flags. Probes create only tiny,
private temporary entries and remove them relative to checked descriptors. Warm
checks perform metadata reads without repeating those writes. Permission, ACL,
identity, capacity, and actual commit checks retain their existing authority.
See `Docs/ManagedOpenClaw.md` for the corresponding managed-runtime preflight.
