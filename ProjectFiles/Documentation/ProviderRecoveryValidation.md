# Provider error recovery validation

The runtime preserves available provider error codes, HTTP status, ACP error
codes, quota scope, retry timing, and failed upstream model attempts. Structured
errors survive ACP RPC responses, stream notifications, terminal results, JSONL
transcripts, Gateway transcript recovery, and provider error JSON returned as
text. Raw envelopes remain in memory; the readiness file contains only
normalized identifiers and policy facts.

Recovery distinguishes explicit account/project limits from limits containing
a model dimension. A quota code or the word “daily” alone does not establish
account-wide scope. Shared cooldowns invalidate sibling verification and block
generation before a reported reset. Recovery retains the existing two-extra-
Lite-request budget and stops when OpenClaw has already exhausted recovery.
Structured upstream attempts prevent duplicate requests to models already
tested by OpenClaw. Ordinary readiness reads make no generation requests.
An explicit readiness Check can probe once when a shared exhausted quota has
no reported reset, allowing repaired billing/quota to become verified again.

Readiness-state write transactions perform bounded cache pruning. They inspect
at most 64 credential namespaces and 128 runtime identities per write. They
also inspect at most 128 verification timestamps, 128 ordinary model-health
entries, 128 managed-health namespaces, and 128 managed model-health entries
per write. Visited dictionary slices
rotate to the end of their existing JSON objects, so an active or unexpired
prefix cannot starve later obsolete entries. The validated
rollback descriptor and referenced metadata are cached by file identity and
timestamps within each runtime-state instance. A
verification timestamp expires only after the same ten-minute cache lifetime
used by readiness lookup; malformed or future timestamps are retained. The
active identity, the identity described by the rollback runtime when it can be
validated, records with an active single-flight lease, invalidation markers,
unknown record fields, and any uncertain rollback state are preserved.

Pruning never deletes entries from `credential_health`, so reported account-wide
quota restrictions—including a quota with no known reset—survive cache cleanup.
Model cooldowns are removed only when their explicit finite reset time has passed;
repair failures and malformed or indefinite cooldowns remain. Managed-health
namespaces for the current and validated rollback installations are retained.
Pruning runs only as part of an existing write and adds no provider checks.

Successful provider verifications retain their wall-clock timestamp and a
versioned monotonic timestamp paired with the operating-system boot-session
identifier. A cached success is usable only on the same boot with a valid,
non-regressing monotonic clock and an age under ten minutes. Wall-clock jumps
within that boot do not expire or extend the cache. A reboot, unavailable boot
identity, legacy timestamp-only entry, malformed stamp, or monotonic regression
requires a fresh verification. Model and credential cooldown records are not
modified by clock-cache validation.

Regression coverage includes healthy execution, model-specific fallback,
shared quota exhaustion, reported resets, cancelled/interrupted waits, cached
shared limits, credential changes, upstream attempt exhaustion, anonymous
account errors, credential rejection, malformed output, format repair,
provider retry counts, stale session/request errors, partial output followed
by error, and successful recovery followed by complete output. Existing tests
continue covering reconnect acknowledgement, delayed terminal output, and
completion during process exit. These checks use fixtures and make no live
provider or desktop-control requests.

Full Python, Swift, and setup integration suites and signed-bundle packaging
passed for delivery: 220 Python tests, 117 Swift tests, and the mock setup
integration suite. The rebuilt bundle passed strict code-signature verification
and its packaged runtime loaded successfully with `--help`.
Live provider/control accuracy remains unverified for
this change: no live-control tester, TaskPilot fixer, Chrome interaction, or
live ACP task is run. The installed ACP bridge may omit provider metadata;
TaskPilot preserves supplied fields and leaves missing scope unknown.

References: [OpenClaw model failover](https://docs.openclaw.ai/concepts/model-failover),
[Gemini API rate limits](https://ai.google.dev/gemini-api/docs/rate-limits).
