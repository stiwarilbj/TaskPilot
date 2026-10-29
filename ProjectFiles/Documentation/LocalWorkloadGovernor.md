# Shared local workload admission

`LocalWorkloadGovernor` is a process-local, thread-safe coordinator shared by
capture, compression, synchronous Accessibility traversal, runtime pipe writers,
and subprocess supervisors. It adds admission accounting; it does not execute
actions, change task authorization, replay mutations, or replace component caps.
No prompts, paths, pixels, commands, credentials, generation IDs or model output
enter its records. Reservations use ephemeral opaque IDs. Snapshots contain only
fixed categories and numeric counts, remain in memory, and add no timers.

## Pressure and capacity

Admission combines all current reservations, including queued work, with the
caller’s existing monotonic deadline. Shared totals are updated under a short
lock in constant time; no queue scan or cross-process I/O happens under that
lock. There is no new waiting queue: optional work returns a typed deferral to
its existing refresh schedule; required work exceeding available shared capacity
returns a typed local-resource error through its existing failure path.

- Owned memory is estimated, with a budget of physical memory / 32 clamped to
  64–256 MiB. Optional previews and routine maintenance leave 32 MiB of that
  budget for required work. These are estimates of instrumented retained memory,
  not total RSS or a limit on another process’s allocations.
- Optional work defers at 16 queued reservations or on macOS warning/critical
  memory pressure. A normal notification restores optional admission. The same
  memory-pressure source still evicts disposable caches only on warning/critical.
- Required non-transport work has a 64-reservation backstop. Existing capture
  frame/queue limits, pixel bounds, encoder limits, IPC byte/frame limits and
  priority reserve remain hard caps.
- Cancellation, bridge responses and terminal/control IPC use the writer’s
  existing priority classification. They bypass shared pressure/capacity gates
  while retaining the writer’s hard caps, deadline and framing behavior. Their
  retained bytes still appear in shared accounting. Started frames finish their
  suffix under the existing transport timeout; pressure does not truncate them.
- Descriptor demands are compared with OS process headroom plus outstanding
  reservations before expensive acquisition, encoding or launch. This is
  conservative, advisory headroom, not an OS descriptor reservation or a change
  to process limits. Unknown headroom retains existing native error handling.
- Encoding reserves estimated temporary bytes by filesystem device. Concurrent
  encoders on the same volume must fit together. The existing capture reserve
  and bound-owner disk check remain in force; a fresh no-follow volume snapshot
  is checked again after worker scheduling, before PNG compression. No user
  output files are pruned or allocated by the governor.

Required work already admitted is not revoked merely because pressure rises.
Additional allocations and fresh descriptor/disk headroom still require checks.
Expiry or rejection never proves that an already-dispatched mutation failed.
Existing receipts, ownership and reconciliation remain authoritative.

## Reservation boundaries

`CaptureAcquisitionQueue` reserves configured maximum pixel storage before
requesting pixels and accounts for queued requests. `ScreenCaptureService`
supplies separate evidence/preview estimates. The accepted frame replaces the
estimate with actual row-padded storage and relinquishes transient descriptor
headroom. Retaining a `CapturedFrame` retains its reservation. Viewer acquisition
owns its reservation only through returning the frame; existing viewer images
are not described as governed retained evidence. A deferred preview keeps the
viewer’s last image and retries on its existing refresh schedule.

`CapturePNGEncoder` separately reserves working-memory estimates, two transient
descriptors and temporary disk headroom. Queued cancellation releases immediately.
Active cancellation keeps the reservation until native compression drains and
partial artifacts are discarded. Coalesced/rejected requests release before
resuming their continuation, even if that consumer is not scheduled promptly.

`ObservationCollection` reserves estimated bounded graph storage around its
synchronous traversal. It checks the caller before admission and releases in a
defer, including thrown cancellation or AX errors. It adds no AX queue and never
silently treats a denied traversal as an empty or complete observation.

`RuntimePipeWriter` reserves before payload evaluation and updates to actual
retained bytes before enqueue. Full delivery releases before the completion
callback; cancellation, admission failure, deadline rejection, failed writes and
writer destruction release remaining reservations. Priority bypass never changes
FIFO ordering. A shared-capacity failure uses `transport_local_resource` and the
existing conservative task-drain/receipt-reconciliation path.

`SubprocessSupervisor` reserves controller-side launch/monitoring memory and
descriptor headroom before spawn. A failed launch releases immediately. Once
launched, ownership lasts through the entire supervised tree, including children
outliving their parent. Parent exit alone cannot release it. Output buffers keep
their existing separate bounded drainage ownership.

The Gateway host marks only ordinary periodic audits as disposable. Startup/full
integrity audits, changed installations, explicit fault checks and repairs remain
required. A deferred routine audit is retried after 30 seconds using the existing
host loop; no failed audit is recorded and no repair or restart is triggered.
Separate TaskPilot processes have separate accounting; OS memory-pressure and
descriptor/disk observations provide external headroom signals.

## Offline validation

```sh
swift test --package-path ProjectFiles --filter 'LocalWorkloadGovernorTests|CapturePipelineTests|MemoryPressureTests|RuntimeTransportTests|ObservationCollectionTests|SubprocessSupervisorTests'
```

Synthetic tests inject pressure, clocks, capacities, images, writers and native
read providers. Pipeline fixtures use an isolated governor rather than depending
on the machine's ambient memory pressure. They check combined admission, reserved essential/terminal
capacity, volume isolation, expiry, exactly-once release, coalescing, cancellation,
partial writes, launch failures and tree teardown. Existing tests retain component
limits, frame order, callback counts, task ownership and raw-image identity.
No generation, screenshot acquisition, fixer, live-control tester, Chrome or
desktop task is used. Live pressure/desktop behavior remains unvalidated.
