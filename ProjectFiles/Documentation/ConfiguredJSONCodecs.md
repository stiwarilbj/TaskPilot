# Configured JSON codecs

Repeated coding uses codecs with fixed configuration and private ownership:

| Owner | Codec | Configuration | Access scope |
| --- | --- | --- | --- |
| Runtime task invocation | Metrics decoder | Convert snake-case keys | Existing serialized runtime I/O queue |
| Task ledger store | Encoder and decoder | Millisecond dates; default object key ordering | Store-owned serial coding queue, shared by value copies |
| Compatibility profile store | Archive encoder | Default object key ordering | Store-owned serial coding queue; existing profile lock protects the snapshot and write |
| Compatibility key construction | Metadata encoder | Existing defaults | One synchronous invocation reuses it for both fingerprints |

Configuration is established before publication and remains fixed. Each store
or task invocation owns its codecs; they are not exposed through its interface.
Runtime messages are still checked against their invocation before decoding.
The ledger retains its `Sendable` value interface, existing atomic file writes,
permissions, camel-case persistence keys, and date units. Stored values remain
compatible with existing sorted files; readers do not depend on object key
order. Metadata fingerprints retain their existing bytes.

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
