import XCTest
@testable import OrbitAgent

final class HousekeepingScheduleTests: XCTestCase {
    private final class SleepProbe: @unchecked Sendable {
        let start = ContinuousClock.now
        let lock = NSLock()
        private var requests: [(Duration, Duration?)] = []
        var recorded: [(Duration, Duration?)] { lock.withLock { requests } }
        func record(_ deadline: ContinuousClock.Instant, _ tolerance: Duration?) {
            lock.withLock { requests.append((start.duration(to: deadline), tolerance)) }
        }
    }

    private struct ProbeClock: Clock {
        let probe: SleepProbe
        var now: ContinuousClock.Instant { probe.start }
        var minimumResolution: Duration { .nanoseconds(1) }
        var onSleep: @Sendable () -> Void = {}
        var suspend = false
        func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
            probe.record(deadline, tolerance)
            onSleep()
            if suspend { try await ContinuousClock().sleep(until: deadline, tolerance: tolerance) }
        }
    }

    func testNonurgentPollsPassBoundedLeewayToClockWithoutExtraTimers() async throws {
        for (schedule, interval, tolerance) in [
            (HousekeepingSchedule.readiness, Duration.seconds(5), Duration.milliseconds(500)),
            (.permissions, .seconds(1), .milliseconds(100))
        ] {
            let probe = SleepProbe()
            try await schedule.wait(clock: ProbeClock(probe: probe))
            XCTAssertEqual(probe.recorded.count, 1)
            XCTAssertEqual(probe.recorded.first?.0, interval)
            XCTAssertEqual(probe.recorded.first?.1, tolerance)
            XCTAssertGreaterThan(tolerance, .zero)
            XCTAssertLessThan(tolerance, interval)
        }
    }

    func testCancellationWakesActualSleepWithoutWaitingForIntervalOrLeeway() async throws {
        for schedule in HousekeepingSchedule.allCases {
            let entered = expectation(description: "Sleeping \(schedule)")
            let probe = SleepProbe()
            let worker = Task {
                try await schedule.wait(clock: ProbeClock(probe: probe, onSleep: { entered.fulfill() }, suspend: true))
            }
            await fulfillment(of: [entered], timeout: 1)
            let cancelled = expectation(description: "Cancelled \(schedule)")
            worker.cancel()
            let observer = Task {
                do { try await worker.value; XCTFail("Cancelled housekeeping continued") }
                catch is CancellationError {}
                catch { XCTFail("Unexpected error: \(error)") }
                cancelled.fulfill()
            }
            await fulfillment(of: [cancelled], timeout: 0.5)
            await observer.value
            XCTAssertEqual(probe.recorded.count, 1)
        }
    }

    func testCancellationBeforeSchedulingDoesNotInstallAnotherWait() async {
        let probe = SleepProbe()
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await HousekeepingSchedule.readiness.wait(clock: ProbeClock(probe: probe)); XCTFail("Cancelled worker slept") }
            catch is CancellationError {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await worker.value
        XCTAssertTrue(probe.recorded.isEmpty)
    }

    func testCancellationAtWakePreventsAnotherMaintenancePass() async {
        let probe = SleepProbe()
        let worker = Task {
            do {
                try await HousekeepingSchedule.permissions.wait(clock: ProbeClock(probe: probe, onSleep: {
                    withUnsafeCurrentTask { $0?.cancel() }
                }))
                XCTFail("Cancelled wake permitted another refresh")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
        await worker.value
        XCTAssertEqual(probe.recorded.count, 1)
    }
}
