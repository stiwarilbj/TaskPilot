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
