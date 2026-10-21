# Owned subprocess trees

`SubprocessSupervisor` owns launch, kernel-acknowledged process-group creation,
parent exit, descendant discovery, teardown, and output-drain acknowledgement as
separate states. Commands, their local syntax/help probes, OpenClaw status and
dashboard helpers, and the task runtime use it. The small `ProcessSupport` C
module uses `posix_spawn` with `POSIX_SPAWN_SETPGROUP`; every attribute and file
operation is checked. A group-setup failure rejects the launch before the
requested executable runs. There is no optimistic parent-side `setpgid` repair
or fallback to signaling an arbitrary PID. Unrelated descriptors are closed at
exec, working directories and literal argument arrays are preserved, and the
child receives a fresh signal mask and default dispositions.
The child starts suspended and is released only after ownership and kernel
observers are installed. A failed release is reaped before launch failure returns.

An exit notification reaps the immediate parent without declaring the tree
finished. A bounded local process inventory retains PID plus birth-time
identities, group membership, and observed descendant relationships. A child
that has been observed leaving the group remains tracked after reparenting.
Signals recheck those identities; a live owned group member anchors group
signals. Zombies are finished effects, not running children. Failed or overflowing
inspection cannot authorize completion or handoff. The supervisor stays retained
until its owned tree is empty, even if the caller releases its parent handle.
Fork, exec, and descendant exit notifications trigger inspection locally; a
500-millisecond inventory timer with 25-millisecond leeway provides a fallback.
Kernel observers are capped at 1,024; additional descendants remain inventory-owned.
Empty groups are retired permanently, and unreadable live members cannot be
mistaken for exited processes.

Ordinary commands use one deadline for parent and descendants. A zero parent
exit with a surviving child does not pass execution checks. Timeout or cancellation
resumes paused processes, terminates owned work, escalates to KILL after at most
one second, and awaits tree drainage. Once a terminating parent exits, surviving
children are killed promptly instead of getting a fresh grace period to mutate
state. The command's parent exit status is preserved separately from timeout.
Both output streams continue draining, and their final bytes are collected
before output-drain acknowledgement. Failed or uncertain effects remain subject
to the existing receipt reconciliation rules; no action is replayed here.

The runtime keeps its output readers until its tree ends. Reads are bounded and
nonblocking, including queued reads racing final drainage. An unterminated final
completion/error frame from the same generation can settle the ending task;
this exception cannot execute bridge actions or deliver stale task messages.
Terminal delivery waits for the runtime tree, native operations, and enabled
service cleanup. The existing five-second stopping explanation remains in use.

## Explicitly requested persistent work

Background syntax by itself grants no persistence. A conservative check of the
original task allows explicit requests such as “run the server in the
background” or “keep the service running”; explanatory and negated requests do
not qualify. Only a successful launcher that has actually exited may transfer
its surviving descendants to the task's private resource ledger. Preflight and
readiness processes never qualify. An unrecognized request retains ordinary
whole-tree waiting and its bounded timeout.

The command result states that the launcher finished and service readiness is
unverified. Existing outcome checks prove only their named outcomes. Inherited
output remains bounded and continuously drained; future output is discarded,
so closing a command result does not break a retained service's stdout pipe.
With Task cleanup enabled, retained service trees must finish teardown before
task handoff. With cleanup disabled they transfer to an in-memory resource
registry and stay supervised until exit. Changes to the existing cleanup setting
apply until teardown starts. No new UI, permission, action fields, or model
requests are introduced, and no commands or output are persisted by the supervisor.

## Boundaries and validation

macOS does not supply an unprivileged subreaper or atomic snapshot of all forks.
Process groups cover children that exit/reparent between inventory passes, and
observed descendants remain owned across group changes. A program that immediately
double-forks, creates a new session, and reparents before it can be observed can
escape this mechanism. OS-managed services handed to launchd are also outside a
command's process tree. This is process-tree supervision, not a sandbox or a
claim of containment of deliberately escaping programs. It lasts for the
TaskPilot controller's lifetime; it does not survive the controller being killed.

Offline fixtures cover parent exit before descendants, inherited and closed
output, timeout after exit zero, cancellation after parent exit, observed session
escape, TERM-resistant children, group-setup rejection, retained services with
both cleanup choices, runtime completion during exit, output floods, and later
task handoff. Python checks reject failed/unacknowledged standalone group setup
before configuration or model requests. Existing command, receipt, ownership,
transport, and output-buffer regressions remain in the suites. No fixer,
live-control tester, Chrome, desktop task, or provider request is run; live
accuracy validation remains incomplete.
