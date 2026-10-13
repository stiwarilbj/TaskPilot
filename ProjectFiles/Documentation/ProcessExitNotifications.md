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

Task commands and syntax/help probes drain both pipes continuously on an
invocation-owned queue. Each stream retains up to 32 KiB in memory, creating a
private spill directory (0700) and file (0600) only when needed. Task output
retains the existing 64 KiB per-stream limit; excess bytes are drained and
discarded without growing memory or files. Help probes count all drained bytes
against their existing combined limit and interrupt the owning wait when it is
exceeded. Storage errors also wake that wait while readers continue draining.

After actual exit, a final nonblocking drain collects terminal writes before
readers retire. Cancellation handlers close their readers and acknowledge
retirement before descriptors can be reused. An inherited writer cannot hold
teardown open: an unclosed stream is marked incomplete and cannot prove an exact
stdout outcome. Spills are
synchronized and read before returning and removed on every cleanup path.
Timeout or cancellation cannot turn captured output into a successful command.

OpenClaw's local status helper uses the same buffering with a single merged pipe,
preserving combined stdout/stderr order and its existing full-output behavior.
Short status output needs no temporary files. Incomplete status output is an
error. Dashboard output still goes directly to the null device, so authenticated
local URLs are not captured or surfaced. Exit codes and outcome checks are
unchanged.

Native regression fixtures cover immediate exits, retained notifications,
terminal stdout/stderr, graceful and forced timeout, cancellation without an
explicit executor stop, paused lease revocation, removed observers, large
status output, launch failure and later executor reuse. Buffer fixtures cover
memory/spill boundaries, simultaneous noisy streams, retention caps, UTF-8,
private file permissions, spill failure, inherited writers and resource cleanup.
Existing probe-limit, receipt, command outcome and runtime-drain checks also
remain in the suites.
These tests use disposable local processes and files; no fixer, live-control
tester, Chrome, live desktop task or provider request is run. Live accuracy
validation remains incomplete.

This avoids temporary output files for short commands and periodic process-status
wakeups; it does not add model requests or change prompts, model defaults, the
action contract, permissions, setup, cleanup
preferences or the interface. Task-level performance is not benchmarked here.
