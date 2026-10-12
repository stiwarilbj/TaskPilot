# Bounded control compatibility profiles

The native executor keeps method compatibility by app installation, version,
build, control role/subrole and action. Profiles guide an initial delivery
method; they are neither target authority nor proof that a task completed.
All current observation, target, window, focus, foreground, permission,
secure-input and ownership checks remain in place.

Only a verified method can outrank the ordinary default, and only among the
methods already permitted for that action. Text replacement still requires
direct value setting or acknowledged whole-field selection. Insertion cannot
become replacement. Accepted or uncertain text delivery ends the delivery
phase; an unconfirmed result never starts another method. Secure/private input
neither consults nor trains profiles. Idempotent no-op text checks train no
delivery method.

Semantic press retains Accessibility preference when AXPress is currently
advertised. A coordinate route can start directly only when fresh capability
metadata lacks AXPress, the profile records explicit AXPress rejection, and
that existing session/HID route was locally verified. Coordinate delivery
still validates the current element bounds, pointer hit and foreground.
Profiles never extend HID delivery to an app outside the existing wrapper
compatibility rule.

Acknowledgement records support without claiming verification. Text methods
become verified only after matched readback. Pointer methods require a change
at the validated control: selection, expansion, a binary checkbox/radio value
or editable-field focus. A generic screen change does not train verification.
These facts describe method compatibility only; the existing expected-effect
checks and whole-request coverage gate still decide task completion. Explicit
method rejection and unconfirmed delivery remove the method's preference
without replaying input.

The cache has at most 128 profiles and six methods per profile. Each method's
evidence expires after seven days independently of newer feedback for other
methods. Least-recently-used profiles are evicted. App version/build or binary
and Info.plist metadata changes, role capabilities, wrapper routing and display
mode changes invalidate the matching revision. Permission, macOS, shared
contract and private delivery-policy changes invalidate the entire cache.
Missing version metadata, unknown capability responses and a bundle updated
after process launch disable profiling until trustworthy metadata is available.

Private `Application Support/TaskPilot/ControlCompatibility.json` storage is
bounded to 256 KiB and owner-readable/writable. It contains hashes of metadata,
method enums, support/verification states and timestamps. It contains no PIDs,
task IDs, labels, window titles, coordinates, values, commands or credentials.
Unreadable, corrupt, incompatible, oversized or symbolic cache files safely
fall back to ordinary delivery; cache write errors never fail an action.
Profiles remain outside prompts and task history and add no model requests.

Metadata operations use the task lifecycle gate without marking an action
receipt dispatched. Late results cannot restore a superseded profile revision
or write from a stopped task. No new UI controls, setup or permissions exist.

Offline tests cover learning and reuse, invalidation, expiry/eviction, storage
privacy, stale feedback, method reporting, focus, secure input and uncertain
delivery without duplication. No fixer, live-control tester, Chrome interaction
or live desktop task is run for this change. Live accuracy remains unverified.
