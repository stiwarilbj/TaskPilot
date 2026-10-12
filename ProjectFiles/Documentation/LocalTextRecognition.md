# Local screenshot text

TaskPilot supplements incomplete Accessibility data with Apple's local
[Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images).
It also checks windows whose exposed tree has no useful
controls; menu-bar and window-raise actions cannot hide a poorly exposed canvas.
The remembered/active app order selects at most two relevant windows. Recognition
uses at most 1.5 seconds of the existing observation-consistency deadline. A
timeout or recognition failure leaves explicitly partial text evidence and
does not trigger a provider request or model switch.

Recognition runs off the main thread against the same captured image bracketed
by Accessibility and Core Graphics checks. It returns word locations, confidence,
surrounding line text, native app/window ownership, and repeated-label counts.
Word boxes avoid placing a line's midpoint between neighboring buttons.
Occluded labels and controls already supporting AXPress are excluded. Text is
untrusted observation data, never a control role or an executable element ID.
No recognition result establishes that a control is enabled, focused, or that
an action succeeded.

The central coordinate mapping converts Vision's bottom-left normalized boxes
to top-left image pixels, Quartz points, and full-display action coordinates.
It supports resized images, negative display origins, and crops. Up to 48
provisional targets are ranked by task labels. At most two nearby detail crops
retain original screenshot resolution and context, bounded to 512 KiB each.
They are standard image attachments in the existing ACP decision/verification
request; format repair reuses identical images. Crop bytes stay out of prompt
JSON. No extra model calls, public actions, controls, or user setup are added.

Known secure fields exclude their app from recognition, and overlapping secure
app windows exclude candidate crops. Recognition does not recover credentials
or create secure-input targets. Text/crop data stays in the task's in-memory
observation and lease, is replaced on a fresh observation, and is discarded on
retirement. Only aggregate candidate/crop counts are logged. Detail crops are
not written to disk; existing screenshot files retain owned cleanup.

For a coordinate click inside a provisional text box, native execution requires
confidence at least 0.8, current task/revision/pause epoch, current app/window
identity and geometry, foreground ownership, and unambiguous visible ownership.
A fresh local capture re-recognizes that label and checks its current position
and size within two points. A final synchronous scene/hit check runs immediately
before the existing event delivery. Exposed disabled/secure controls are rejected.
Changed, missing, ambiguous, or low-confidence text requests fresh observation;
it is never replayed. Existing action receipts, permission checks and uncertain
mutation reconciliation remain in effect. These checks support coordinate
delivery; they do not infer a missing native role or prove the intended result.

Private task protocol 5, text-recognition version 1, and the generated contract
fingerprint reject mixed bundled components before task requests. Python
validates target ownership, all coordinate spaces, crop transforms/bytes,
confidence and revision before accepting evidence. Planning/completion prompts
retain provisional semantics; repair, routing and single-action budgets are
unchanged. Versioned recognition evidence participates in cache/regression
identity. The 16-action contract is unchanged.

Offline tests use fake controls/captures and an offscreen rendered image passed
through real Vision. They cover mappings, crops, ownership, secure fields,
ambiguous/stale text, cancellation, partial budgets, native-control preference,
single-call healthy decisions and unchanged one-repair budgets. Setup and
offline prompt regressions also run without desktop control. Live app accuracy
remains unverified: no fixer, live-control tester, Chrome interaction, live ACP
check, or live desktop task is run.
