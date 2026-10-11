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
