# Configured JSON codecs

Repeated coding uses codecs with fixed configuration and private ownership:

| Owner | Codec | Configuration | Access scope |
| --- | --- | --- | --- |
| Runtime task invocation | Metrics decoder | Convert snake-case keys | Existing serialized runtime I/O queue |
| Task ledger store | Encoder and decoder | Millisecond dates; default object key ordering | Store-owned serial operation queue, shared by value copies |
| Compatibility profile store | Archive encoder | Default object key ordering | Store-owned serial coding queue; existing profile lock protects the snapshot and write |
| Compatibility key construction | Metadata encoder | Existing defaults | One synchronous invocation reuses it for both fingerprints |

Configuration is established before publication and remains fixed. Each store
or task invocation owns its codecs; they are not exposed through its interface.
Runtime messages are still checked against their invocation before decoding.
The ledger retains its `Sendable` value interface, existing atomic file writes,
permissions, camel-case persistence keys, and date units. Stored values remain
compatible with existing sorted files; readers do not depend on object key
order. Metadata fingerprints retain their existing bytes.

The ledger serializes each complete save: directory preparation, metric validation,
encoding, durable replacement (including synchronization), and final file permissions.
Snapshots commit in FIFO order of admission to that store's operation queue; concurrent
callers have no separate timestamp-based ordering. A store and its value copies share
this order. Independent stores or processes are not coordinated by this queue. A save
returns successfully only after finalization succeeds, preserving the coordinator's
save-before-publish rule. Failures propagate and release the queue; an error after
replacement does not imply the old bytes were restored. Reads also run entirely on
the operation queue, so they cannot read during an unfinished save and decode later.

Ledger files have a 64 MiB encoded-byte ceiling, with no separate queue or history
entry-count cap. Saves reject larger encoded snapshots before replacement so they
cannot commit a file the loader would reject. Loads reuse `PrivateRuntimeMetadata`:
no-follow/nonblocking/close-on-exec open, descriptor-based regular-file and current-user
ownership checks, one hard link, and a size check before any content read. Reads are
at most 64 KiB per chunk and 64 MiB overall. Descriptor and pathname identity, size,
permissions, ownership, and modification/change times must match after reading.
Duplicate JSON keys at every depth are rejected before typed millisecond-date decoding.
Checked I/O remains separate from the JSON-decoding telemetry span, which includes
both duplicate-key validation and typed decoding and records either kind of failure.
Only a missing file yields an empty snapshot; oversized, malformed, replaced, or
unreadable files propagate errors without rewriting or deleting the ledger.

Ordinary runtime messages, task history, compatibility archives and debug bridge
replies do not sort object keys. Canonical ordering remains where serialized
data is hashed, used for equality or stable ordering, or emitted as deterministic
prompt data and generated artifacts. Array order and JSON contents are preserved.

Reused codecs remove repeated allocation and configuration; ordinary storage
also skips sorting. Serial coding still has overhead, so task-level speed gains
are expected to be small. JSON schemas, prompts, model calls, permissions, and
user interaction remain unchanged.

`ConfiguredJSONCodecTests` checks stored values, legacy sorted-file decoding,
date units, fingerprint compatibility, recovery after coding errors, concurrent
store copies, and concurrent profile saves. A pipe-based `TaskOwnershipTests` fixture checks
repeated snake-case metrics, ignored invalid messages, optional legacy fields,
and a fresh subsequent invocation. Fixtures use temporary local files and
synthetic runtime helpers without provider or desktop actions.

`TaskLedgerSerializationTests` gates older writes both before replacement and before
permission finalization while a newer snapshot is submitted through a store copy.
It checks final queue/history/authorization contents, blocked reads, error propagation,
and recovery for the next save. Restoring encode-only serialization makes the
overlapping-save regression fail. Existing queued-edit tests continue to check that
failed persistence cannot publish an edited request as saved.
`TaskLedgerReadTests` checks sparse oversized files without reading their contents,
legacy records, short reads, duplicate/malformed JSON, links and nonregular files,
growth/truncation/replacement/removal during reads, and descriptor closure.

History grouping sorts entries once with input order as a stable tie-break for
identical finish times, then computes year/month/day components and each day boundary
once per entry. Ordered key builders preserve numeric year/month ordering and absolute
day ordering for the selected `Calendar`, including year resets across non-Gregorian
eras. New year, month and day keys enter ordered builders by binary insertion; the
lookup dictionaries merge keys that recur across era boundaries. Entries already
arrive newest-first within each day, so the implementation makes no per-day sorted copies
or final group sorting pass. `TaskLedgerHistoryGroupingTests` compares the full result
against the previous grouping for 20,000 synthetic New York history records, checks
daylight-saving boundaries and Japanese era-year resets, and uses work counters for
source sorts, calendar reads, day-bucket arrays, entry appends, and eliminated per-day
sort copies. On that fixture, the reference implementation creates over 8,000 sorted
copies in addition to its year/month/day full-entry bucket arrays, makes 60,000 calendar
lookups, and appends every record to three grouping buckets. The new path appends each
history entry to one day bucket, creates one day-entry bucket per day, makes 40,000
calendar calls (one combined date-components query and one day-boundary lookup per
record), and creates zero per-day sorted-copy arrays. Counters instrument both the
reference and new implementations; timing is descriptive and is not used as a threshold.
