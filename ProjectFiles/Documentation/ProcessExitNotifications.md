# Command process exit notifications

Task commands, syntax/help probes and OpenClaw's local status/dashboard helpers
install a [Foundation termination handler](https://developer.apple.com/documentation/foundation/process/terminationhandler)
before launch. Each invocation owns a locked exit status and notification
signals. An exit before the worker starts waiting is retained; a late callback
can only settle that invocation. The existing ACP runtime already uses its own
termination callback and output-drain path.

Workers wait on notifications with a monotonic execution deadline instead of
polling `isRunning` every 25 or 50 milliseconds. Timeout, command cancellation,
Swift task cancellation and task revocation wake the wait. Shutdown resumes a
paused command, sends termination, waits at most one second for graceful exit,
then kills the owned process group when necessary. It still awaits actual exit
before releasing resources or handing off work. An incomplete teardown cannot
authorize completion. Pause/Resume and the execution timeout policy are retained.

Lease revocation observers are removed when their operation ends and consumed
once on revocation or retirement. They only wake their originating wait; native
signals stay with the worker's captured process. Stop, Pause and Resume capture
the process under the existing command lock, so later signals cannot look up a
different invocation.

Probe output limits use file-write/extend notifications on the two existing
output files, with a final size check for delayed or coalesced events. Monitoring
stops before handles close. Normal task stdout/stderr are synchronized and read
after exit, including final writes from a termination handler. Timeout or
cancellation cannot turn those writes into a successful command result.

OpenClaw status output now spools into a private temporary directory (0700) and
file (0600), preventing a verbose status command from filling an unread pipe.
After actual exit, the file is synchronized and read before returning; every
path removes the temporary resources. Dashboard output continues going directly
to the null device, so authenticated local URLs are not captured or surfaced.
Existing exit-code, timeout and outcome-check semantics remain unchanged.

Native regression fixtures cover immediate exits, retained notifications,
terminal stdout/stderr, graceful and forced timeout, cancellation without an
explicit executor stop, paused lease revocation, removed observers, large
status output, launch failure and later executor reuse. Existing probe-limit,
receipt, command outcome and runtime-drain checks also remain in the suites.
These tests use disposable local processes and files; no fixer, live-control
tester, Chrome, live desktop task or provider request is run. Live accuracy
validation remains incomplete.

This removes periodic process-status wakeups; it does not add model requests,
change prompts, model defaults, the action contract, permissions, setup, cleanup
preferences or the interface. Task-level performance is not benchmarked here.
