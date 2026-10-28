# Private runtime metadata

`private_runtime_metadata.py` and `PrivateRuntimeMetadata.swift` implement the
same bounded JSON file-read pattern. Shared fixtures in
`Tests/Fixtures/private-runtime-metadata.json` cover matching limits and JSON
acceptance. Managed runtime descriptors, health and request records, ownership,
recovery, provisioning, configuration, and integrity records use these readers.

Each reader opens with no-follow, nonblocking, close-on-exec flags. Before
reading it checks the open descriptor for a regular file owned by the current
user, one hard link, and an acceptable size. Provisioning journals additionally
retain their required mode of `0600`. Reads use at most 64 KiB per chunk and
never exceed the file's fixed limit, including when it grows. Descriptor and named-file
identities, ownership, mode, link count, size, and nanosecond modification/change
times must still match after reading. Every exit closes the descriptor.

Limits are 4 KiB for requests/acknowledgements and provisioning journals,
64 KiB for ordinary records, 128 KiB for runtime descriptors, 4 MiB for
configuration, 8 MiB for process lists, and 64 MiB for integrity manifests and
caches. The small environment diagnostic record retains its 256-byte limit.
The existing generated descriptor schema still validates field and path rules.

JSON must be a complete UTF-8 object or array. Duplicate keys at every nesting
level, including escaped and canonically equivalent Unicode keys, are rejected
before dictionary conversion can discard them. Nonfinite numbers, unpaired
surrogates, alternate encodings, BOMs, raw NULs, and excessive nesting are
rejected. Callers retain their schema and top-level type checks. Errors contain
fixed classifications rather than payload contents.

Invalid health never establishes readiness. Invalid ownership and Gateway
restart-budget records stop startup; rejected ownership records remain intact
for inspection. A missing optional record retains its existing meaning.
An invalid disposable integrity cache triggers authoritative full verification.
Existing configuration repair and recovery policies remain in force.

These checks detect observed replacement or modification around a read; they
do not lock out other processes or make the filesystem atomic. Existing
private-root checks and configuration fences remain necessary. Non-JSON keys,
scripts, CLI output, and immutable bundled resources are separate input paths.
No interface, runtime protocol, provider request, or action-schema changes are
introduced.

Offline reproduction from `ProjectFiles`:

```sh
python3 -m unittest Tests.Python.test_private_runtime_metadata Tests.Python.test_managed_openclaw Tests.Python.test_managed_provisioning
swift test --filter 'PrivateRuntimeMetadataTests|ManagedOpenClawTests|RuntimeMessageJSONTests'
```

Fixtures exercise short/interrupted reads, exact limits and pre-read oversized
rejection, replacement and growth during reading, descriptor closure, symlinks,
hard links, wrong ownership, directories/FIFOs, and invalid JSON. These tests
perform no provider or desktop actions.
