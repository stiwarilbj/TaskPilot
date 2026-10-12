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

    func testVerifiedCoordinatePreferenceRequiresCurrentUnsupportedCapabilitiesAndPreflight() throws {
        var presses = 0, clicks = 0, checks = 0
        let method = try AutomationPressPolicy.deliver(preferVerifiedCoordinate: true, pressAdvertised: false,
            preflight: { checks += 1 }, press: { presses += 1; return .success }, fallback: { clicks += 1 })
        XCTAssertEqual(method, "coordinate")
        XCTAssertEqual(presses, 0); XCTAssertEqual(clicks, 1); XCTAssertEqual(checks, 1)
        XCTAssertThrowsError(try AutomationPressPolicy.deliver(preferVerifiedCoordinate: true, pressAdvertised: false,
            preflight: { throw AccessibilityActionError.staleObservation }, press: { presses += 1; return .success }, fallback: { clicks += 1 }))
        XCTAssertEqual(presses, 0); XCTAssertEqual(clicks, 1)
    }

    func testPreferenceCannotSkipAdvertisedAccessibilityOrReplayUncertainPress() {
        var clicks = 0, presses = 0
        XCTAssertThrowsError(try AutomationPressPolicy.deliver(preferVerifiedCoordinate: true, pressAdvertised: true,
            preflight: {}, press: { presses += 1; return .cannotComplete }, fallback: { clicks += 1 })) { error in
                XCTAssertEqual((error as? AccessibilityActionError)?.code, "delivery_uncertain")
        }
        XCTAssertEqual(presses, 1); XCTAssertEqual(clicks, 0)
    }

    func testExplicitPressEvidenceIsReportedWithoutNewDelivery() throws {
        var results: [AXError] = [], clicks = 0
        _ = try AutomationPressPolicy.deliver(recordPress: { results.append($0) }, preflight: {},
            press: { .actionUnsupported }, fallback: { clicks += 1 })
        XCTAssertEqual(results, [.actionUnsupported]); XCTAssertEqual(clicks, 1)
    }

    func testProfileReusesOnlyAVerifiedCoordinateRouteWithoutDuplicatePresses() throws {
        let environment = ControlCompatibilityProfiles.fingerprint(["fixture"])
        let profiles = ControlCompatibilityProfiles(environment: environment)
        let key = ControlCompatibilityProfiles.Key(appID: "fixture", bundlePath: "/fixture.app", version: "1", build: "1",
            executableRevision: "1", role: "AXCheckBox", subrole: "", action: .press, capabilities: ["press": false],
            hid: false, mainDisplay: false, environment: environment)
        var clicks = 0, presses = 0
        for _ in 0..<2 {
            let preferred = profiles.preferred(for: key, permitted: [.accessibility, .session_event])
            _ = try AutomationPressPolicy.deliver(
                preferVerifiedCoordinate: preferred == .session_event && profiles.evidence(for: key, method: .accessibility) == .unsupported,
                pressAdvertised: key.pressAdvertised, recordPress: { result in
                    if result == .actionUnsupported { profiles.record(.unsupported, method: .accessibility, for: key) }
                }, preflight: {}, press: { presses += 1; return .actionUnsupported }, fallback: { clicks += 1 })
            if ControlInteractionState(toggle: false).verifies(ControlInteractionState(toggle: true)) {
                profiles.record(.verified, method: .session_event, for: key)
            }
        }
        XCTAssertEqual(presses, 1); XCTAssertEqual(clicks, 2)
        // An unconfirmed route has no preference, so the semantic default is
        // tried again only for a new logical action, never a mutation replay.
        profiles.record(.unconfirmed, method: .session_event, for: key)
        XCTAssertEqual(profiles.preferred(for: key, permitted: [.accessibility, .session_event]), .accessibility)
    }
}
