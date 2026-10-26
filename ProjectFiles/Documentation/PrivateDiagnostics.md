# Private diagnostic allowlists

Diagnostics use fixed schemas at both boundaries that can retain data.
Unrecognized fields, strings outside the declared enums, booleans in numeric
slots, nested objects, and counters outside `0...1,000,000,000` are rejected.
Rejection drops the diagnostic record or event and never changes task execution.

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
