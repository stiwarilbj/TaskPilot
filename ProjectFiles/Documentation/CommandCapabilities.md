# Command capability preflight

General `run_command` actions now pass through a private native inspection
before command delivery. Explicitly named, recognized tools in command tasks
are inspected locally before the first planning response (at most two tools).
The existing deterministic operation templates retain their fixed executables,
arguments and mandatory outcome checks and need no new capability probe.

Inspection uses the same normalized PATH, environment and validated working
directory as execution. It resolves executable paths, records their canonical
file identities, and runs established help-only interfaces for known tools in
standard installation locations. Git help is specific to supported literal
subcommands; other known tools use their supported global/subcommand help.
Unknown executables and user scripts never receive a guessed `--help` call.
Their paths are bound, but their options remain explicitly unverified.

All probes within an inspection share two seconds of active waiting. Each help
or resolution probe gets at most 800 milliseconds. Output is monitored against
a combined 64 KiB threshold, returned excerpts are at most 1,800 characters,
and termination/drain may add up to one second. Probe process groups are
terminated and temporary output files removed. Task ownership, Stop and Pause
apply to inspection just as to other pending native work.

Help is untrusted capability data, never an instruction or completion fact.
The model receives observed flags, context and incomplete-help limitations.
Production help catalogs may omit aliases and implicit negated forms, so a
missing listing alone does not reject a flag. An explicitly exhaustive profile
can reject unadvertised long options before dispatch; its parser respects
observed option operands and the `--` separator. Short-option listings are
informational. In particular, curl documents implicit boolean negations in its
[official command reference](https://curl.se/docs/manpage.html).

The three fixed help-extraction regular expressions are private, immutable
static properties, initialized once and shared across inspections. Matches,
flag sets, and value-argument counts are computed afresh from each help text;
this does not extend executable bindings or capability-cache validity.
`CommandHelpParsingTests` compares extraction against the previous per-call
compilation path, including Unicode, unusual whitespace, misleading examples,
alias operands, repeated options, and independent concurrent inspections.
An optimized local seven-trial benchmark of 1,000 extractions measured median
time of 36.5 ms with per-call compilation and 6.7 ms with static expressions,
with identical result counts. This measures parsing only, not command latency;
regressions assert exact extraction results rather than timing thresholds.

Literal argument arrays execute the inspected canonical executable directly.
For fully recognized static shell pipelines/sequences, syntax is checked
without running the source, and the actual shell classifies literal command
heads before canonical paths replace only those heads. Operands and quoting
remain intact. Builtins, aliases, functions, context-changing shell commands,
standalone environment assignments, substitutions and other dynamic grammar
keep their original shell source. These cases bind the outer shell and captured
environment only; child resolution and options remain explicitly unverified.
General shell execution remains available without pretending this conservative
analysis is a full shell interpreter.

The private inspection handle belongs to the task generation and suspension
revision and expires after 120 seconds. Its fingerprint covers the exact
validated action and execution environment. Before delivery, native code checks
the handle, working-directory identity and alias, shell identity, executable
lookup and executable file metadata again. Observed changes reject the action
before the receipt is marked dispatched. These checks detect replacement;
external filesystem actors are not atomic with a later `exec` or child lookup.

In-memory help and binding caches hold at most 64 entries and are cleared when
a task is bound. Help reuse requires matching executable identity, environment,
directory and exact probe arguments. Planning keeps at most eight bounded
capability summaries. Startup, decision-cache and offline-regression identities
include the private capability version. Bundled version mismatch stops before
model calls or action execution. The generated action schema remains unchanged;
inspection handles stay outside model actions and prompts.

Missing programs, invalid syntax, unadvertised options from exhaustive profiles,
and changed bindings retain distinct failure codes. Recovery receives the
specific condition and observed capability data through its existing bounded
path. No automatic installation, silent program substitution or uncertain
mutation replay is introduced. Inspection happens before evidence invalidation
and never marks an action receipt dispatched. Completion still requires the
requested outcome checks and full requirement coverage; help and exit zero
cannot establish it.

Only aggregate inspection, help-probe, cache-hit and preflight-rejection counts
enter persisted diagnostics, with backward-compatible history decoding. No
environment values, help output, inspection handles, prompts or commands are
persisted by this feature. There are no interface, setup, permission or model
default changes and no extra model requests for healthy command decisions.

Validation covers disposable native command fixtures, a task-scoped bridge
check without a display, fake ACP task loops, cancellation, changed executables,
directory aliases and environments, bounded probes, shell semantics and option
operands. Python, Swift, setup mocks, generated-artifact checks and scripted
offline prompt regressions run without the fixer, Chrome, live-control tester,
live desktop tasks or live provider calls. Live model accuracy remains untested.
