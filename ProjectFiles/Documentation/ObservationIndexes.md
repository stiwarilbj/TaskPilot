# Shared observation lookups

The Python runtime builds private `ObservationIndexes` for each observation state
inside the existing task-scoped screenshot/state lifetime. Target validation,
prompt selection, action identity/history, recovery, expected-effect checks,
requirement evidence, and OCR ownership checks share those lookups.

Indexes contain element ID groups, first/last matches, app PID membership, row
positions, parents/children, bounded ancestry, window scopes, and separate
Accessibility/graphics window tables. PID and window namespaces remain distinct.
Ancestry retains the existing 24-parent limit, cycle detection, and app/window
boundaries. Duplicate candidates and enumeration order remain available to
ambiguity checks; a lookup does not authorize an action or prove completion.

Indexed rows are read-only snapshots. Equivalent observation copies cannot change
each other's cached targets. The existing state content guard invalidates indexes
after an in-place edit, even if a revision was reused. A fresh revision or task
gets separate indexes. Observation discard and task exit clear the cache alongside
the existing image/state buffers; task generation mismatches stop lookup reuse.
Helpers outside a task scope build fresh indexes rather than retaining global
control data. Nested matching helpers accept the already resolved indexes so they
do not rebuild the graph for every candidate.

The indexes and their private version key stay outside model prompts, decision
inputs, and persisted history. No model requests, desktop observations, actions,
user controls, or setup steps are added. Existing native freshness, focus,
permission, secure-input, and execution checks remain in force.

Regression tests cover index sharing, mutation/revision/task invalidation, scope
cleanup, duplicate IDs, PID/window collisions, ancestry boundaries, immutable
snapshots, prompt parity, coordinate ambiguity, and field reconciliation.
A local comparison against the prior implementation found identical ranking,
structure, coordinate candidates, and field matches in a synthetic 362-element
fixture. Across 30 warmed samples, median field-candidate matching took about
0.84 ms with indexes versus 6.79 ms previously. This measures local matching work,
not total task latency or live accuracy. Live desktop validation remains incomplete.
