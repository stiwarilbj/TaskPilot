# Private diagnostic allowlists

Diagnostics use fixed schemas at both boundaries that can retain data.
Unrecognized fields, strings outside the declared enums, booleans in numeric
slots, nested objects, and counters outside `0...1,000,000,000` are rejected.
Rejection drops the diagnostic record or event and never changes task execution.

## Linked fault reports

`BackendTelemetry.faults` and Python's task-owned `FaultReports` retain at most
32 episodes (hard maximum 64), for 120 monotonic seconds from the first event.
Symptoms do not extend expiry; clock regression expires the episode. Each
report retains a fixed root cause and first stage, up to 15 consequence counts,
bounded recovery claims, and a bounded duplicate-claim counter. No free-form
text, exception, payload, file path, credential, model response, task identifier,
or screenshot is retained. Reports and their opaque UUIDs never enter history,
decision caches, model prompts, or persisted action diagnostics.

The root is the earliest classified cause established in that explicit chain,
not a guess about an unobserved underlying failure. A linked Gateway failure
may explain a later connection failure. Quota, capacity, command timeout,
configuration, native protocol and unrelated transport failures remain distinct.
Unclassified exceptions use `unknown`; the router's conservative configuration
fallback does not independently prove a configuration defect. Temporal proximity
never merges reports. A later different classified cause starts its own report.

The optional version-1 `backend_fault` IPC record contains exactly `version`,
`fault_id`, `sequence`, `cause`, and `stage`, inside the normal task/revision
envelope's `fault` field. Its alternative `fault_link` contains exactly
`version`, `child_id` and `parent_id`. A live-host Gateway root discovered during
that specific reconnect may adopt its transport symptom. This explicit link
preserves spent recovery claims and bounded consequence counts; quota and
command roots cannot be adopted. Both roots must already belong to the same
invocation, and unknown, self, stale or incompatible links are ignored. Later
callbacks to the child resolve to the parent until expiry. Both languages reject
arbitrary fields and values. The native receiver
imports roots into an invocation-owned scope, requires consecutive sequences,
and discards duplicates, expired links, stale generations and stale revisions.
Malformed diagnostic records are ignored without becoming transport errors or
UI events. Fixed-name `BackendFault` signposts contain only numeric cause,
stage, and consequence codes. The in-memory report distinguishes the root from
its later recovery, waiting, drainage and terminal consequences.

The Gateway host can add the same small root record to existing `health.json`.
This is a transient causal hint, never connectivity or provider-readiness proof.
Python accepts it only for a recovering/needs-repair state from a live host
birth identity, matching instance/installation/configuration, checked within
45 seconds. Healthy state clears the active hint; normal host expiry limits
its lifetime. The hint adds no new diagnostic file or background timer.

Recovery claims coalesce one episode/route/attempt. Duplicate handling of the
same terminal ACP failure cannot reconnect or repeat reasoning again. Existing
request-terminal acknowledgement, provider policy, three-per-ten-minute local
budget, action receipts, reconciliation, cancellation and native ownership gates
remain authoritative. Gateway claims count existing serialized budgeted steps;
diagnostics cannot grant or reset a restart allowance. A delayed command never
requests Gateway recovery. Supported recovery routes cannot be claimed for an
unrelated cause. This does not automatically retry a desktop mutation.

Offline reproduction (no provider or desktop access):

```sh
swift test --package-path ProjectFiles --filter 'BackendFaultReportsTests|RuntimeTransportTests.testFaultReports'
cd ProjectFiles
python3 -m unittest discover -s Tests/Python -p test_fault_correlation.py
```

The shared `Tests/Fixtures/backend-faults.json` asserts the wire vocabulary and
strict field types in Swift/Python. Synthetic tests cover concurrent duplicate
claims, expiry, clock regression, unrelated causes, live-host hints, real native
IPC import, terminal drainage and unchanged provider/reconnect budgets. No live
Gateway outage or desktop accuracy validation is claimed by these fixtures.

## Request metrics

The `request_metrics` event is validated in Python before IPC and again in
`BackendTelemetry.DiagnosticSchema` before the Swift runtime accepts it. The
required fields are `planning`, `verification`, `retries`, `model_switches`,
`cache_hits`, and `reconnects`. Optional fields are `prompt_calls`,
`provider_retries`, `action_deliveries`, `action_rejections`,
`unconfirmed_actions`, `repairs`, `evidence_checks`, `coverage_rejections`,
`requirements_proven`, `dependency_checks`, `dependency_rejections`,
`conflict_inspections`, `evidence_conflicts`, `recovery_cycles`,
`cycle_suppressions`, `receipt_queries`, `receipt_recoveries`, `effect_checks`,
`verified_effects`, `unconfirmed_effects`, `receipt_unresolved`,
`local_notifications`, `local_targeted_checks`, `local_poll_wakeups`,
`command_inspections`, `command_probes`, `command_probe_cache_hits`, and
`command_preflight_rejections`. Only `provider_retries` may be null.

Task history stores the typed `AgentRequestMetrics` value. The history writer
validates every metric again before encoding, so only allowlisted integer
counters can be persisted.

## In-memory stage high-water marks

`BackendTelemetry.memoryHighWaterMarks()` exposes fixed numeric peaks for
queued capture frames, active PNG encodes, and runtime snapshots waiting for
main-queue delivery. Capture byte counts use each `CGImage` row stride times
height; snapshot bytes use the existing bounded event-size estimate. Counts
and byte peaks are kept only in the recorder's memory and are not written to
task history, diagnostic files, or exported reports. The fixed stage enum
cannot retain task data, paths, identifiers, or image contents.

## Action diagnostics

`automation-diagnostics.jsonl` records are projected onto this exact set of
fields: `schema_version`, `timestamp_ms`, `runtime_pid`, `action_type`,
`outcome`, `delivery_method`, `error_code`, `verification_scope`, and
`recovery`. The first four are required; the rest are optional enumerated
values. Action types come from the generated action contract. The writer does
not serialize incoming action/result dictionaries, messages, commands, paths,
labels, model output, or credentials. An unknown enum value rejects the whole
record. The file remains private and bounded to 1 MB.

Relevant offline checks: `swift test --package-path ProjectFiles --filter BackendTelemetryTests`
and `python3 -m unittest discover -s ProjectFiles/Tests/Python -p 'test_openclaw_runtime.py'`.

## Development snapshot-size audit

`DEBUG` builds sample the first and then every 64th admitted event with an
exact serialized runtime source. `processLine` passes only the existing JSON
frame byte count (excluding LF) to `emit`; no payload is copied, re-encoded or
retained for the audit. Sampling occurs after snapshot coalescing and the
unchanged queue admission check. Native-only and deferred terminal events
without a one-to-one serialized source are not sampled. Each invocation owns
its sampling cursor; the existing telemetry recorder aggregates across it.

`BackendTelemetry.snapshotSizeAudit()` exposes exactly two in-memory numeric
aggregates: `underestimationCount` and `maximumShortfallBytes`. Equal or larger
estimates add no underestimation; negative/unknown measurements are ignored.
Updates use the recorder's lock and saturating count arithmetic. There are no
per-event records, category strings, sizes, request IDs, payloads, timestamps,
logs, files, exports or history additions. Release builds compile out both the
sampler and aggregate API/storage.

The actual size is the incoming JSON wire representation, including its
envelope, escaping and whitespace; this is not a heap-size or projected-object
measurement. It provides development evidence for later bound tuning. This
pass changes no estimates, byte limits, coalescing, delivery ordering or
admission/recovery policy. It adds no generations, captures or timers.

Offline checks: `RuntimeSnapshotFilterTests`, `BackendTelemetryTests` and
`TaskOwnershipTests.testStreamedBurstAndExitTailDeliverEachEventOnceInOrder`.
The 1,200-status UTF-8 burst produces 19 sampled underestimates while preserving
every status and the terminal event exactly once. Fake numeric measurements
cover sampling, coalescing, invocation reset, invalid measurements, large
shortfalls and concurrent aggregate updates.

## Owned temporary capture retention

Each `TaskLease` maintains a private capture ledger, with only file count and
retained encoded byte totals exposed by `captureArtifactUsage`. The default
per-owner limits are 128 registered files and 256 MiB. Registration uses regular
file metadata, never image contents or directory scans. Re-registering an
unchanged object is idempotent. Before admission, metadata checks reconcile
paths already unlinked by runtime observation disposal. Limits apply to retained
finished PNGs; the existing bounded encoder pipeline still controls transient
compression work. A limit rejects the new capture and cleans its private PNG,
without evicting a current observation or changing model request policy.

Only `.png` paths immediately inside the owner's private scratch `capture`
directory qualify. Foreign-owner paths, user destinations, symlinks, and
nonregular files do not qualify. Cleanup checks recorded file identity before
unlinking a registered path. No user output paths enter this policy.

An artifact expires on explicit observation rejection/discard or task retirement
after drainage. There is no wall-clock expiry for active task evidence. Native
image sources/readers hold explicit reference tokens; expired referenced files
remain accounted for until their last token is released. Encoder holds defer
whole-scratch deletion until queued/running compression settles, including Stop
and late failure paths. Retirement is idempotent and removes unreferenced expired
captures; deferred releases finish cleanup without a timer. Unchanged live
captures are never evicted merely to meet a cap. Existing private scratch leases
and abandoned-process recovery remain authoritative after a crash.

All bookkeeping is in memory. No filenames, images, ownership identifiers, or
per-file measurements are added to diagnostics/history. Offline reproduction:
`swift test --package-path ProjectFiles --filter 'CaptureArtifactLedgerTests|CapturePipelineTests|AgentActionMagnifierTests|TaskOwnershipTests'`.
Fixtures cover independent owners, count/byte bounds, runtime unlink, native
reader lifetime, partial encoding, retirement, cancellation, and excluded paths.
