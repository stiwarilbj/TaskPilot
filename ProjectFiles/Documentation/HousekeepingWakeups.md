# Housekeeping wakeup tolerance

Only quiet preflight polling uses `HousekeepingSchedule`:

| Work | Existing interval | Explicit tolerance |
| --- | --- | --- |
| Ordinary readiness refresh | 5 seconds | 500 milliseconds |
| Permission-settings monitor | 1 second | 100 milliseconds |

The coordinator owns these loops. The main window starts the same immediate
readiness check and cancels its worker through SwiftUI's existing task lifetime;
view layout, controls, and explicit refresh buttons are unchanged. Permission
monitoring retains its existing maximum of 90 checks and stops when permissions
are ready. Both waits use Swift's nonblocking, cancellation-aware
[`Task.sleep(for:tolerance:clock:)`](https://developer.apple.com/documentation/swift/task/sleep%28for%3Atolerance%3Aclock%3A%29).
Positive tolerance gives the scheduler an explicit opportunity to coalesce
nonurgent wakeups. It is not a guaranteed delay or a measured energy saving.

Cancellation checks bracket each wait so a cancelled wake cannot authorize
another maintenance pass. No extra timer, persistent worker, model request,
capture, or command is created. Current cache pruning remains access-triggered,
with disposable caches also released on memory-pressure events; no periodic
pruning source is introduced.

Task execution deadlines, command timeout and process-exit handling, Stop and
drain monitoring, activation, observation consistency, settling, notifications
for local effects, provider cooldowns, and cursor/preview timing keep their
existing schedules. The policy has no generic task-deadline case.

Offline clock tests check the actual intervals/tolerances supplied to the sleep
API and cancellation before scheduling, during a real suspended clock wait,
and at wakeup. Full suites retain coverage for command timeouts, task ownership,
shutdown, and action/observation waits. No fixer, live-control tester, Chrome,
provider calls, or live desktop tasks are run; live validation remains incomplete.
