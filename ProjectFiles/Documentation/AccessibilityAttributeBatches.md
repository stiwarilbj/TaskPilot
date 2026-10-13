# Accessibility observation attribute batches

Observation collection retrieves each control's role, subrole, title, description,
help, position, size, enabled state, and focus in one
`AXUIElementCopyMultipleAttributeValues` call with zero options. The accepted values
feed both the observation row and its private target record. Field values and
selections remain separate reads after the existing secure-field check. Immediate
pre-action identity, focus, permission, and enabled-state checks remain fresh.

The result is positional: an `AXValue` containing an `AXError` retains that
attribute's error code, while `CFNull` indicates a missing value without a known
code. Neither can become a label, role, or coordinate. Successful neighboring
attributes remain usable. Required role failures prevent executable targets;
unreliable subroles keep text masked. Optional missing values preserve existing
defaults and label fallback behavior.

Unsupported batches fall back to individual reads within the same collection
deadline and retry budget. The collector remembers this fallback for at most 32
apps during that staging collection, then discards it. A successful batch with a
missing or misaligned result array reports incomplete Accessibility data and uses
the same fallback. Global permission, transport, or invalid-element failures do
not fan out into individual queries. A transient per-attribute failure may retry
only that attribute, sharing the existing eight-retry collection limit. Task
ownership and deadlines are checked around reads; timeouts reset afterward.

This reduces the healthy metadata group from nine attribute queries to one. It
adds no model requests, persistent control data, frontend controls, or setup.
The API does not guarantee that an application's attributes are atomic; existing
screenshot/control consistency checks still decide whether to publish a staged
observation.

Offline tests inject batch/single readers and timeout setters. They cover normal
metadata, label fallback, nulls, encoded errors, malformed arrays and identity,
unsupported batching, shared retry limits, secure masking, deadlines, revocation,
and fresh values on later snapshots. No app is launched or controlled by these
tests. Live compatibility and accuracy validation remain incomplete.

API semantics: [Apple's multiple-attribute read documentation](https://developer.apple.com/documentation/applicationservices/1462051-axuielementcopymultipleattribute?changes=__4&language=objc).
