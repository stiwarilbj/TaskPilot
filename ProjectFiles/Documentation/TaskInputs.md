# Exact task inputs

The Python runtime binds literal inputs once when it creates the task's evidence
ledger. `AgentRuntime/task_inputs.py` retains paths, URLs, filenames and quoted
or fenced text from the complete original request. Complete, unambiguous text
suffixes in existing wording such as "Type hello" and "saying buy milk", or a
"Text:" block, are also retained without requiring quotes. Each binding has an opaque
task-specific ID, exact source ranges and an immutable value. Repeated identical
literals share one binding. The namespace is independent of the native task
generation; generation IDs remain outside model prompts.

Extraction is conservative. It preserves Unicode, whitespace, newlines,
backslashes, environment-like text, URL escapes and query parameters without
normalizing them. Fenced text includes the final newline preceding the closing
fence. Ambiguous bare punctuation, unfinished quotes and inferred phrases remain
unbound, available through the original task and existing literal action fields.
No user setup or new input syntax is required. At most 128 distinct literals are
bound; omitted entries are explicit in the catalogue. Long values have bounded
prompt previews and source ranges, while their complete values remain in memory
and the complete original task remains in every applicable prompt.

Planning, recovery and completion receive the same catalogue. A model may replace
a supported whole string value with an object of this shape:

```json
{"input_ref":"input_0123456789abcdef_1"}
```

IDs above are illustrations; only IDs from the current task are accepted. The
reference can occupy action path, content, text, URL, query, working-directory
or whole-command fields; individual `argv` arguments; generated command-operation
operands; outcome and expected-result check values; checklist source/check
values; and output/message fields. Observed element IDs, route IDs, PIDs, action
names, evidence IDs, enum values and numeric parameters cannot use references.

Resolution happens before strict response, action, expectation and requirement
validation. Native tools receive only ordinary resolved parameters, with the
same size, encoding, path, command-syntax, target, permission and secure-input
checks. A filename cannot become an absolute path without an explicitly supplied
complete path. Nothing concatenates paths, invents text, decodes escapes, adds
shell quoting or substitutes a literal inside shell source. Argument arrays keep
each literal argument separate, including spaces and shell metacharacters.

Malformed, unknown, cross-task and transformed references have precise
field-path errors and use the existing single repair budget for that decision.
Repair reuses the same task catalogue, screenshot and evidence, performs no
actions, and makes no new observations. No generation calls are added for binding
or resolution. Readiness-only responses cannot acquire task input bindings.

Recent action/candidate prompt copies may display exact matching literal fields
as references. Native result contents, observation data and stored evidence
remain unchanged. A bound input is user data, not proof of execution, target
identity or permission. All completion paths still require verified evidence and
the whole-request coverage audit. Screen contents, model assertions and secure
input replies cannot add or change bindings.

Bindings live only in the task ledger's memory and are not persisted in history,
diagnostics, profiles or readiness state. The binding version and fingerprint
participate in the decision-cache identity. Regression fingerprints cover the
new module; fictional offline fixtures use deterministic namespaces so exact
recordings remain replayable. Production tasks always use a fresh namespace.

Offline tests cover exact bytes, duplicated literals, empty and multiline text,
scope isolation, malformed references, strict post-resolution validation,
argument boundaries, long histories, untrusted observations, completion proof,
unchanged request/repair counts and the real Python task loop with fake native
results. Swift tests reject unresolved reference objects before side effects.
Live model accuracy and desktop validation remain incomplete. No fixer,
live-control tester, Chrome interaction or live desktop task is run.
