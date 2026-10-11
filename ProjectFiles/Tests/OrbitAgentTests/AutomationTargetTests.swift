import XCTest
@testable import OrbitAgent

final class AutomationTargetTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let bounds = CGRect(x: 100, y: 150, width: 80, height: 30)
    private let windowBounds = CGRect(x: 50, y: 50, width: 600, height: 500)

    private func identity(pid: Int32 = 42, bundleID: String = "fixture.app",
                          launchDate: Date = Date(timeIntervalSince1970: 100),
                          role: String = "AXButton", subrole: String = "", label: String = "Save",
                          bounds: CGRect? = CGRect(x: 100, y: 150, width: 80, height: 30),
                          windowTitle: String? = "Draft",
                          windowBounds: CGRect? = CGRect(x: 50, y: 50, width: 600, height: 500)) -> AutomationTargetIdentity {
        AutomationTargetIdentity(application: AutomationApplicationIdentity(pid: pid, bundleID: bundleID,
            bundlePath: "/Applications/Fixture.app", name: "Fixture", launchDate: launchDate),
            role: role, subrole: subrole, label: label, bounds: bounds,
            windowTitle: windowTitle, windowBounds: windowBounds)
    }

    private func validate(_ current: AutomationTargetIdentity, sameWindow: Bool = true, enabled: Bool = true) throws {
        try AutomationTargetPolicy.validate(observed: identity(), current: current,
            sameWindow: sameWindow, enabled: enabled, displayFrame: display)
    }

    func testUnchangedControlDeliversExactlyOnce() throws {
        var checks = 0, deliveries = 0
        try AutomationTargetPolicy.deliver(preflight: {
            checks += 1
            try self.validate(self.identity())
        }, event: { deliveries += 1 })
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(deliveries, 1)
    }

    func testChangesAfterInitialValidationPreventDelivery() throws {
        try validate(identity())
        let changedTargets = [
            identity(pid: 43), identity(bundleID: "different.app"),
            identity(launchDate: Date(timeIntervalSince1970: 101)),
            identity(role: "AXTextField"), identity(subrole: "AXSecureTextField"),
            identity(label: "Delete"), identity(bounds: bounds.offsetBy(dx: 1, dy: 0)),
            identity(bounds: CGRect(x: 100, y: 150, width: 90, height: 30)),
            identity(bounds: nil), identity(windowTitle: "Different document"),
            identity(windowBounds: windowBounds.offsetBy(dx: 10, dy: 0)),
            identity(windowTitle: nil, windowBounds: nil)
        ]
        var deliveries = 0
        for changed in changedTargets {
            XCTAssertThrowsError(try AutomationTargetPolicy.deliver(preflight: {
                try self.validate(changed)
            }, event: { deliveries += 1 })) { error in
                XCTAssertEqual((error as? AccessibilityActionError)?.code, "stale_target")
            }
        }
        XCTAssertEqual(deliveries, 0)
    }

    func testReplacedWindowWithIdenticalTitleAndBoundsIsStale() {
        XCTAssertThrowsError(try validate(identity(), sameWindow: false)) { error in
            XCTAssertEqual((error as? AccessibilityActionError)?.code, "stale_target")
        }
    }

    func testDisabledControlDoesNotReceiveAnEvent() {
        var deliveries = 0
        XCTAssertThrowsError(try AutomationTargetPolicy.deliver(preflight: {
            try self.validate(self.identity(), enabled: false)
        }, event: { deliveries += 1 })) { error in
            XCTAssertEqual((error as? AccessibilityActionError)?.code, "disabled_target")
        }
        XCTAssertEqual(deliveries, 0)
    }

    func testInvalidAndOffscreenBoundsAreNeverAccepted() {
        for rectangle in [CGRect.zero, CGRect(x: 2000, y: 0, width: 80, height: 30),
                          CGRect(x: CGFloat.infinity, y: 0, width: 80, height: 30)] {
            let target = identity(bounds: rectangle)
            XCTAssertThrowsError(try AutomationTargetPolicy.validate(observed: target, current: target,
                sameWindow: true, enabled: true, displayFrame: display))
        }
    }

    func testCoordinatesRejectReplacedRenamedMovedAndMissingWindows() throws {
        let original = AutomationGraphicsWindow(id: 1, title: "Draft", frame: windowBounds)
        let second = AutomationGraphicsWindow(id: 2, title: "Other", frame: windowBounds.offsetBy(dx: 100, dy: 0))
        try AutomationTargetPolicy.validateWindows(observed: [original, second], current: [second, original])
        for current in [[], [second],
                        [AutomationGraphicsWindow(id: 3, title: original.title, frame: original.frame), second],
                        [AutomationGraphicsWindow(id: 1, title: "Other document", frame: original.frame), second],
                        [AutomationGraphicsWindow(id: 1, title: original.title, frame: original.frame.offsetBy(dx: 1, dy: 0)), second]] {
            XCTAssertThrowsError(try AutomationTargetPolicy.validateWindows(observed: [original, second], current: current)) { error in
                XCTAssertEqual((error as? AccessibilityActionError)?.code, "stale_target")
            }
        }
        XCTAssertThrowsError(try AutomationTargetPolicy.validateWindows(observed: [], current: []))
    }

    func testCancellationAtFinalPreflightDoesNotDeliverOrReplay() {
        var deliveries = 0
        XCTAssertThrowsError(try AutomationTargetPolicy.deliver(preflight: {
            throw AccessibilityActionError.cancelled
        }, event: { deliveries += 1 }))
        XCTAssertEqual(deliveries, 0)
    }
}
