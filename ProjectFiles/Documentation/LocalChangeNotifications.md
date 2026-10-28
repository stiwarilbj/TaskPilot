# Local checks awakened by notifications

TaskPilot uses scoped macOS Accessibility observers and filesystem vnode
notifications during local settling and outcome readback. Notifications are
signals to inspect state, not proof that an event was delivered or that the
requested effect occurred. They make no model requests and dispatch no actions.

Each native wait creates its subscription before its initial targeted check.
This closes the registration race: an effect that happened before registration
is found by the check, and a subsequent change can wake the check. Unsupported,
irrelevant, missing, and coalesced events retain a maximum 500 ms polling
fallback. Notification bursts have a bounded 50 ms debounce. Existing settling
deadlines and the two-second file/readback bounds are shared rather than renewed.

Accessibility registration deduplicates element/notification pairs by native
element identity (`CFHash` with `CFEqual` collision checks), never by labels or
coordinates. The intended target and its container are considered first,
followed by application-level notifications and then remaining candidates. A
wait attempts at most 32 registrations; unsupported or over-limit pairs do not
disable the existing polling fallback. Successful pairs alone are removed when
the scoped observer closes.

For a supported field expectation, the native probe reads the current observed
field and checks its app identity, owner window, label, role, and secure-input
exclusion. Dialog probes search only the intended app's window subtree, bounded
to 200 nodes, 12 levels, and 100 ms. Incomplete probes ask for fresh paired
evidence. A positive probe is only a capture candidate: Python still requires
the existing expected-effect validator to find the exact condition in an
accepted consistent screenshot/control observation. Ordinary screen changes
and graphics-only apps keep bounded complete-observation fallback checks.
The wait reserves 500 ms of its remaining budget for paired observation.

File checks watch both the target and its nearest existing parent, including a
resolved symlink destination where applicable. This covers ordinary writes,
atomic replacement, deletion, and creation of missing directories. Watchers
are rearmed when inode or ancestor identity changes. Exact bounded native
readbacks remain authoritative; unrelated directory changes, successful command
exit, and notification counts cannot prove requested contents. Healthy exact
native results are reused without another check.

Text-entry readback uses the same wake mechanism and fallback. This changes
waiting only; existing focus, secure-input, delivery, and replay protections
still apply.

Subscriptions belong to one native bridge operation and task suspension epoch.
Stop/cancellation wakes the waiter and drains its AX registration and file
descriptors before the operation ends. Pause/Resume discards the old epoch's
subscription and requests fresh evidence. Stopped or superseded generations
cannot publish a readback or wake a newer task. Timer, notification, and
cancellation races resume a continuation exactly once. No persistent observers,
paths, control values, or notification payloads are stored.

Only aggregate `local_notifications`, `local_targeted_checks`, and
`local_poll_wakeups` counts enter private task metrics. Watcher capability flags
and counters stay out of prompts and evidence. The local-wait policy version is
part of decision-cache and offline-regression identities. The interface, setup,
permissions, model defaults, and action contract are unchanged.

Offline coverage includes controlled notifications, absent/unsupported events,
wrong expectations, delayed fields/dialogs, stale targets, cancellation,
Pause/Resume, superseded tasks, timer races, and temporary-file notifications
through the native bridge. Swift, Python, setup integration, generated-artifact,
and scripted prompt replay checks are required before bundling. No fixer,
live-control tester, Chrome, provider calls, or live desktop task is used for
validation; real-app notification support and live accuracy remain unverified.
