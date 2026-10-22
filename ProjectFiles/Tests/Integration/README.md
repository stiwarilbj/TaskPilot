# App control regression fixture

The automated Swift and Python suites exercise action validation, revision scope,
activation waits, restoration guards, mutation replay protection, and private
output diagnostics without controlling Chrome.

`test_app_control.py` is an explicitly opt-in native bridge fixture. It creates a
disposable AppKit app and uses the signed TaskPilot bundle's existing permissions.
It does not launch or control browsers, and its cleanup does not close discovered
apps. `--live-acp` adds one provider planning request against the disposable app.
Do not run it as part of ordinary builds or automated test discovery.

Validation performed during implementation:

- Five native button/double-click/text/scroll cycles, menu selection, disabled
  controls, and stale element IDs passed on the main display with no wrong-target
  or duplicate actions.
- A secondary display was unavailable, so that display path remains unverified.
- Live ACP returned a decision that failed the intended-target assertion; the
  action was not delivered. Prompt and observation refinements followed, but live
  model verification remains incomplete.
- Browser testing was stopped after reported Chrome instability. No further live
  browser or native-control tests were run after that request.

The final bundle is validated by compilation, automated suites, and signature
verification. These checks do not establish complete live app compatibility.

Response repair validation uses mocked ACP terminal responses and current-observation
fixtures. It covers strict parsing and native parameters, the shared one-call repair
budget, same-model retention, fallback, provider errors, cache identity, and request
counts. The Swift suite also checks compatibility with older diagnostic records.
No live-control tester, Chrome interaction, or live ACP check was run for this change;
live validation remains incomplete.

Screen settling now polls local observations after desktop actions and model-requested
waits. Mock fixtures cover stable dialogs, loading indicators, field readiness,
revision and foreground churn, screenshot-only changes, bounded waits, cancellation,
cleanup, and reuse of the final observation without duplicate actions or model calls.
Live-control validation remains incomplete; no Chrome or live fixture was used.

Decision-prompt regression fixtures check context-specific action examples, valid JSON
and fixture-bound validation, compact recovery references, preserved task evidence,
local credentials, completion rules, and one-call healthy decisions. Empty-observation
fixtures are capped at 4,000 characters. No Chrome interaction or live-control tester
was used; live accuracy validation remains incomplete.

Click preflight compares the observed app identity, Accessibility owner PID, window
identity/title/bounds, control label/role/subrole/bounds, and enabled state immediately
before AXPress or the first mouse-down. Pointer hit testing rejects another control
covering a known target. Coordinate clicks also check Core Graphics window IDs and
bind to an observed control when available; apps that expose no Accessibility control
still have only app/window metadata available for that part of the check.
Automated fixtures cover changed targets, replaced windows, rejected delivery,
cancellation, and fresh-observation replanning without replaying the rejected click.
These local checks make no model requests. No live-control tester or Chrome interaction
was run; live compatibility and accuracy validation remain incomplete.

Text entry now binds to the supplied observed field or the uniquely observed focused
input in the supplied app. It acknowledges focus before delivery, prefers supported
Accessibility setters, preserves insertion/selection semantics, and checks readable
values locally for up to two seconds. Keyboard chunks stop if focus changes; partial
or ambiguous delivery is never replayed automatically. Whole-field replacement is
idempotent, and unconfirmed replacements share the existing mutation replay guard.
Secure fields and private credential/code entry skip read-back and return no values;
secure subroles are redacted in Accessibility observations as well as secure roles.
Browser navigation requires an identified address field in the browser toolbar and
verified entry before Return; unknown/localized toolbar labels may require the
existing model-driven desktop recovery path.
Automated tests cover focus rejection/timeouts, direct setters, selection-preserving
insertion, Unicode boundaries, delayed/ignored/partial/duplicate entry, safe fallback,
unreadable and secure values, cancellation, and zero replay. Local focus/read-back
checks make no model requests. No Chrome interaction or live-control tester was run;
live compatibility validation remains incomplete.

Action recovery now uses classified failures: stale targets refresh observations,
focus/activation failures require current target evidence, and a busy target waits
locally before a new decision. Loading recovery permits two five-second waits;
unchanged rejected inputs permit one recovery attempt, then suppress further
delivery. Three consecutive native rejections remain a task safety bound.
Unsupported Accessibility presses permit one coordinate fallback only after
revalidating the intended control and pointer hit. Ambiguous presses never fall
back. Uncertain mutations are checked on fresh evidence and cannot be replayed
by changing press/click, keyboard, or text-entry methods. Complete nonsecure
field read-back can prove a previous replacement without entering text again;
clipped values and generic screen changes cannot. Failed file verification and
timed-out/nonzero commands retain uncertainty and require inspection rather
than repeating a write or command. Recovery state is private and task-local;
diagnostics store only action/outcome/recovery codes, without commands or values.
Automated fixtures cover these paths, cancellation, transport stops, unchanged
targets, delayed effects, and query counts. No Chrome interaction or live-control
tester was run; live compatibility and accuracy validation remain incomplete.

Command execution validates the working directory, executable, argument types,
timeouts, and requested outcome checks before launching. Single programs use
literal `argv` arrays; shell source runs through a bounded `zsh -f -n` syntax
preflight before execution, without user startup scripts. The validated directory
also supplies `PWD`. Literal shell quoting preserves spaces, apostrophes, and
metacharacters. Existing pause, cancellation, output limits, and mutation replay
guards apply to both syntax checking and execution.

`run_command` accepts exactly one of `argv` or `command`, plus optional `checks`:
`file_exists`, `directory_exists`, and `path_absent` require an absolute or `~/`
path; `file_contents` also requires exact content (UTF-8 or base64);
`stdout_equals` requires exact text. Checks are read-only and run locally after
the process ends. Exit zero alone reports execution, not verified task effects.
Missing checks, mismatches, timeouts, and nonzero exits cannot enable native fast
completion. Unconfirmed commands cannot be replayed by changing timeout, checks,
or equivalent literal command/argv representations. Prompts and format repair use
the same validated contract; no extra generation calls are made for local checks.

Swift fixtures execute disposable local commands and files to test quoting,
literal paths, syntax rejection before effects, invalid directories/parameters,
exact/binary/empty file contents, directory/removal checks, dangling links,
truncated output, cancellation, and zero-exit false positives. Python fixtures
cover precise validation errors, one same-model repair, completion evidence,
replay protection, and the 4,000-character prompt bound. No Chrome interaction,
live-control tester, or live ACP task was used; live accuracy remains unverified.

Observation compaction now ranks the existing candidate controls by task wording,
the active window on the task display, focus, menus, and nearby row/section labels.
Selected controls retain structural ancestors and their own surrounding labels
within the 360-element prompt budget. Native capture visits focused/topmost
visible windows first and supplies observation-scoped window IDs, distinguishing
same-title windows without guessing from titles. Capture remains bounded; missing
controls still require inspection of the current screenshot. Revision-scoped IDs,
window activation flags, and enumeration order do not count as screen changes or
reset the unchanged-target rejection budget.

Both planning and completion verification retain confirmed earlier events in the
current task beyond the recent eight actions. The bounded historical memory keeps
native file evidence, verified requested command checks, and confirmed action
effects. It excludes stale control IDs, command source, unverified model completion
claims, and private/secure input. Long values are explicitly excerpted, binary
reads retain a byte digest, and mutable state still requires fresh evidence.
Nothing is persisted or reused across tasks; action execution and mutation guards
continue using the original validated history.

Automated fixtures cover late relevant controls, active versus inactive windows,
duplicate button labels, app/window isolation, Unicode matching, ancestor cycles,
unchanged IDs, long tasks, evidence budgets, private input exclusion, and window
metadata churn during settling. Ranking and progress memory make no model or
native-action calls; healthy decisions still use one planning request. No Chrome
interaction, live-control tester, or live ACP task was run for this change; live
accuracy validation remains incomplete.

Task observations now stage Accessibility trees before and after the screenshot,
bracketed by fresh display geometry, resolution, application identity, and window
z-order checks. Only an accepted second tree publishes executable observation IDs.
Control signatures retain hierarchy, full labels/bounds, focus, enabled state, and
nonsecure editable values while ignoring scoped IDs, enumeration order, and numeric
progress values. Graphics-only apps keep window-identity checks without requiring
pixel equality. Rejected screenshots are deleted and removed from the task ledger.

Consistency recovery uses local cancellable backoff and a five-second retry budget;
settling calls pass their remaining budget rather than stacking another five seconds.
Already-running macOS reads may finish after that deadline; no additional attempt is
started, and only a matched pair can be accepted. Persistent changes return
`observation_unstable` before any planning, fallback, action replay, or completion.
Pause discards unfinished pairs; Resume starts fresh, while revoked generations
cannot publish. Diagnostics contain only counts, fixed rejection categories, and
elapsed time, with no captured content or secrets.

Fake-provider Swift fixtures cover each bracketing boundary, control changes,
menus/sheets, graphics-only metadata, ID/order churn, progress values, deadlines,
slow reads, cancellation, Pause/Resume, and ownership revocation. Python fixtures
cover shared settling budgets and failure before provider requests or action delivery.
Full offline suites and signed-bundle checks pass. No fixer, live-control tester,
Chrome interaction, live desktop task, or live ACP check was run; live accuracy
validation remains incomplete. These checks do not make the two macOS APIs atomic.

Native discovery now uses collision-safe hashed identity buckets instead of a
linear visited list, preserving fresh rows for focused-control aliases while
expanding each discovered node once. Task-owned app/window graphs cache only
child handles and parent/child edges: no labels, editable values, geometry,
executable IDs, or persisted user content. Graphs are bounded to 16 applications,
16 windows per application, 4,096 nodes and 8,192 child edges per application.
Complete child pages can assist the pre-capture walk only after notification
registration succeeds; every control's attributes and each child count are read
again. Dirty subtrees are refreshed while unaffected pages remain reusable.

Unknown structural notifications, unsupported notification coverage, failed AX
reads, changed child counts, process identity/window replacement, a two-second
refresh interval, and Pause/Resume gaps force fresh discovery. Stop closes the
ending generation's graphs immediately; delayed subscriptions and callbacks
cannot populate the next generation. Subscriptions for disappeared processes are
released. Hash collisions always use equality, and cycles cannot suppress another
branch's invalidation.

The post-capture walk always enumerates children afresh, regardless of cached
pages or notifications. Only that fresh tree can become the accepted executable
map. A same-count replacement missed by notifications therefore causes normal
local recapture instead of publishing stale controls. Existing ownership, target
identity, bounds, enabled/focus and capture-consistency checks still apply.

Offline fixtures cover warm/dirty branches, cyclic/shared topology, collisions,
read/notification races, unsupported subscriptions, bounded growth, process
replacement, stale callbacks, Pause/Stop, new revision IDs and current bounds,
and same-count replacements around capture. The 1,280-control in-process fixture
measured 1.40 ms median traversal (30 samples), versus approximately 43.6 ms with
the previous linear index. This excludes native AX communication, graph storage,
and end-to-end capture latency; no live speed or accuracy claim follows. No
fixer, live-control tester, Chrome interaction, live desktop task, or provider
request was used. Live validation remains incomplete.

Capture acquisition, accepted-frame ownership, and PNG compression now have
separate stages. The native acquisition lane is serial, prioritizes eligible task
evidence, and retains at most two evidence frames and one preview reservation.
At most eight evidence requests and one replaceable preview request may wait;
waiting requests retain metadata rather than pixels. The existing viewer retains
its displayed image separately. Preview acquisition remains eligible when both
evidence slots are occupied, and superseded previews cannot publish late results.

Consistency checks pair a raw frame with the second fresh control tree before
OCR or encoding. One detached compression worker and one queued job encode only
that immutable frame; later screen changes cannot substitute newer pixels.
Read-only text-target reconciliation consumes raw pixels without creating a PNG.
Queued cancellation releases buffers promptly. Native acquisitions and ImageIO
compression already running retain capacity until drainage, then discard cancelled
results and partial files. Task revocation and suspension epochs prevent stale
publication; accepted evidence retains its own frame lifetime.

Synthetic-image fixtures block compression while exercising acquisition and
preview progress, preview floods, queue limits, exact encoded pixels, duplicate
encoding rejection, partial-file cleanup, task revocation, queued cancellation,
and consistency rejection before compression. These are offline tests: no fixer,
live-control tester, Chrome interaction, live desktop task, or provider request
is used. Live capture latency and accuracy validation remain incomplete.

Local native operations now inherit one monotonic `LocalOperationBudget` through
TaskLocal ownership checks. Python uses a task-owned `LocalBudget` across command
inspection, dispatch, receipt recovery, and effect settling; local readback,
prerequisite, and evidence-inspection groups also share one allowance. Private
bridge requests carry only remaining milliseconds, not cross-process clock
values, and native helpers cap their existing limits against that remainder.
The allowance is excluded from action identity so receipt lookups and retries
cannot change the meaning of a logical action. No provider-response deadline is
introduced: final-verifier generation waits remain outside local readback scopes.

Activation/focus, AX reads, notifications, capture queueing, OCR, compression,
command launch/wait, and local polling check remaining time before additional
work. Root expiry reports `local_budget_exhausted` with the consuming phase.
Pause does not renew the monotonic allowance; cancellation/revocation still
interrupt parked workers. In-flight OS reads or ImageIO work may drain after
expiry, and subprocess teardown/output drainage must finish before handoff.
These are admission deadlines, not a claim that native APIs are preemptible.
Cleanup and foreground restoration keep their existing ownership protections.

Expiry before dispatch leaves the action rejected. Expiry after dispatch leaves
its receipt unconfirmed and never supplies negative proof or permission to replay.
A late valid terminal receipt remains authoritative; unresolved work still stops
without redispatch. Effect-inspection exhaustion leaves proof unconfirmed, while
completion-readback exhaustion cannot authorize completion. Offline clock, fake
executor, synthetic-image, and temporary-file fixtures cover shared nested limits,
phase reporting, cancellation, queue expiry, precommit expiry, compression drainage,
late receipts, and unchanged model-call budgets. No fixer, live-control tester,
Chrome interaction, live desktop task, or provider call is run; live validation
remains incomplete.
