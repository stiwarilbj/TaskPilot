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
child receives a fresh signal mask and the existing full set of resettable
default dispositions, including teardown, release, and pipe signals.
Controller-owned runtime and command pipes are created with `FD_CLOEXEC` on
both ends before readers or writers receive them. Spawn retains its
`POSIX_SPAWN_CLOEXEC_DEFAULT` allowlist, maps only the intended standard streams,
and explicitly closes their source descriptors once each after mapping (including
shared stdout/stderr). Caller-supplied handles retain their original flags and
ownership; an already-closed unused pipe end is never inspected. No extra
inherited descriptors are required by this launch contract.

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
Output readers share a separate serial queue. Each round gives both streams a
turn, rotates which stream goes first, and yields after at most 64 KiB or 16 read
attempts per stream (including interrupted reads). Read sources stay armed for
remaining bytes; stderr is inspected even when only stdout's source fires.
Exit and teardown notifications remain on the independent supervisor queue.
Final drainage repeats fair rounds through EOF before retiring readers. An
unexpected continuously inherited writer remains bounded to 16 final rounds
and is reported incomplete, never exact-output proof. Explicitly persistent
services keep their existing continuous discard/drain behavior.
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

Descriptor regression fixtures launch synthetic children with deliberately
inheritable unrelated handles and standard-stream source handles. They verify
that none survive exec, intended stdin/stdout/stderr still work, merged output
is preserved, and runtime completion without a final newline is drained exactly
once. These fixtures require no desktop interactions or provider calls.

## Bounded configuration-helper signal state

Managed-helper startup keeps audit dependencies eager, including SQLite health,
descriptor validation and the bounded subprocess launcher. `command()` dispatch
does not preload provisioning libraries: `download()` imports `urllib.request`
when a download starts, and `install()` imports `tarfile` only after a successful
download reaches extraction. Valid existing installations, full/incremental
audits and failed downloads do not load archive support. Checksum, archive
namespace validation, staging cleanup and activation rules are unchanged. Static
function-local imports remain discoverable by the bundled runtime builder.
`python3 -m unittest Tests.Python.test_managed_imports` checks these boundaries
in fresh processes; its downloads use only an in-memory data URL.

`managed_openclaw.bounded_run()` uses the private `managed_spawn.py` Darwin
launcher. It sets an empty signal mask and default dispositions for `SIGHUP`,
`SIGINT`, `SIGQUIT`, `SIGTERM`, `SIGCONT`, `SIGPIPE`, and `SIGXFSZ` in checked
`posix_spawn` attributes. KILL/STOP cannot be reset and are excluded. PIPE/XFSZ
retain Python's existing restore-signals behavior. Other ignored signals remain
inherited on this Python path. The native supervisor retains its preexisting,
broader full-default policy; its groups, suspended-start acknowledgement and
release behavior are unchanged.

Python 3.11's `Popen` interface cannot supply this mask/default set together with
working-directory and explicit lease inheritance. The private launcher binds
the supported Darwin libc spawn API through ctypes, including its opaque
attribute/action handles and SDK flag values. This avoids Python `preexec_fn`,
which can deadlock after forking a multithreaded controller, and avoids changing
process-global signal dispositions or the controller thread's mask. No extra
launcher process, shell, or executable is introduced. Attribute/action failures
reject before exec; both native objects are destroyed on every return path.

The Python helper still starts a new session with its PID as group ID. Literal
arguments, child environment/PATH, working directory, standard input, merged
disk-backed output and explicit provisioning-lease descriptors are preserved.
Darwin's close-on-exec-default policy passes only the intended standard streams
and explicit leases, without changing controller descriptor flags. Stable source
copies handle closed controller standard descriptors. The small pid/wait adapter
preserves normal and signal exit codes, timeout exceptions and bounded waits;
`bounded_run` retains its existing group-KILL/reap interruption path, output limit,
and post-command configuration-path fence. This does not add process-tree policy,
model requests, observations, diagnostics, or task contents to persistence.

Offline reproduction from `ProjectFiles`:

```sh
python3 -m unittest discover -s Tests/Python -p test_managed_spawn.py
swift test --filter SubprocessSupervisorTests
```

Both suites compile a tiny raw C observer so interpreter/shell startup cannot
hide inherited signal state. Altered dispositions and masks live only in
disposable hosts. Fixtures verify empty masks and default teardown signals,
unchanged host state, concurrent launches, TERM delivery, groups/sessions,
streams, leases, descriptor closure, launch failures, timeout, interruption and
drainage. Native integration runs through the actual supervisor. No provider,
Chrome, fixer, live-control tester, or desktop task runs; live validation remains
incomplete.

## Advisory descriptor headroom

Immediately before allocating launch arguments, `/dev/null` or a child,
`SubprocessSupervisor` reads its process's `RLIMIT_NOFILE` soft limit and a
bounded `PROC_PIDLISTFDS` snapshot. The C helper uses a fixed 4,096-entry buffer,
opens no handles, and collects no paths or descriptor contents. Only descriptors
below the soft limit occupy available slots; existing descriptors above a
subsequently lowered limit do not consume those slots.

Launch requires room for three standard descriptor destinations in the child
and three additional parent slots: one for `/dev/null` and a small two-slot
reserve for transient spawn/dispatch monitoring. Caller-created pipes are
already included in the count and are not charged again. A complete snapshot
showing insufficient headroom returns typed `Failure.localResourceExhausted`
with fixed `local_resource_exhausted` classification before spawn or
acknowledgement. Caller-owned streams and process limits remain untouched.

Unavailable, incomplete or over-capacity inspection skips this advisory guard;
it does not manufacture a resource shortage. Concurrent activity may change
headroom after inspection. The guard reserves nothing, calls no `setrlimit`,
and cannot guarantee a launch: existing OS errors, suspended-start ownership,
process-group acknowledgement, output drainage and teardown remain authoritative.
No background sampler, user setting, payload diagnostics or model call is added.

Offline `SubprocessSupervisorTests` inject unavailable, exhausted and exact-boundary
snapshots, check zero launches on rejection, preserve pipe flags/limits, and
retain normal supervision and OS failure handling. Tests do not lower the
controller's resource limits or deliberately exhaust its descriptors.
