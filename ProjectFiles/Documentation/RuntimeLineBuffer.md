# Runtime line buffer

Task stdout uses an invocation-owned `RuntimeLineBuffer`. It uses native
`memchr` to scan only newly appended bytes, advances a read cursor for complete
LF-delimited lines, and retains a partial line until its delimiter or
process-exit flush arrives.
Empty LF lines are skipped; CR, invalid UTF-8, and other bytes remain unchanged
for the existing JSON decoder. Returned lines own their bytes independently.

Consumed storage is compacted once per append when the prefix reaches 64 KiB
and occupies at least half the buffer. Fully consumed storage is cleared; a
large burst or exit flush also releases retained capacity. An unfinished line
keeps the existing unrestricted framing behavior. Byte-relative cursors remain
valid when Foundation Data has a nonzero start index after compaction.

The runtime's serialized I/O queue, generation ownership, message handling, and
termination drainage are unchanged. No prompts, model calls, actions, setup,
or interface behavior are added.

## Regression coverage

`RuntimeLineBufferTests` checks chunk boundaries, split UTF-8, arbitrary bytes,
blank lines, CRLF, incomplete lines, EOF, compaction thresholds, repeated
compaction, independent invocations, returned-line lifetimes, and parity with
the previous parser across deterministic fragmented streams.
`TaskOwnershipTests` also passes 1,200 synthetic messages through real helper
pipes and verifies ordering and exactly one terminal event with no bridge calls.
These fixtures do not control desktop apps or contact providers.

## Reproduce the benchmark

From the repository root:

```sh
mkdir -p ProjectFiles/.taskpilot-build
swiftc -O \
  ProjectFiles/Sources/OrbitAgent/Agent/Runtime/RuntimeLineBuffer.swift \
  ProjectFiles/Tests/Benchmarks/RuntimeLineBuffer/main.swift \
  -o ProjectFiles/.taskpilot-build/benchmark-runtime-lines
ProjectFiles/.taskpilot-build/benchmark-runtime-lines
```

Replace `-O` with `-Onone -g` to match the current bundled app's debug build.

The standalone benchmark compares the previous prefix-removing parser with
the production buffer. It validates byte-for-byte parity before timing, warms
both implementations, alternates their order across five samples, and reports
median milliseconds per full stream. Fixture construction is outside timing;
line collection and an equal checksum are included. Data is synthetic only.

An optimized run on arm64 macOS with Apple Swift 6.3.3 on 2026-10-13 measured:

| Fixture | Bytes | Chunks | Previous median ms | Cursor median ms | Ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| Single decision | 209 | 1 | 0.0010 | 0.0004 | 2.50× |
| 10,000-message burst, 64 KiB chunks | 1,658,936 | 26 | 7.8086 | 0.7627 | 10.24× |
| 10,000-message burst, one chunk | 1,658,936 | 1 | 127.3083 | 0.9277 | 137.24× |
| 1,000 messages, 317-byte chunks | 164,936 | 521 | 0.6811 | 0.1474 | 4.62× |
| Incomplete 64 KiB line, 32-byte chunks | 65,536 | 2,048 | 185.1469 | 0.1092 | 1,694.71× |

The same fixtures compiled with `-Onone -g` measured:

| Fixture | Previous median ms | Cursor median ms | Ratio |
| --- | ---: | ---: | ---: |
| Single decision | 0.0038 | 0.0014 | 2.71× |
| 10,000-message burst, 64 KiB chunks | 21.1787 | 1.9391 | 10.92× |
| 10,000-message burst, one chunk | 144.2283 | 2.0655 | 69.83× |
| 1,000 messages, 317-byte chunks | 2.3702 | 0.4080 | 5.81× |
| Incomplete 64 KiB line, 32-byte chunks | 519.1950 | 0.5134 | 1,011.34× |

These measurements isolate local framing and result handling. They vary by
machine and stream shape and do not establish end-to-end speed or live accuracy.
