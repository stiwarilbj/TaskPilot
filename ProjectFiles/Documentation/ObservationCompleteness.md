# Observation completeness

Every accepted task observation reports whether traversal of the exposed
Accessibility tree on the assigned display completed. This does not claim that
Accessibility exposes every visible control. Graphics-only apps retain their
window metadata and are explicitly marked as missing Accessibility data.

The native collector first uses the existing 640-control, 160-child, depth-14
budgets. It retains omitted branch scopes and expands relevant branches locally,
prioritizing the active window, remembered app, menus, focused fields, and task
label matches. Expansion is bounded to 1,280 controls, depth 28, and 16 branch
passes. Child arrays use paged reads where supported and a single-value fallback
for apps without pagination. No target, command, or action is supplied locally.

Each staged collection shares the capture-consistency deadline and has a
1.5-second read budget. Object-specific Accessibility reads use at most an
80-millisecond timeout and reset it afterward; the global timeout is unchanged.
Transient read failures receive at most one retry per object/attribute and eight
retries per staging pass. Unsupported optional leaf attributes are normal
absence, while unreadable containers, required attributes, and timeouts remain
explicit gaps. Unfinished controls never publish executable targets. Visible
app controls are read before background discovery can consume their budget.

Both snapshots around capture perform this collection and expansion. Only a
consistent accepted pair publishes its revision and element map. Cancellation,
Pause/Resume, superseded generations, and screenshot disposal use the existing
ownership and consistency checks. Local expansion makes no model requests.

The private `observation_completeness` report includes collected-control counts,
gap reason counts, app/window/subtree scopes, and omitted-scope counts. Separate
prompt-selection metadata identifies controls excluded by ranking or the
360-control prompt limit. Missing observation data means unobserved, rather than
unavailable; planning, recovery, repair, and completion prompts retain this rule.
An exhausted local budget permits explicitly partial evidence, never false
completeness. Existing screenshot fallback and target checks still apply.

Python validates completeness before planning or accepting the observation
revision. Old offline fixtures have unknown coverage. Expansion counters are
private diagnostics and are excluded from prompts and cache inputs; actual
coverage changes affect decision identity. No control content or new history
payload is persisted. Protocol version 4 and completeness version 1 reject
mismatched bundled components during startup before task requests.

Offline tests cover healthy trees, child paging, priority expansion, huge/deep
trees, read failures, graphics-only apps, bounded retries/timeouts, cancellation,
capture deadline sharing, malformed reports, prompt omissions, and single-call
healthy decisions. They do not establish live app accuracy. Live desktop
validation remains incomplete; the fixer, Chrome, and live-control tester are
not used.
