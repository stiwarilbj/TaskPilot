# Runtime snapshot notifications

Each runtime invocation owns a small filter on its serialized I/O queue. It
compares the last scheduled status and diagnostic snapshot independently,
before allocating main-queue work. An exact repeat is suppressed even while
the first notification is still queued. Distinct transitions are all scheduled
in order, including returning to a previously seen value.

Status comparison preserves the original string without trimming or hashing.
Diagnostic comparison uses the entire decoded `AgentRequestMetrics` value,
including optional/private fields and the distinction between unavailable and
zero counts. No serialization, timers, persistent cache, or model calls are
introduced. Only one value per channel is retained for the invocation.

Pause, Resume, secure-input requests, and accepted credential replies invalidate
status suppression because the coordinator updates status at those boundaries.
A new task starts with an empty filter. Output/action results, model health,
secure-input events, and terminal events bypass snapshot suppression. Shutdown
status reports also bypass it, even when their text appeared earlier. Existing
ownership checks, Stop handling, output drainage, terminal uniqueness, and
cleanup remain responsible for whether those events are deliverable.

Regression tests exercise 10,000 interleaved duplicate pairs, every metric field,
distinct transitions, event delivery, and invalidation. Disposable runtime
fixtures verify a streamed duplicate burst, two native bridge results, repeated
output/health events, a completion without a final newline, new invocations,
Pause/Resume, and secure-input continuation. Existing Stop and stale-generation
tests remain in place. No desktop controls, Chrome, fixer, provider calls, or
live-control tester are used; live desktop validation remains incomplete.
