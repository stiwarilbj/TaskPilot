# Requirement evidence and completion

`AgentRuntime/task_evidence.py` owns an in-memory checklist and evidence ledger
for the current task generation. The first planning response proposes all
requirements, quoting the original request. Runtime-assigned IDs remain stable
throughout the task. Model claims cannot create native proof.

Validated native results establish only their acknowledged scope: exact file
paths and byte hashes, complete reads, individual command outcome checks, or
historical execution. Exit zero alone establishes command execution. Desktop
delivery or focus never establishes saving, sending, or submission. Accepted
observations provide evidence for visual outcomes assessed by the existing
final verifier.

Mutations conservatively invalidate mutable proof. Before final verification,
the private `recheck` bridge inspects relevant native file outcomes without
replaying writes or launching commands. Historical execution facts survive.
The complete ledger outlives the recent action history; prompt excerpts of long
values retain their full length and hash, while exact contents stay in memory.

All completion paths use the same coverage gate. The existing final verifier
audits the complete original request, adds omitted requirements, and cites
matching evidence for every entry. A global `verified: true` or an empty
remaining-work list is insufficient. Semantic coverage and visual proof still
depend on this verifier; they are not deterministic guarantees of accuracy.

Only full-request local grammars bypass model verification: an exact request
for a file's complete contents or the largest top-level Downloads file. Extra
instructions disable these shortcuts. Truncated reads remain incomplete. Full
native output can be returned using validated evidence references rather than
asking a model to reproduce it.

Checklist metadata uses the existing one-repair budget. Checklist version and
ledger state participate in decision-cache and offline regression identities;
the generated action contract remains unchanged. Only aggregate diagnostic
counts are added to persisted task metrics. Evidence, task IDs, raw responses,
commands, and credentials are not added to persistence.

Validation covers every completion path, exact contents and destinations,
omitted requirements, forged references, freshness, complete output, long
histories, repair limits, and mutation execution once. Native readback tests
cover UTF-8, binary and empty files, bounded reads, independent command checks,
and revoked ownership. The offline fixtures include partial multi-file
completion and successful writes with incorrect contents.

Live desktop accuracy remains unvalidated. This change was checked without
the fixer, live-control tester, Chrome interaction, live desktop tasks, or
provider requests.
