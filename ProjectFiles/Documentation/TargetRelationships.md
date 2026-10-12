# Target relationships

The private observation connects each control to its application/PID, window,
and observed outer-to-inner container path. `target_context.path` references
existing element IDs, including sheets, dialogs, panels and rows;
`nearby_label_ids` references the labels retained with that control by the
existing ranked selection. No derived node is executable.

Repeated control names carry a count and up to eight candidate IDs. A partial
flag makes omitted candidates explicit. These warnings do not make an explicit,
current element ID invalid. The model must select the intended app, window and
panel rather than infer a target from a button's name alone.

Both response validation and the native coordinate preflight reject overlapping
unrelated hit candidates. A button and its label child can describe the same
control. An explicit element ID keeps precedence over incidental coordinates.
Graphics-only applications retain their existing screenshot path and window
ownership checks.

Native target records include the observed parent chain, container identities,
labels and bounds, and surrounding static labels. Staging caches shared
container reads locally. Accepted screenshot/control pairs compare this
structure, and the final delivery preflight rereads it without that cache.
Reparenting, replacing, moving or relabeling a panel rejects the stale target
before an event is delivered. No extra model requests are involved.

Replay protection compares semantic container context across revisions so two
Save buttons in distinct observed panels do not inherit each other's failure
state. Unknown contexts remain conservative. This is contextual identification,
not proof that a click saved a document; task coverage and reconciliation still
apply.

Validation uses synthetic observations and fake native delivery. No fixer,
live-control tester, Chrome, or desktop task was run. Live accuracy remains
unvalidated.
