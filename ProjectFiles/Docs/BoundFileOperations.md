# Filesystem identity and concurrent changes

Native file reads, writes, and file outcome checks use `BoundFileOperation`.
It resolves directory aliases with `realpath`, walks the resolved directory
with no-follow `openat`, and retains the parent descriptor. Parent identity and
the original pathname's resolution are checked again around delivery and
verification. Leaf symlinks and nonregular file read/write targets are rejected.

A write binds the current target's device/inode/birth identity and version
(size, timestamps, mode). It stages the complete replacement in that same
directory, with bounded streaming for append, preserving ACLs, extended
attributes, and ordinary permissions. Appending now publishes a replacement
object; other hard links to the previous object remain unchanged. No full-file
buffer is needed for appends. Existing files must remain unchanged during staging.

`write_file.precondition` accepts `bound` (default) or `absent`. An absent target
is installed using `RENAME_EXCL`, including when a default-bound destination was
initially absent. An explicit absent precondition also rejects an existing target
before staging. Existing-target replacement uses `RENAME_SWAP`, retaining the
displaced object long enough to detect a replacement or edit between the last
check and the exchange. Unsupported conditional rename operations fail closed.

Verification reads the still-open committed descriptor and checks its identity,
version, complete content hash, and directory entry. Native results report opaque
SHA-256 `parent_identity`, `file_identity`, and `file_version` fingerprints.
Writes also report `file_sha256` for the whole committed file; `content_sha256`
continues to describe the requested bytes (only the appended bytes for append).
The generated result contract requires these fields before receipts or evidence
can accept native verification. The in-memory evidence ledger preserves them.

A detected change produces `file_conflict` and requires fresh, read-only
inspection. If commit has occurred, its receipt remains unconfirmed: it cannot
independently authorize replay or prove completion. After a post-delivery
conflict, a displaced original is retained at the random sibling staging path
named in the error. TaskPilot does not overwrite a concurrent application change
to attempt a speculative rollback. Ordinary successful writes remove staging.
Cancellation remains cancellation, including after delivery.

These checks detect observed races; they neither lock unrelated applications nor
make all filesystem operations atomic as a group. Another writer can still edit
an open inode or rename entries after the last check. Evidence describes the
verified object at inspection time; existing task freshness and completion gates
still apply. Arbitrary shell commands remain outside this native write layer;
their file outcome checks use bound inspection, and exit zero alone is not proof.

Supported document outputs additionally pass the staged structural checks in
[Artifact acceptance](../Documentation/ArtifactAcceptance.md). Their typed proof
and digest refer to the same inspected object/version; unsupported structure
never inherits meaning from a successful byte write.

Validation uses disposable local files and injected boundary changes, plus the
Python, Swift, setup, generated-contract, and offline scripted regression suites.
No fixer, live-control tester, browser interaction, provider request, or live
desktop task is used. Live desktop accuracy remains unvalidated.
