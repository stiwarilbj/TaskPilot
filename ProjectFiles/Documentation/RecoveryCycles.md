# Recovery across different actions

The task runtime retains a bounded history of attempted approaches and accepted
screen states. It detects two repeated laps of a closed path containing two to
six steps, such as opening and cancelling the same dialog or toggling the same
control between two unsuccessful states.
After two explicitly unsuccessful methods on an unchanged state, proposing one
of them again is also suppressed before dispatch. The existing identical-action
guard and three consecutive native-rejection limit remain in force.

Screen fingerprints compare the target app's windows, control hierarchy,
labels, bounds, enabled/focused state and nonsecure values. Revision IDs,
enumeration order, foreground restoration, cursors and progress-indicator values
do not create progress. Graphics-only windows contribute their metadata and
high-confidence recognized text. Where semantic content is unavailable, exact
image digests conservatively distinguish screen content; unknown images cannot
establish a repeated state. Unrelated apps cannot hide a target app's loop.

Approach fingerprints include the normalized action and its semantic target.
Element IDs and incidental coordinates for the selected control are excluded.
Changing controls, panels, parameters or supported methods remains available;
the guard never chooses or executes a replacement. Reports identify the repeated
state path and attempted methods, including native delivery methods when known.
Old IDs, literal commands, paths and input text are excluded from those summaries.
The next existing decision uses the recovery prompt to select a different
strategy or inspect the effect. Detection itself makes no model or bridge calls.

New matching requirement proof resets recovery memory. Fresh evidence IDs,
model completion claims, delivery acknowledgement, waiting and re-proving the
same requirement do not. This allows repeated workflows that actually advance
different verified requirements. Mutable proof remains subject to the existing
ledger's invalidation and final coverage audit.

Blocked approaches apply only to their observed state. Three suppressed cycle
proposals without new proof stop safely, using the existing three-decision bound;
the overall step limit is unchanged. Read-only file inspection and local waits
remain available but cannot reset a failed-method budget. Receipts and uncertain
mutation reconciliation run first: cycling detection cannot authorize a second
send, submission, file mutation or uncertain desktop event. Loading, credentials,
permissions, cancellation and task-generation ownership keep their existing stops.

Memory is per task: 24 recent attempts and at most 48 blocked approaches. Only
aggregate recovery-cycle and suppression counts join private diagnostics and
history metrics, with backward-compatible decoding. Reports and state contents
are not persisted. There are no frontend controls, model changes or setup steps.
Recovery policy version 1 binds decision caching and offline regression packs.

Synthetic tests cover dialog loops, alternating rejected methods, meaningful
progress, stale IDs, repeated proof, graphics-only content, uncertain mutations,
bounded stopping and unchanged healthy request counts through the actual task
loop. The offline corpus includes both loop patterns. These scripted responses
test execution safeguards; they do not establish live model accuracy. No fixer,
Chrome interaction, live ACP request or live desktop task is run. Live accuracy
validation remains incomplete.
