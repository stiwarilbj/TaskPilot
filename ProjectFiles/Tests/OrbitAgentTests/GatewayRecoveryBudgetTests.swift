import Foundation
import XCTest
@testable import OrbitAgent

/// Injected clocks and serialized fixtures only; no Gateway or system clock changes.
final class GatewayRecoveryBudgetTests: XCTestCase {
    private func clock(_ uptime: TimeInterval, shift: TimeInterval = 0, boot: String = "boot-a") -> GatewayRecoveryClock {
        GatewayRecoveryClock(bootSession:boot, wall:1_000_000 + uptime + shift, monotonic:uptime)
    }
    private func roundTrip(_ budget: GatewayRecoveryBudget) throws -> GatewayRecoveryBudget {
        try JSONDecoder().decode(GatewayRecoveryBudget.self, from:JSONEncoder().encode(budget))
    }
    private func exhausted() -> GatewayRecoveryBudget {
        var budget = GatewayRecoveryBudget()
        for time in [1000.0, 1001, 1004, 1014] { _ = budget.failed(at:clock(time)) }
        return budget
    }

    func testSameBootHostRestartPreservesExactWindowAndCooldown() throws {
        var budget = try roundTrip(exhausted())
        XCTAssertFalse(budget.synchronize(at:clock(1015)))
        XCTAssertFalse(budget.probeIsDue(at:clock(1073.999)))
        XCTAssertTrue(budget.probeIsDue(at:clock(1074)))
        XCTAssertEqual(budget.restarts.count, 3)
        XCTAssertTrue(budget.synchronize(at:clock(1603.999)))
        XCTAssertEqual(budget.restarts.count, 1) // Only the attempt at 1004 remains.
        XCTAssertTrue(budget.synchronize(at:clock(1604)))
        XCTAssertEqual(budget.restarts.count, 0)
        XCTAssertEqual(budget.failed(at:clock(1604)), 1)
    }

    func testWallClockJumpsCannotEraseAttemptsOrCreateHoursOfCooldown() throws {
        for shift in [-1_000_000_000.0, -86_400, 86_400] {
            var budget = try roundTrip(exhausted())
            XCTAssertTrue(budget.synchronize(at:clock(1015, shift:shift)))
            XCTAssertEqual(budget.restarts.count, 3)
            XCTAssertEqual(budget.monotonicProbeDeadline, 1075)
            XCTAssertEqual(budget.nextProbe - clock(1015, shift:shift).wall, 60)
            budget = try roundTrip(budget)
            for time in [1015.0, 1030, 1074.999] {
                XCTAssertFalse(budget.synchronize(at:clock(time, shift:shift)))
                XCTAssertFalse(budget.probeIsDue(at:clock(time, shift:shift)))
            }
            XCTAssertTrue(budget.probeIsDue(at:clock(1075, shift:shift)))
            XCTAssertEqual(budget.restarts.count, 3)
            _ = budget.synchronize(at:clock(1604, shift:shift))
            XCTAssertEqual(budget.restarts.count, 0) // Expiry still follows the original uptime.
        }
    }

    func testClockAdjustmentKeepsLaterValidCircuitAndReservedAttempt() {
        var budget = exhausted()
        XCTAssertEqual(budget.failed(at:clock(1074)), 120)
        _ = budget.synchronize(at:clock(1075, shift:100))
        XCTAssertEqual(budget.monotonicProbeDeadline, 1194)
        XCTAssertFalse(budget.probeIsDue(at:clock(1135, shift:100)))

        var reserved = GatewayRecoveryBudget()
        XCTAssertEqual(reserved.failed(at:clock(1000)), 1)
        _ = reserved.synchronize(at:clock(1000.5, shift:-100))
        XCTAssertTrue(reserved.restartReserved)
        XCTAssertEqual(reserved.restarts.count, 1)
        XCTAssertEqual(reserved.monotonicProbeDeadline, 1060.5)
    }

    func testRebootRebasesUnknownAgeOnceWithoutResettingSpentAttempts() throws {
        for shift in [-86_400.0, 86_400] {
            var budget = try roundTrip(exhausted())
            _ = budget.synchronize(at:clock(2, shift:shift, boot:"boot-b"))
            XCTAssertEqual(budget.restarts.count, 3)
            XCTAssertEqual(budget.monotonicProbeDeadline, 62)
            XCTAssertFalse(budget.restartReserved)
            budget = try roundTrip(budget) // Another host on the new boot must not extend the hold.
            XCTAssertFalse(budget.synchronize(at:clock(30, shift:shift, boot:"boot-b")))
            XCTAssertFalse(budget.probeIsDue(at:clock(61.999, shift:shift, boot:"boot-b")))
            XCTAssertTrue(budget.probeIsDue(at:clock(62, shift:shift, boot:"boot-b")))
            XCTAssertEqual(budget.failed(at:clock(62, shift:shift, boot:"boot-b")), 120)
            _ = budget.synchronize(at:clock(602, shift:shift, boot:"boot-b"))
            XCTAssertTrue(budget.restarts.isEmpty)
            XCTAssertEqual(budget.failed(at:clock(602, shift:shift, boot:"boot-b")), 1)
        }
    }

    func testUptimeRegressionUsesTheSameBoundedConservativePath() throws {
        var budget = try roundTrip(exhausted())
        XCTAssertTrue(budget.synchronize(at:clock(500)))
        XCTAssertEqual(budget.restarts.count, 3)
        XCTAssertEqual(budget.monotonicProbeDeadline, 560)
        XCTAssertFalse(budget.probeIsDue(at:clock(559.999)))
        budget = try roundTrip(budget)
        XCTAssertFalse(budget.synchronize(at:clock(550)))
        XCTAssertTrue(budget.probeIsDue(at:clock(560)))
        _ = budget.synchronize(at:clock(1100))
        XCTAssertTrue(budget.restarts.isEmpty)
    }

    func testHealthyEmptyBudgetDoesNotGainARebootPenaltyOrRewriteOnRefresh() throws {
        var budget = GatewayRecoveryBudget()
        budget.healthy(at:clock(1000))
        budget = try roundTrip(budget)
        XCTAssertFalse(budget.synchronize(at:clock(1100)))
        XCTAssertFalse(budget.synchronize(at:clock(1100, shift:1))) // Small clock slews do not create holds.
        _ = budget.synchronize(at:clock(1, boot:"boot-b"))
        XCTAssertTrue(budget.probeIsDue(at:clock(1, boot:"boot-b")))
        XCTAssertEqual(budget.nextProbe, 0)
        XCTAssertFalse(budget.synchronize(at:clock(2, boot:"boot-b")))
    }

    func testLegacyRecordsMigrateOnceAndFutureDatesReceiveOnlyBoundedHolds() throws {
        let old = #"{"restarts":[1000990,1000991,1000994],"nextProbe":1001060,"circuits":1}"#
        var budget = try JSONDecoder().decode(GatewayRecoveryBudget.self, from:Data(old.utf8))
        _ = budget.synchronize(at:clock(1000))
        XCTAssertEqual(budget.restarts, [1000990,1000991,1000994])
        XCTAssertEqual(budget.monotonicProbeDeadline, 1060)
        XCTAssertFalse(budget.restartReserved)
        budget = try roundTrip(budget)
        XCTAssertFalse(budget.synchronize(at:clock(1001)))

        let future = #"{"restarts":[2000000,2000001,2000004],"nextProbe":2000300,"circuits":1}"#
        budget = try JSONDecoder().decode(GatewayRecoveryBudget.self, from:Data(future.utf8))
        _ = budget.synchronize(at:clock(1000))
        XCTAssertEqual(budget.monotonicProbeDeadline, 1060)
        XCTAssertEqual(budget.restarts.count, 3)

        let expired = #"{"restarts":[1,2,3],"nextProbe":70,"circuits":1}"#
        budget = try JSONDecoder().decode(GatewayRecoveryBudget.self, from:Data(expired.utf8))
        _ = budget.synchronize(at:clock(1000))
        XCTAssertTrue(budget.restarts.isEmpty)
        XCTAssertTrue(budget.probeIsDue(at:clock(1000)))
    }

    func testInvalidNewTimingNeverFallsBackToAnEmptyFreshBudget() throws {
        let data = try JSONEncoder().encode(exhausted())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let cases: [(inout [String:Any]) -> Void] = [
            { $0["version"] = 99 },
            { $0["nextProbe"] = 900_000 },
            { $0["restarts"] = [2000,2001,2002] },
            { $0["restarts"] = [] },
            { $0["anchor"] = ["bootSession":"", "wall":1001014, "monotonic":1014] },
            { $0["anchor"] = ["bootSession":"boot-a", "wall":1001014, "monotonic":2000] },
            { $0["anchor"] = "damaged" }
        ]
        for mutate in cases {
            var object = original
            var timing = try XCTUnwrap(object["timing"] as? [String:Any])
            mutate(&timing); object["timing"] = timing
            object["circuits"] = Int.max // Damaged counters cannot overflow backoff arithmetic.
            var budget = try JSONDecoder().decode(GatewayRecoveryBudget.self, from:JSONSerialization.data(withJSONObject:object))
            _ = budget.synchronize(at:clock(1015))
            XCTAssertEqual(budget.restarts.count, 3)
            XCTAssertEqual(budget.monotonicProbeDeadline, 1075)
            XCTAssertFalse(budget.probeIsDue(at:clock(1074.999)))
            XCTAssertEqual(budget.failed(at:clock(1075)), 300)
        }
    }

    func testActualClockUsesOneBootMarkerAndMonotonicSamples() {
        let first = GatewayRecoveryClock.current
        let second = GatewayRecoveryClock.current
        XCTAssertFalse(first.bootSession.isEmpty)
        XCTAssertEqual(first.bootSession, second.bootSession)
        XCTAssertGreaterThanOrEqual(second.monotonic, first.monotonic)
    }
}
