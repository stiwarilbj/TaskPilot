# Backend action contract

`Contracts/action-contract.json` is the source for action names, execution owners,
parameters, constraints, safe executor defaults, normalization, key codes,
modifier aliases, examples, prompt bounds, and command outcome checks. Shared
field and limit references prevent values from drifting within the definition.
Optional metadata remains compatible. Defaults are read by executors; validation
never supplies missing targets, commands, paths, or content.

After changing a definition or validator template, run:

```sh
python3 ProjectFiles/Scripts/generate-action-contract.py
python3 ProjectFiles/Scripts/generate-action-contract.py --check
```

The generator uses the Python standard library. It produces the Python validator
and prompt data, Swift validator and exhaustive dispatch enums, and setup's
private startup fingerprint metadata. Build scripts check these committed outputs
before packaging; check mode never modifies files. New native actions or outcome
checks require implementing their exhaustive Swift switch cases.

The fingerprint covers resolved definitions, both validator templates, and the
generator. Both task startup and readiness/setup checks supply it through private
stdin. Mismatches stop before provider requests or desktop execution. The same
fingerprint invalidates response/readiness caches and offline regression reports.
No credentials or action contents are included in fingerprint metadata.

Structural validation occurs in Python and again at native entrypoints. Swift
rejects boolean or string numeric parameters, and floating-point values in integer
fields. Semantic clicks normalize to press before incidental coordinates are
validated. `none` and `wait` belong to the Python runtime and are rejected by the
native bridge. Live target freshness, focus, permissions, ownership, secure input,
and delivery verification remain native checks; structural validity does not
establish success.

The shared fixture corpus is run through both languages. Existing response-repair,
request routing, single-action execution, cancellation, completion, and prompt-size
checks remain in their existing suites. Live desktop accuracy is not established
by these offline tests; do not run the fixer, Chrome, or live-control tester as
part of this change.
