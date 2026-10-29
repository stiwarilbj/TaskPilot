# Private artifact acceptance

The native file path now checks supported output structure in stages before a
staged write can commit. Command and GUI output files use the same checks when
their existing file outcome checks inspect them. No model request, desktop
observation, file extraction, browser access, or automatic execution is added.

## Stages and proof

The explicit destination suffix selects PDF, DOCX, or XLSX validation. The
existing exact-path requirement matching still rejects outputs at the wrong
destination. An extension only selects a validator; it never establishes proof.

1. Bind the regular-file descriptor and its identity/version.
2. Check the signature and bounded container layout.
3. Inspect the required document structure and relationships.
4. Recheck identity/version. For writes, bind the staged validation and whole
   digest to the same version, commit conditionally, then verify the committed
   descriptor and hash using the existing file-operation guarantees.

The generated native contract defines a versioned `artifact_format` proof:
format, `verified: true`, validation version, `document_structure` scope,
structure count, and an exact, format-specific list of facts. Swift and Python
validate it before receipts or evidence can accept the result. The facts and
count limits come from `Contracts/action-contract.json`. A former two-field
signature attestation cannot become a structural proof.

- **PDF:** Retain header, terminal marker, and cross-reference preflight; use
  Quartz against bounded descriptor bytes to read the catalog, page tree, every
  page object, and finite positive media bounds. Facts are `pdf_catalog` and
  `pdf_pages`. The count is pages inspected. Locked, unreadable, empty, and
  over-limit documents acquire no proof. There is no rendering or script/link
  execution.
- **DOCX:** Validate the ZIP directory and local entries, CRCs of inspected
  parts, parsed content types, a unique internal office-document relationship,
  the Word document namespace, and exactly one body. All declared internal
  package relationships must resolve to existing members; relationship
  references in the main document must exist. Facts include `word_body`.
- **XLSX:** In addition to the package stages, match every declared workbook
  sheet to a distinct, internal relationship and correctly typed sheet part.
  Validate sheet IDs/names, XML namespaces, sheet data for worksheets, and
  referenced relationships. Nonconventional worksheet filenames are supported;
  a random worksheet cannot substitute for a missing declared one. Chartsheets
  are supported. Facts include `workbook_sheets`; the count is declared sheets.

XML parsing disables external entity resolution and rejects DTD/entity
declarations, malformed documents, duplicate relationship IDs, duplicate parts,
escaping relationship paths, overlapping ZIP entries, and missing targets.
External relationship metadata is never fetched or used as a required part.
The supported OOXML subset uses UTF-8 and transitional or strict namespaces.

## Bounds, cancellation, and reuse

Inspection accepts at most 64 MiB per file, a 4 MiB ZIP central directory,
16,384 entries, 1,024 bytes per member name, 4 MiB per inflated inspected part,
and 12 MiB aggregate inflated bytes. XML is limited to 64 levels, 64 attributes
per node, and 50,000 aggregate retained nodes. At most 256 relationship files,
256 sheets, or 2,048 PDF pages are inspected. Unsupported features and exhausted
bounds remain unverified rather than being inferred valid.

A two-second monotonic inspection allowance is checked between native stages,
ZIP entries, XML callbacks, and pages. Existing task cancellation and any shorter
local-operation deadline are also checked. Quartz parsing and decompression are
bounded by input sizes; those individual synchronous library calls are not
preemptible. No late result passing the elapsed-time check can gain proof.

The same-task verified-digest fast path carries the complete typed structural
proof. It reopens the exact object and checks parent identity, file identity,
version, and size. Any mismatch falls back to fresh inspection. No proof survives
an applicable mutation, task replacement, or incompatible contract version.

## Output sets and evidence scope

`artifact_acceptance.py` derives a bounded output set from the task ledger's
active outcome requirements, excluding prerequisites and superseded work. Each
exact normalized destination must have matching proof for **all** its declared
outcomes. It uses the maintained requirement/evidence indexes, not new disk
reads. Missing members, wrong names or sibling paths, mismatched types, or
invalidated proof leave the set pending. The completion gate checks the set;
the existing independent final verifier still audits the entire original
request, including any output the checklist omitted.

The next ordinary planning/verification prompt receives the derived report.
Unknown formats are explicitly `bytes_only_structure_unverified`; their narrow
file/byte facts never become structural or semantic claims. Supported facts
prove only the inspected document structure, not correct prose, formulas,
visual layout, all optional standard features, or successful rendering. File
existence and successful writes alone do not prove usability.

All reports remain task-local. No artifact bytes, extra screenshots, paths,
part contents, or proof details are added to diagnostic persistence. Existing
file results, evidence freshness, authorization, repair budgets, receipts, and
single-action execution remain authoritative.

## Offline verification

```sh
swift test --package-path ProjectFiles --disable-sandbox --filter FileFormatVerificationTests
/opt/homebrew/bin/python3.11 -m unittest discover -s ProjectFiles/Tests/Python -p test_artifact_acceptance.py
python3 ProjectFiles/Scripts/generate-action-contract.py --check
```

The shared native-result corpus tests typed proof acceptance in both languages.
Native tests use synthetic packages and disposable files, including malformed
relationships, XML, bounded work, and identity replacement. Python tests cover
partial/misnamed sets, invalidation, narrow unsupported facts, and digest reuse.
Full Swift, Python, setup integration, and offline regressions are also required.
Live desktop and artifact-rendering accuracy are not established by these tests.
