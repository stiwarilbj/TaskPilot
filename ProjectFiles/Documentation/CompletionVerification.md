# Independent completion verification

Each existing completion decision uses a fresh ACP session and a unique gateway
session key over the task's current transport. No additional generation is
introduced. The runtime acknowledges model selection and supported thinking
settings for that session before sending the verification request. Setup calls
are configuration RPCs, not generation requests or model switches.

The verifier receives the complete original task, exact task input bindings, a
fresh accepted screenshot/control observation, checklist definitions including
dependencies, and valid task-owned native facts with their evidence IDs and
verification scopes. The curated ledger excludes previous coverage conclusions,
requirement proof claims and invalidated evidence. Planning responses, candidate
completion claims, recovery narratives and unverified recent action descriptions
are not included. Evidence contents remain untrusted data; a checklist can omit
requirements, so the verifier must independently audit the original request.

The existing coverage gate still validates each proof's requirement, target,
scope and freshness. Answers are composed from supplied evidence; completion
output never falls back to the planner's proposed answer. Full file/stdout
results can still be returned verbatim by their validated evidence references.
Exact local completion grammars keep their existing zero-call paths.

One verification decision retains the existing shared format-repair budget and
model fallback order inside its isolated session. Success retains the selected
model for subsequent task work. An unsuccessful final check restores the
planner's session without appending verification conversation to it. Each new
completion check has another fresh context. Validated identical cache hits
remain generation-free; the isolation policy and prompt compiler version bind
both the cache and offline regression packs.

Only updates naming the current session and, when supplied, request ID are
accepted. Transcript recovery reads that session's gateway key. Readers capture
their originating process, output queues and termination event so an ended
transport cannot populate a reconnected client's buffers. Cancellation cancels
the session owning the pending request even after local session restoration.

Transport recovery still reconnects at most once, and only after the gateway
acknowledges that the old verification request ended. It retries reasoning in a
new context. After a terminal verification result it reattaches the saved
planning gateway key through `session/new`, restoring that history without
another generation. Cancellation and failed shutdown acknowledgement do not
trigger reattachment or replay.

Regression tests use a fictional JSON-RPC subprocess, fake transports, native
result fixtures and the offline task-loop corpus. They check independent
sessions, acknowledged settings, stale output, fallback, one repair, cache
identity, cancellation, reconnect and unchanged generation counts. No fixer,
live-control tester, Chrome interaction, live provider or desktop task is run;
live accuracy validation remains incomplete. Fresh context reduces inherited
claims but does not itself prove task success.
