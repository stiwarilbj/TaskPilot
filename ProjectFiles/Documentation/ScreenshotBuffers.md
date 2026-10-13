# Task-scoped screenshot buffers

Each task and explicit readiness check owns an in-memory screenshot scope.
Accepted observations are identified by screenshot path and observation revision
within that task generation. The first consumer reads the image once and computes
its existing BLAKE2b digest. Local settling checks, repeated planning inputs and
decision-cache identities reuse that digest. ACP lazily encodes the same bytes
as Base64 once, including response-format repair, model fallback and reconnect.

Only the accepted observation's original bytes are used. A later change to its
temporary file cannot change the image supplied during repair. A new observation
revision reads fresh bytes even if a path is reused. Separate tasks and readiness
checks cannot inherit each other's buffers. Fresh completion ACP sessions keep
their existing conversation isolation while using their own accepted observation.

Discarding an observation releases its bytes, digest and encoding and removes
its temporary file. An old revision cannot delete another buffered revision's
file when paths are reused. Task scope teardown clears remaining buffers on
success, startup failure, provider failure, cancellation or process shutdown.
The store remains outside observation dictionaries, prompts, persisted metrics
and task history. Screenshots continue to use the existing temporary-file path;
this change adds no persistent image cache.

Decision-cache fingerprints incorporate the buffered image digest rather than
reading and hashing the file again. The cache remains task-local and accepts
only validated decisions with the existing observation, instruction, purpose and
evidence identity. Screenshot pixels, image format, detail crops, model defaults,
repair budgets and request counts remain unchanged.

Offline tests exercise actual ACP serialization with fictional transport. They
assert one read and one encoding per image, exact image payloads, lazy encoding,
repair/fallback/reconnect reuse, fresh revisions, generation rejection, cleanup
and complete planning/verification task loops. Live desktop accuracy is not
validated by these tests.
