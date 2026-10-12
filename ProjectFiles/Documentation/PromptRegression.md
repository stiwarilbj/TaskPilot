# Private prompt regression evaluation

`ProjectFiles/Scripts/evaluate-prompts.py` is a developer tool. It runs the
production task loop, response validator, repair budget, model router, action
recovery, settling checks, and completion checks against an in-memory fixture
desktop. It never starts OpenClaw, launches an app, accesses a credential, sends
a desktop event, or executes a command. It is not bundled into TaskPilot and
does not change the interface or require end-user setup.

Fixtures replace the home-directory context with `/fixture` and canonicalize
JSON dictionary ordering, including compacted history. This keeps sanitized
prompt inputs identical across users, saved files, and Python hash seeds.
Production prompt content and serialization are not modified.

## Create the private corpus

```sh
python3 ProjectFiles/Scripts/evaluate-prompts.py init
```

The default destination is
`~/Library/Application Support/TaskPilot/PromptRegression`. The directory is
mode `700`; files are mode `600`. Corpus, response recordings, and reports stay
outside the checkout. Initialization refuses to overwrite an existing corpus.
Use `--private-dir /absolute/private/directory` before the subcommand for a
separate experiment. Symlinks and destinations inside the repository are
rejected.

Eleven sanitized cases cover a healthy control, the wrong window with an identical
button label, a moved control, a delayed dialog, an invalid text parameter,
command syntax failure, exit zero without the requested file result, premature
completion, an uncertain submission, partial multi-file completion, and a
successful write with incorrect contents. Outcomes use independent state and
exact counters, so a model's completion claim does not establish success. A
repeated mutation also fails an exactly-once requirement.

These initial cases are **reproductions of documented failures and synthetic
controls**, with provenance attached to each case. They are not recordings of
the user's tasks. Existing runtime diagnostics intentionally omit task text,
screenshots, commands, and model responses; they cannot reconstruct those
tasks. The two demo recordings use predetermined replies and the same current
prompt. Their difference tests the evaluator's ability to detect failures;
it does not measure an improvement in model accuracy.

## Record and compare a proposed prompt

Freeze `corpus.json` before recording either variant. `baseline-prompt.json`
and `candidate-prompt.json` identify the executor revision and rule sections.
`null` uses the current production rules. A proposed `planning_rules` or
`verification_rules` string replaces that rule section while preserving the
same task evidence, context examples, and validated history. This tool does
not load or execute candidate Python code. A changed executor needs a new
experiment; do not compare different executor versions as a prompt-only change.

Supply **independently collected terminal model responses** for both prompt
variants. Collection is deliberately separate from this offline tool; there
is no live-control tester or generation command here. The demo recording shows
the JSON schema:

```json
{
  "version": 1,
  "sanitized_reviewed": true,
  "source": "recorded_model",
  "corpus_sha256": "<SHA256 of the frozen corpus>",
  "prompt_pack_sha256": "<SHA256 of this prompt pack>",
  "runs": [{
    "case_id": "healthy-control",
    "trial": 0,
    "requests": [{
      "purpose": "planning",
      "repair": false,
      "model": "google/gemini-3.5-flash-lite",
      "instruction_sha256": "<SHA256 of exact UTF-8 instruction>",
      "image_sha256": "<SHA256 of exact image bytes>",
      "elapsed_seconds": 1.2,
      "provider_retries": null,
      "response": "{\"status\":\"done\"}"
    }]
  }]
}
```

The module's `digest` function defines canonical container hashing. Record each
planning, repair, and verification request, including fallback responses. A
terminal provider error uses `error` with its sanitized structured envelope
instead of `response`. Never record partial output as a terminal response.
Provider retry counts stay `null` unless upstream reports them. Request time
must cover the request through its terminal response. Keep provider/runtime
settings and the task/observation identical between variants; use at least
three paired trials per case. Do not relabel demo recordings as model evidence.

Sanitize a real case **before** collecting comparison responses: replace app
names, document labels, account identifiers, paths, contents, and URLs with
consistent fictional data while preserving ambiguity, geometry, timing,
roles, action failures, and independently known outcomes. Manually review the
result. `sanitized_reviewed` records that review, not an automatic guarantee.
The importer also rejects recognizable home paths, email addresses, credentials,
and non-example URLs. It refuses suspicious content rather than silently
rewriting exact response/target behavior. Do not import a raw screenshot or
transcript from a user's task. The built-in PNGs are schematic fixture frames
with control labels supplied by Accessibility data, not real app screenshots.

```sh
python3 ProjectFiles/Scripts/evaluate-prompts.py compare \
  --baseline /absolute/private/baseline-recording.json \
  --candidate /absolute/private/candidate-recording.json
```

Each response must match the model, purpose, repair flag, and exact generated
prompt/image hashes. Evidence or prompt changes, missing replies, and unused
replies invalidate the replay. Replaying a baseline response under a new
prompt cannot count as a candidate model trial.

## Interpret the gate

Reports compare independent fixture success, incorrect actions/attempts,
duplicate actions, premature completion, TaskPilot planning/verification/repair
calls, retries, switches, and reported provider retries. They also compare
median and p95 task time. Task time combines recorded terminal-response time
with simulated local waits; offline replay wall time is reported separately
and is never presented as model speed. Private aggregate reports contain no
raw prompts, responses, commands, task text, screen contents, or secrets.

Eligibility requires full failure-category and healthy coverage, at least
three paired model trials for every case, a real prompt change, complete exact
bindings, successful candidate tasks, and zero incorrect or duplicate candidate
actions or false completions. A previously successful task must not need more
TaskPilot calls. Its median time may increase by at most 10% plus 0.5 seconds
to allow small timing noise. Gate failure returns exit code `1`; invalid input
returns `2`. Initialization succeeds while reporting its demos ineligible.

The gate never adopts or changes a prompt automatically. It is a prerequisite
for developer review. Passing it establishes fixture behavior, not physical
click delivery, real shell execution, or visual accuracy on live apps. Existing
Swift/native tests remain necessary. Live desktop accuracy validation is still
incomplete; this workflow does not interact with Chrome.

Run the evaluator's regression tests with the ordinary Python suite:

```sh
python3 -m unittest discover -s ProjectFiles/Tests/Python
```
