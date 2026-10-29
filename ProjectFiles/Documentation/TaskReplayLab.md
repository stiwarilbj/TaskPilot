# Offline task replay lab

Run on macOS with Swift and Python 3.11 or newer:

```sh
python3 ProjectFiles/Scripts/replay-task-traces.py
python3 ProjectFiles/Scripts/replay-task-traces.py --trace stop_at_delivery --seed 3
python3 ProjectFiles/Scripts/replay-task-traces.py --list
```

The runner prints only fixed trace codes, unsigned seeds, and scheduled event
names. An assertion includes its trace and seed. The full run repeats every
trace/seed twice and compares the outcome and scheduled order. Set
`TASKPILOT_REPLAY_PYTHON` to a Python 3.11+ executable when running `swift test`
directly; its default is `/opt/homebrew/bin/python3.11`. The runner supplies its
own interpreter automatically. No installed OpenClaw, API key, app permission,
fixer, browser, live-control tester, or desktop task is needed.

## What actually executes

`TaskReplayLabTests.swift` starts `Tests/ReplayLab/runtime_worker.py` through the
real `AgentRuntimeProcess` and supervised subprocess pipes. Python uses the
real startup compatibility checks, `RuntimeInbox`, task context/state machine,
prompt builders, response validation, model router, action envelope, receipt
reconciliation, evidence ledger and independent completion verifier path.
Swift uses the real line decoder, invocation ownership, event delivery,
`RuntimePipeWriter`, task lease, atomic dispatch boundary and action receipts.
Receipt lookup and completion acceptance go through `AgentAutomationBridge`.

Only external readiness/provider responses, desktop acquisition and settling,
and the executable desktop effect are synthetic adapters. The provider produces
one fixed fictional task; an in-memory integer stands in for the app's button
counter. Acquisition uses a temporary non-image marker inside controller-owned
test scratch space, removed on observation disposal or after drainage (including
deliberate abrupt worker exits). No screenshots or desktop input are created. The
settling adapter supplies a fresh observation; it does not claim effect proof.
The model must inspect the counter before proposing completion, and the existing
final verifier audits fresh ledger evidence. A delivered press stays explicitly
unconfirmed in its receipt.

The only production seam added is an internal defaulted pipe-write operation on
`AgentRuntimeProcess`, forwarded to its existing writer. Production still calls
`Darwin.write` unchanged. Tests cap each real controller write at seven bytes;
worker stdout writes at most eleven bytes at a time. Wire bytes, framing,
ordering, callbacks and native invocation handling remain production code.

## Trace boundaries and invariants

The shared `Tests/Fixtures/task-replay-traces.json` catalog contains only a closed
vocabulary of trace/fault/event codes, bounded ticks, and seeds. The bounded
reader rejects duplicate keys, extra fields, arbitrary payload strings, invalid
numbers and oversized catalogs. There is no recorder or import of user traces.
Do not put saved requests, model output, paths, commands, screenshots, credentials
or captured app data in fixtures. New behavior belongs in explicitly synthetic
adapters and corresponding allowlist/test changes.

`SeededLifecycleScheduler` controls logical time. Barriers wait for actual model
and native preflight arrivals before releasing the next event, rather than
depending on OS timing. Equal-tick events use the same xorshift64 ordering in
Swift and Python. Seeds 1 and 3 exercise Stop before and after atomic delivery.
Watchdog timeouts detect a hung test; they do not define the race order.

| Trace | Injected condition | Required result |
| --- | --- | --- |
| healthy | Fragmented IPC in both directions | One press; normal two plans and final verification |
| lost_reply | Drop the received action acknowledgement at the Python consumer boundary | Reconcile the same native receipt; inspect fresh outcome; no redispatch or extra model calls |
| stale_observation | Reject first preflight before delivery | Fresh observation and replanning; exactly one actual press |
| stop_at_delivery | Release Stop and preflight at the same logical tick | Zero or one press according to seed; one Stop callback; no later delivery |
| exit_after_dispatch | Worker exits after receiving the action response | One press; failure once; no verifier or replay |
| disconnected_reply | Consumer loses the connection after delivery | Reconciliation then drainage with pending mutation; no new plan, completion or replay |
| malformed_result | Contradictory native success fields | Protocol failure with pending mutation; no false proof, verifier or replay |

Each run checks terminal callback uniqueness, all bridge handlers settling before
native retirement, receipt certainty and bounded dispatch counts. Native bridge
fixtures also reorder delayed old-owner and foreign-generation actions against a
current receipt query; old work must neither deliver nor change the new task.
Existing seeded pipe/subprocess tests separately check per-frame completion
uniqueness, cancellation, EAGAIN, partial output drainage and descendant teardown.

The CLI optionally filters a trace/seed, then runs the offline Swift suite under
a 240-second outer watchdog. Python unit tests independently check catalog privacy,
bounds and known seed orders. Run the full Python and Swift suites, setup
integration, generated-artifact check and offline prompt regression checks for
delivery. This lab is test support only and is not copied into the app bundle.

These tests make selected cross-component races reproducible. They do not model
every possible OS interleaving, prove real AX targeting accuracy, or establish
provider availability. Live desktop validation remains incomplete.
