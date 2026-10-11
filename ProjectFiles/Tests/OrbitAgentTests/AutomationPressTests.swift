import ApplicationServices
import XCTest
@testable import OrbitAgent

final class AutomationPressTests: XCTestCase {
    func testSuccessfulPressNeverClicksAgain() throws {
        var presses = 0, clicks = 0
        let method = try AutomationPressPolicy.deliver(preflight: {}, press: {
            presses += 1; return .success
        }, fallback: { clicks += 1 })
        XCTAssertEqual(method, "accessibility")
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(clicks, 0)
    }

    func testExplicitUnsupportedPressAllowsOneRevalidatedFallback() throws {
        for error in [AXError.actionUnsupported, .notImplemented] {
            var checks = 0, presses = 0, clicks = 0
            let method = try AutomationPressPolicy.deliver(preflight: { checks += 1 }, press: {
                presses += 1; return error
            }, fallback: { clicks += 1 })
            XCTAssertEqual(method, "coordinate")
            XCTAssertEqual(checks, 2)
            XCTAssertEqual(presses, 1)
            XCTAssertEqual(clicks, 1)
        }
    }

    func testAmbiguousPressNeverUsesAnotherDeliveryMethod() {
        for error in [AXError.cannotComplete, .failure, .illegalArgument, .noValue] {
            var clicks = 0
            XCTAssertThrowsError(try AutomationPressPolicy.deliver(preflight: {}, press: { error }, fallback: { clicks += 1 })) { error in
                XCTAssertEqual((error as? AccessibilityActionError)?.code, "delivery_uncertain")
            }
            XCTAssertEqual(clicks, 0)
        }
    }

    func testPermissionAndStaleFailuresRemainClassifiedWithoutFallback() {
        for (error, code) in [(AXError.apiDisabled, "permission_denied"), (.invalidUIElement, "stale_target")] {
            var clicks = 0
            XCTAssertThrowsError(try AutomationPressPolicy.deliver(preflight: {}, press: { error }, fallback: { clicks += 1 })) { error in
                XCTAssertEqual((error as? AccessibilityActionError)?.code, code)
            }
            XCTAssertEqual(clicks, 0)
        }
    }

    func testTargetChangedAfterUnsupportedPressPreventsClick() {
        var checks = 0, clicks = 0
        XCTAssertThrowsError(try AutomationPressPolicy.deliver(preflight: {
            checks += 1
            if checks == 2 { throw AccessibilityActionError.staleObservation }
        }, press: { .actionUnsupported }, fallback: { clicks += 1 })) { error in
            XCTAssertEqual((error as? AccessibilityActionError)?.code, "stale_target")
        }
        XCTAssertEqual(clicks, 0)
    }

    func testPointerHitRejectionDoesNotReplaySemanticPress() {
        var presses = 0, clicks = 0
        XCTAssertThrowsError(try AutomationPressPolicy.deliver(preflight: {}, press: {
            presses += 1; return .actionUnsupported
        }, fallback: {
            try AutomationTargetPolicy.deliver(preflight: { throw AccessibilityActionError.staleObservation },
                                               event: { clicks += 1 })
        }))
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(clicks, 0)
    }

    func testCancellationStopsBeforeAnyDelivery() {
        var deliveries = 0
        XCTAssertThrowsError(try AutomationPressPolicy.deliver(preflight: { throw AccessibilityActionError.cancelled },
            press: { deliveries += 1; return .success }, fallback: { deliveries += 1 })) { error in
            XCTAssertEqual((error as? AccessibilityActionError)?.code, "cancelled")
        }
        XCTAssertEqual(deliveries, 0)
    }
}
