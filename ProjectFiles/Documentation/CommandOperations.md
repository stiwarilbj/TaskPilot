# Deterministic command intentions

The private `run_command` action accepts a named `operation` as an alternative
to choosing an executable, flags and checks. Recipes live in the authoritative
action contract; generated Python and Swift code compile the same literal
argument arrays and mandatory outcome checks. Other supported actions and
general `argv`/syntax-checked shell execution remain available.

```json
{"type":"run_command","operation":{"type":"create_directory","path":"/example/folder"}}
{"type":"run_command","operation":{"type":"copy_file","source":"/example/a","destination":"/example/b"}}
{"type":"run_command","operation":{"type":"move_file","source":"/example/a","destination":"/example/b"}}
{"type":"run_command","operation":{"type":"remove_file","path":"/example/a"}}
{"type":"run_command","operation":{"type":"remove_empty_directory","path":"/example/folder"}}
{"type":"run_command","operation":{"type":"print_text","text":"Exact output"}}
```

These are illustrations. Selection and operands still come from the current
task decision. Templates never invent paths, text or destructive authorization.
The existing planning request selects the operation; compilation, preflight and
readback need no model request. Healthy task-loop fixtures use one planning
request and the existing final coverage verifier.

Complete literal requests are recognized locally for operand validation, not
automatic execution. A proposed template that disagrees with their verb or
paths uses the existing one-response repair budget. Creating a named copy/move
destination's parent is an allowed prerequisite. Compound, ambiguous and
negative requests remain on the general planning path. Request patterns,
examples, parameter bounds and recipes share the versioned contract.

Each template has a fixed executable and flags. Matching canonical `argv` can
be carried through the native bridge; conflicting command text or flags are
rejected. Mandatory checks cannot be removed, and extra outcome checks can be
added. Paths are absolute or `~/`, passed as literal operands with home
expansion only. Parent traversal is rejected for templates; complex paths can
use general execution. No shell interpolation or guessed quoting occurs.

Copy and move accept regular files bounded by the existing 2 MiB read limit,
an existing destination parent and an absent destination. They reject existing
files, directories, dangling links and symbolic sources before delivery, and
use no-clobber flags. A bounded nonfollowing source read checks file identity,
size and modification metadata around the snapshot. Native verification then
requires the exact destination bytes; move also requires source absence. These
checks detect observed changes, without making external filesystem actors
atomic with command execution. Larger files, overwrites, directory trees and
other operations stay available through ordinary commands and their checks.

File removal never recurses and rejects directories and links. Empty-directory
removal uses `rmdir`, so nonempty directories are preserved. Text output uses
`printf` with a constant format and an exact stdout check.

The private requirement ledger records a `command_operation(operation)` fact
only when all native outcome checks match. Exit zero or destination existence
alone cannot prove a copy. Destination snapshots survive in the in-memory
ledger for read-only rechecks after later mutations. Rechecks never launch the
original command, and they cannot create proof of an operation that never
executed. Whole-request completion still requires coverage of every constraint
and any requested returned output. Action receipts, task ownership, cancellation
and uncertain-mutation protection remain in effect.

Recent and historical prompt context keeps the operation and verified checks,
including byte hashes, without transmitting the native source snapshot or
duplicating generated arguments. The full check inputs stay in the local ledger.

No operation contents, source snapshots, prompts or commands enter persisted
diagnostics. The shared contract fingerprint and private validation/checklist
versions invalidate incompatible bundles and cached decisions. There are no
interface, setup, permission or model-default changes.

Validation uses shared Python/Swift fixtures, fake ACP and transport, and
disposable local command/file fixtures. No fixer, live-control tester, Chrome
interaction or live desktop task was run. Live model accuracy remains untested.
