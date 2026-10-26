# Private backend phase measurements

`BackendTelemetry` uses `OSSignposter` with subsystem
`com.orbitagent.controller` and category `BackendPhases`. Each invocation gets
a distinct signpost interval ID, including overlapping intervals. Names are
fixed; metadata accepts only outcome codes, durations, byte counts, and item
counts. It never accepts task contents, commands, paths, credentials, screenshot
pixels, control labels, errors, or task/generation identifiers. Credential-bearing
startup and secure-input frames expose timing without their byte lengths.

Numeric metadata is public within Apple's local logging system so Instruments
can display it. There is no remote export, task-history field, UI, or automatic
report file. The in-process recorder keeps at most 128 samples per phase in
bounded rings. Developer fixtures can inject an isolated recorder. End records
use `fields` presence bits: 1=input bytes, 2=output bytes, 4=items. Absent fields
display zero without meaning measured zero. Outcomes are 0=success, 1=failure,
2=cancellation, 3=abandonment. Intervals close once; subsequent finish calls do
nothing. Median/p95 summaries include successful samples only, using nearest
rank; individual numeric samples retain failures and cancellations.

| Interval | Boundary and size |
| --- | --- |
| Runtime Startup | Startup validation, native process launch, initial private configuration, through the first accepted readiness frame; older helpers use their first recognized protocol frame. Stops/early exit close it unsuccessfully. |
| Task Capture | Permission/content/display preparation through accepted screenshot pixels and coordinate validation, before PNG encoding. Items are pixels. |
| Preview Capture | Separate local viewer capture through returned pixels. |
| AX Collection | Each existing collection/traversal/expansion batch, including its AX attribute reads. Items count included controls. App/window root discovery outside traversal is excluded. Staged observations can produce multiple batches. |
| PNG Encoding | Existing ImageIO PNG encoding and file output; raw and encoded byte counts plus pixels. Includes an optional file-size read. |
| JSON Encoding / Decoding | Native runtime JSON serialization/parsing and task-ledger codecs, including failures. Bytes reflect the encoded frame/file where safe. |
| IPC Receive | One runtime line's decode, ownership checks, and dispatch scheduling; excludes waiting for a line/provider response. |
| IPC Send | End-to-end write to the originating private pipe, including time queued behind prior frames and pipe backpressure. Bytes include the newline where recorded. Do not interpret this span as pure processing time. |
| IPC Bridge | End-to-end owned bridge handling from accepted request through response encoding and private-pipe delivery, or rejection/cancellation. Includes bridge-task and response-queue waits, so it is not pure processing time; queue histograms report admission waits separately. Can overlap capture/AX/action intervals. |
| Command Launch | `Process.run()` inside the existing ownership/delivery gate. Counts arguments excluding executable; also covers existing syntax/probe process launches. Execution, timeout waits, and output drainage are excluded. |
| Persistence Read / Write | Entire existing task-ledger load/save, including queued codecs, atomic write, and permissions. File bytes and entry counts only. |

These are wall-time intervals, not CPU measurements. Nested intervals must not
be added to infer total latency. Python Base64 encoding and ACP/provider waits
are outside this native instrumentation. Measurements never create observations,
actions, retries, or model requests. They do not change readiness or completion.

## Queue wait histograms

Queue tickets capture a monotonic enqueue time before submission and close at
the first execution or admission boundary. Fixed-size counters stay in memory
for the recorder lifetime; no individual enqueue times, payloads, task IDs, or
event histories are retained. Buckets have upper bounds of 0.1, 1, 5, 10, 50,
100, 500, 1,000, and 5,000 milliseconds, followed by overflow. Started work
and work cancelled, rejected, coalesced, or abandoned before start have separate
counts and share a per-queue maximum wait.

| Queue | Enqueue to start boundary |
| --- | --- |
| Runtime I/O | Before async/sync submission to the serialized runtime queue; first instruction of the queued closure. Calls already executing on that queue are direct and have no wait sample. |
| Bridge task / observation task | Before creating the bridge task; its first instruction. Observation task wait is scheduling only; AX Collection remains the synchronous traversal span. |
| Main event delivery | Before `DispatchQueue.main.async`; first instruction of its main-queue closure. The later runtime I/O ownership check is measured separately. |
| Evidence / preview capture | Before capture actor submission; when a reservation is granted. Preview replacements count as coalesced before start. |
| PNG compression | Before encoder actor submission; first instruction on the detached compression worker. This includes actor admission, the encoder backlog, and worker scheduling. |
| Pipe first write | When a frame is accepted by the private writer; immediately before its first write attempt. Later partial writes and backpressure remain in the end-to-end IPC Send span. |

Intentional timer delays, provider-response waits, Pause time, and periodic drain
polling are excluded. Queue wait is not processing duration; existing phase
spans measure work after it begins. Overlapping wall-time spans must not be
subtracted or summed to infer CPU time. Signposts use fixed queue names and
numeric disposition and wait fields only.

## Memory high-water marks

The in-process recorder also keeps fixed stage peaks accessible through
`BackendTelemetry.memoryHighWaterMarks()`. It reports the maximum simultaneous
count and byte estimate for frames waiting in the bounded PNG queue, active
PNG input buffers, and runtime events retained for main-queue delivery after
snapshot filtering. A capture frame's byte estimate is `bytesPerRow × height`;
a runtime event uses its bounded event-size estimate. Tickets close on cancellation,
coalescing, completion, and abandonment, so the stage gauge falls as ownership
ends while its maxima remain for the recorder lifetime. These counters stay in
memory and contain no task identifiers or payloads.

## Offline baseline

Measured on 2026-10-13 with the SwiftPM debug build on this Apple Silicon Mac.
Each workload performs 30 repetitions, including its first cold sample, without
Instruments recording enabled. IPC receives have 90 samples; sends and runtime
JSON encoding have 60. These small local samples estimate fixture variability,
not production tail latency. Input is synthetic; files/processes are disposable.

| Workload / interval | Median ms | p95 ms |
| --- | ---: | ---: |
| 80 in-process controls / AX Collection | 0.233 | 0.243 |
| 1,280 in-process controls / AX Collection | 43.606 | 44.529 |
| 1,280 controls, 105,144 bytes / JSON Encoding | 1.123 | 1.148 |
| Solid 640×360 image / PNG Encoding | 1.192 | 1.273 |
| Solid 2560×1440 image / PNG Encoding | 15.766 | 16.210 |
| 10 synthetic ledger entries / Persistence Write | 0.187 | 0.241 |
| 1,000 entries, 104,914 bytes / Persistence Write | 1.430 | 1.462 |
| 1,000 entries / Persistence Read | 1.258 | 1.277 |
| Short disposable command / Command Launch | 0.158 | 0.202 |
| Python echo helper / Runtime Startup | 18.579 | 22.728 |
| Echo helper / IPC Receive | 0.025 | 0.040 |
| Echo helper / IPC Send | 0.003 | 0.005 |
| Echo helper / IPC Bridge | 0.074 | 0.083 |

The large-tree fixture grows substantially faster than its control count.
The existing `visited.contains` identity checks are a candidate for dedicated
profiling before a bounded indexing optimization. These fixtures call the real
traversal with an in-process provider: they do **not** measure macOS AX round
trips. PNG encoding is another candidate to measure with representative images;
solid images are unusually compressible. Native IPC writes and short command
launches are much smaller here. The helper's startup cost is not the installed
OpenClaw runtime's startup cost. No app-wide speedup or production bottleneck is
established by this baseline.

Live capture, real AX applications, installed ACP latency, and desktop accuracy
remain unmeasured. No fixer, live-control tester, Chrome interaction, or live
desktop task is part of this validation.

## Reproduction

From the repository root, use an ignored private output directory:

```sh
TASKPILOT_PHASE_REPORT="$PWD/ProjectFiles/.taskpilot-build/phases-benchmark.json" \
swift test --package-path ProjectFiles --disable-sandbox \
  --scratch-path ProjectFiles/.taskpilot-build/swift-build \
  --filter BackendPhaseFixtureTests.testOfflinePhaseBenchmark
```

The developer benchmark is skipped in the ordinary suite unless that output
path is explicitly supplied. Reports contain only fixed workload names and
numeric metrics and are saved with mode 0600. No task evidence is exported.
Run the benchmark without other suites or profiling for latency comparisons.
Use the same build mode and workloads across changes.
The report includes idle and synthetic eight-millisecond queue-wait fixtures,
a serial worker held behind a contended queue, their histograms, paired bridge
spans, and approximate idle ticket cost. Synthetic waits use an injected clock;
the contended fixture uses a disposable serial queue. Capture and runtime
transport fixtures also exercise local queue admission without desktop automation.

To verify emission separately, launch the **XCTest runner**, not TaskPilot, under
Instruments' `os_signpost` instrument. Select the offline benchmark test in the
SwiftPM test bundle and filter to the subsystem/category above. Profiled timings
are excluded from the baseline. An offline Instruments trace verified 810 paired
intervals across the eleven exercised phases, with numeric-only end metadata.
Capture/preview intervals require separately
authorized live validation; the offline fixtures do not exercise them.
