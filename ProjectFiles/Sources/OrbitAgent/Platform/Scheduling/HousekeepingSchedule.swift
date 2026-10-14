import Foundation

/// Only nonurgent preflight polling belongs here; task deadlines use their
/// existing clocks. Cancellation wakes a suspended worker without this leeway.
enum HousekeepingSchedule: CaseIterable {
    case readiness
    case permissions

    var interval: Duration {
        switch self {
        case .readiness: return .seconds(5)
        case .permissions: return .seconds(1)
        }
    }

    var tolerance: Duration {
        switch self {
        case .readiness: return .milliseconds(500)
        case .permissions: return .milliseconds(100)
        }
    }

    func wait() async throws { try await wait(clock: ContinuousClock()) }

    func wait<C: Clock>(clock: C) async throws where C.Duration == Duration {
        try Task.checkCancellation()
        try await Task.sleep(for: interval, tolerance: tolerance, clock: clock)
        try Task.checkCancellation()
    }
}
