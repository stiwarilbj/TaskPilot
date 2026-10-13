# Revision-scoped state fingerprints

The backend retains canonical JSON and its SHA-256 fingerprint once for each
unchanged observation or evidence-ledger identity. Repeated local screen checks
also reuse the existing semantic progress representation for each app PID.
Immutable exact task inputs compute their original identity once. The final
decision identity reuses its hash while its complete input tuple remains equal.

Content snapshots detect nested changes without JSON encoding. They distinguish
booleans, integers, floating-point numbers and signed zero, and disregard object
key ordering. A changed observation or ledger identity invalidates all derived
representations. Existing ledger fingerprint contents and proof rules remain
unchanged: facts and actions have their validated, per-record fingerprints, while
requirements, proof validity, origin, effect checks and coverage remain current.
Prompt projections are still rebuilt from current evidence; they cannot mutate
the fingerprint snapshot. No native inspections or consistency captures are
skipped by this cache.

Observation state lives alongside the existing task-scoped screenshot buffers.
Its identity includes the screenshot path and accepted observation revision.
A content guard catches accidental edits and reused revisions. Equal copies of
the same observation reuse the same representations.
Discard releases derived strings, fingerprints and snapshot data even when the
temporary screenshot is already missing. Scope teardown clears all remaining
state, and generation checks prevent a stopped task from accessing it. Readiness
checks use their separate existing scope. Nothing is persisted to task history,
diagnostics or disk.

Decision keys include a private fingerprint-format version and the existing
validation, contract, purpose, instruction, image and evidence identities. Only
the existing validated nonmutation decisions can be reused, and every cache hit
is revalidated. Actions, observations, provider requests, repair budgets and
fresh completion sessions retain their existing behavior. These changes add no
model calls, frontend controls or setup steps.

Offline tests count actual serialization and hashing, exercise the real ACP
serializer with fake transport, and cover fresh observations, nested changes,
proof invalidation, repaired output, mutation exclusion, cancellation and cleanup.
Live desktop accuracy remains unvalidated.
