# Contradictory evidence

TaskPilot rejects a decision about a conflicted target before dispatch. It
compares high-confidence local screenshot text with the intended control's
Accessibility label or complete nonsecure field value, using the same app,
window and fully contained bounds. Partial words, unrelated windows, overlapping
controls and low-confidence recognition do not establish a contradiction.
Label matching normalizes whitespace, case and typographic ellipses; field
values retain their case. Missing recognition never proves agreement.

An optional private response field also lets a model report a disagreement it
sees in the existing screenshot:

```json
{"evidence_disagreement":{"element_id":"<current complete ID>","screenshot_text":"<observed text>"}}
```

This shape illustrates metadata, not an executable action. Normal status,
checklist and action validation still apply. The ID must name a current
nonsecure control; text is bounded to 256 characters. Optional `evidence_id`
must reference valid mutable native file evidence belonging to this task.
Reported screen text remains an untrusted claim, not a substitute for a native
target or independent proof.

Inspection makes at most three accepted observations within one shared
two-second deadline, with cancellable native capture/ownership checks and short
local backoff. It prioritizes recognition for the intended app even when its
Accessibility tree is otherwise complete. Agreeing and opposing text remain
visible during inspection; ordinary complete trees still add no OCR work.
Existing secure-field and secure-window exclusions, crop/recognition budgets,
and screenshot/control pairing checks remain in force.

Two matching fresh inspections can supersede an older readback or resolve
opposing labels. Known field readbacks are compared with later complete AX
reads. A prerequisite or final native file check that explicitly contradicts
earlier proof triggers bounded read-only rechecks; a changed complete file read
is compared by validated hash. Unavailable, truncated, malformed or wrong-path
readbacks cannot replace proof. Existence alone cannot verify screenshot text.
File-content associations require the exact reported text to match fresh
complete contents and the independently inspected control.

The original decision is discarded even when inspection resolves its conflict.
The next existing planning request receives the exact opposing sources,
refreshed target and evidence, and an explicit resolution or unresolved state.
Unresolved target disagreements follow fresh revisions. Three consecutive
conflict decisions without a delivered action stop safely. Final verification
cannot authorize completion using conflicted evidence. Historical native facts
remain historical; mutable contradictory proof is revoked before inspection.
No command, submission or other mutation is repeated to settle a discrepancy.

The guard is task-local and in memory. It uses private inspection metadata,
not a new action or user control. Only aggregate inspection/conflict counts
join existing diagnostics; source contents, images and reports are not persisted.
Capture files from rejected intermediate observations are deleted. Generation
ownership, cancellation, permissions, receipts, repair budgets and model defaults
are unchanged. Healthy decisions add zero inspections or provider requests.
Evidence-consistency version 1 participates in startup compatibility and cache
identity; source fingerprints also bind offline regressions to this version.

Offline tests cover the real task loop with fake native delivery, contradictory
and agreeing labels, changed/missing targets, literal fields, file readbacks,
ambiguous geometry, cancellation, deadlines, completion and unchanged healthy
request counts. Swift tests exercise offscreen images and fake recognition;
they never control desktop apps. Live accuracy validation remains incomplete;
the fixer, live-control tester, Chrome, live ACP and live desktop tasks are not
run.
