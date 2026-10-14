# Disposable caches under memory pressure

A single background macOS Dispatch memory-pressure source listens for warning
and critical events. Registrations have weak owners and are removed at teardown;
callbacks release cache ownership without updating the interface or delivering
desktop actions. Normal pressure does not evict or eagerly rebuild caches.
See Apple's [memory-pressure source](https://developer.apple.com/documentation/Dispatch/DISPATCH_SOURCE_TYPE_MEMORYPRESSURE).

Both warning and critical events evict:

- ScreenCaptureKit shareable-content metadata, retaining the existing 750 ms
  lifetime when cached. A refresh uses an epoch so a capture already waiting on
  macOS cannot refill a cache evicted in the meantime.
- Disposable command-help probe summaries. An epoch also prevents a pending
  probe from refilling these. Inspected command bindings remain available and
  continue to enforce executable identity, environment, and supported options.
- Python screenshot Base64 copies and derived observation representations:
  canonical JSON, fingerprints, progress signatures, and lookup indexes.
  Rebuilding uses the original accepted bytes and control snapshot, rather than
  rereading a possibly changed screenshot file.

Accepted image bytes and their digest, observation contents/revisions, evidence
ledgers, action receipts, task input bindings, valid decisions, runtime message
buffers, and in-flight command output remain intact. No model request, action,
screen capture, command probe, or evidence invalidation is caused by eviction.
Ordinary use may recreate a cleared helper cache with its existing bounded work.
Objects still referenced by an in-flight operation remain alive until that
operation releases them; eviction does not cancel work or promise immediate
whole-process memory reduction.

The bundled runtime advertises private memory-control support version 1 before
task startup. Only that invocation receives generation-bound pressure controls;
older helpers and readiness-only processes do not. The sole Python stdin reader
consumes controls separately from bridge and secure-input replies, allowing
eviction during ACP waits. Wrong-generation or unsupported pressure controls
are discarded. Scoped locks serialize disposal with representation construction
and task teardown. Native messages retain the existing ownership and drainage
guards. This adds no model prompt fields or public protocol requirements.

Offline tests inject synthetic warning/critical flags without creating actual
system pressure. They cover weak registration teardown, concurrent eviction,
late refill rejection, lazy reconstruction, generation checks, private control
negotiation, retained receipts/evidence, inspected command execution, and
unchanged healthy request counts. Live desktop validation remains incomplete;
no fixer, live-control tester, Chrome, provider calls, or desktop tasks are run.
Swapping reductions have not been measured.
