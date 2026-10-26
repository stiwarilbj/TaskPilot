# Bounded private IPC

`AgentRuntime/bounded_transport.py` provides stdlib-only JSON-line framing,
request mailboxes, ACP routing, and deadline-bound nonblocking writes. Native
framing lives in `RuntimeLineBuffer`; `RuntimePipeWriter` owns native writes.
These changes add no model calls or public protocol fields.

## Bounds and routing

- A frame is at most 8 MiB, excluding LF. Readers consume 64 KiB chunks, preserve
  fragmented UTF-8, and accept a complete final frame without LF. An oversized
  unfinished frame fails immediately; its remainder is discarded through LF.
- Python mailboxes retain at most 32 MiB of wire payload, 1,024 ordinary
  messages, and 32 registered requests. Eight MiB and 32 additional terminal
  slots are reserved from ordinary traffic. Object counts also bound tiny-frame
  floods; decoded objects have additional interpreter overhead.
- Register a request before sending it. ACP replies route by JSON-RPC ID;
  stream events route by session and request ID when supplied. Legacy events
  lacking a request ID require exactly one pending prompt for that session.
  Native bridge and secure-input replies additionally match kind and generation.
  Unknown, stale, duplicate, and post-terminal replies retain no payloads.
- Stream chunks, errors, action results, and secure-input replies are never
  coalesced. Only identical consecutive status snapshots within their status
  channel are suppressed. A digest, rather than the status payload, remembers
  an ACP status already consumed. Native duplicate snapshot filtering remains
  invocation-local.
- A terminal reply occupies its own slot, after its preceding chunks. EOF is
  out of band. Noise arriving after an intact terminal cannot replace it.
  Exceeding aggregate capacity fails the affected request explicitly; no
  incomplete stream can become a successful response.
- Consumed ACP text and errors share an 8 MiB response budget, with additional
  65,536-chunk and 128-error bounds. Stderr keeps twelve lines of at most 4 KiB.
  Reconnect readers retain their own pipes, transport, EOF event and stderr tail;
  duplicated read descriptors prevent descriptor reuse across invocations.

Native writes retain at most 32 MiB/1,056 frames, reserving 8 MiB/32 slots for
bridge and secure-input replies. A dispatch write source delivers at most
64 KiB per callback; a five-second per-frame deadline handles a stalled reader.
`F_SETNOSIGPIPE` converts a closed pipe into a classified error. Pending native
bridge work is bounded to 32 operations/32 MiB, with one operation and 8 MiB reserved for receipt
lookups. Main-queue events are bounded to 4,096/8 MiB; terminal delivery bypasses
this ordinary event budget. No unbounded queue of distinct status updates can
form behind the main thread.

## Failure and cancellation

Transport errors carry specific `transport_*` codes, not format-repair errors.
ACP faults close and wait for the originating child. The existing one-reconnect
path still requires an acknowledged Gateway abort before replaying reasoning.
Neither partial text nor silence triggers another request.

A native action whose reply is lost retains its logical ID. A connected inbox
fault enters the existing bounded, read-only receipt lookup; the action is never
redispatched. If the native transport itself fails, ownership is revoked, native
operations drain, and the native receipt store is inspected before reporting the
terminal failure. Unconfirmed GUI effects remain unconfirmed. No receipt or
transport condition proves whole-task completion.

Stop uses the existing out-of-band process signals and revokes authority before
teardown. It cancels pending writers without waiting for pipe capacity. A helper
that ignores termination is killed after two seconds; queued tasks still wait
for native drainage and cleanup. Terminal helpers get five seconds to finish
their normal cleanup before forced termination. Exit drains are nonblocking and
bounded to 32 MiB per pipe, so a descendant retaining a pipe cannot stall Stop.
Only codes/counts are diagnostic; no payloads or secure-input values are logged.

## Offline verification

`test_bounded_transport.py`, `RuntimeTransportTests`, existing line-buffer,
receipt, provider-error and ownership tests cover framing boundaries, unfinished
floods, status coalescing, streamed chunks, out-of-order replies, reserved terminal
capacity, aggregate overflow, stale sessions/generations, EOF, stalled/closed
pipes, Stop escalation, and receipt reconciliation without replay. Fake ACP
executables and native pipe fixtures do not contact providers or control apps.
Live desktop/provider accuracy validation remains incomplete.

## Local deadline admission

The writer captures the caller's existing local-operation budget across I/O
queue submission. Runtime messages check it before JSON encoding; writer payloads
are evaluated lazily only after admission, then checked again before queueing.
An untouched queued frame is checked before its first write. Expiration settles
its completion and queue ticket once through the existing classified transport
failure path. It does not prove that an associated action failed. A frame with
any bytes already written finishes its suffix under the existing transport
write timeout, preserving framing and receipt reconciliation.

Capture reservations check the stored caller deadline before grant, without
borrowing the cancellation state of the task releasing the previous slot.
Acquisition checks again before pixels are requested. Compression checks before
scratch setup, job admission and worker start. Expired queued jobs release their
accounting and continuation without encoding; running native compression still
drains before releasing capacity, and late artifacts are discarded. These
checks add no timers, captures, or model calls and never reset the allowance.

Offline regression: `swift test --package-path ProjectFiles --filter
'CapturePipelineTests|RuntimeTransportTests|LocalOperationBudgetTests'` includes
fake-clock admission, queued expiry, partial-frame delivery, successor isolation,
and the distinction between rejected and dispatched/unconfirmed receipts.
