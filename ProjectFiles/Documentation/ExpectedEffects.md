# Executable expected results

`expected_result` remains an optional descriptive string and can now be a
supported check object. The existing decision request supplies the check; there
is no extra planning or checklist request. Invalid supported check fields use
the existing single response-repair budget before any execution.

```json
{"type":"dialog_appeared","pid":42,"title":"Save Draft","window_title":"Draft"}
{"type":"field_value","element_id":"<current field_id>","value":"Requested text"}
{"type":"file_contents","path":"/example/note.txt","content":"Requested text","encoding":"utf-8"}
{"type":"file_exists","path":"/example/note.txt"}
```

Each line is an illustration, not an executable default or selected target.
`directory_exists(path)` and `path_absent(path)` are also supported. Descriptions
and unknown check types remain explicitly unconfirmed; they never become shell
source, guessed selectors, or invented file/field contents.

Dialog checks require a new, uniquely matching dialog in the observed app,
optionally scoped to a window title. An unrelated menu, another app's dialog,
or a preexisting dialog does not qualify. Field checks bind to the original
control, application, window and surrounding structure across observation
revisions. They require a complete, exact nonsecure value. Missing, ambiguous,
clipped, replaced or secure fields remain unconfirmed.

The existing local settling loop evaluates GUI checks on accepted consistent
observations. Unrelated screen changes do not end a supported expectation's
wait. It stops on matching evidence and settling, or the existing bounded
deadline. Generic native screen changes acknowledge delivery only; focus and
text-entry readbacks retain their explicit scopes.

File checks use generated command-outcome definitions and native bounded
read-only inspection. Exact write/read/command evidence is reused when it
already proves the same path and contents. Otherwise local polling lasts at
most two seconds, without redispatching the action or invoking a model. A GUI
action with a file expectation captures one fresh observation after that poll,
sharing the wait rather than adding another settling cycle. Permission and
cancellation stops remain stops.

An expected effect proves only its named scope. Validated file proof enters
the private requirement ledger and is rechecked read-only before final
completion when needed. Existing matching native proof is not duplicated.
File existence cannot prove contents, a field value cannot prove submission,
and a verified check cannot bypass whole-request coverage. An unmet check
retains mutation reconciliation and suppresses premature finish-after-action
verification. No check replays an uncertain GUI mutation.

Only aggregate check/verification counts enter existing private diagnostics.
Check contents, model responses, credentials and task identities are not
persisted. Validation/cache and ledger versions and the generated bundled
contract fingerprint change together; model defaults, permissions, interface
and single-action execution remain unchanged.

Tests use synthetic observations, fake native transport, and disposable local
file fixtures. The fixer, live-control tester, Chrome and live desktop tasks
were not run. Live accuracy validation remains incomplete.
