import XCTest
@testable import OrbitAgent

final class AutomationInputTests: XCTestCase {
    func testDelayedActivationYieldsUntilReady() async throws {
        var observations = 0
        try await AutomationInputPolicy.waitUntilReady(timeout: 0.3, ready: {
            observations += 1
            return observations >= 3
        })
        XCTAssertEqual(observations, 3)
    }

    func testActivationTimeoutDoesNotAuthorizeDelivery() async {
        do {
            try await AutomationInputPolicy.waitUntilReady(timeout: 0.04, ready: { false })
            XCTFail("An inactive app must not receive input")
        } catch let error as AccessibilityActionError {
            XCTAssertEqual(error.code, "activation_failed")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellationStopsAnActivationWait() async {
        var polls = 0
        do {
            try await AutomationInputPolicy.waitUntilReady(ready: { false }, cancelled: {
                polls += 1
                return polls >= 2
            })
            XCTFail("Cancellation must stop delivery")
        } catch let error as AccessibilityActionError {
            XCTAssertEqual(error.code, "cancelled")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testFocusTimeoutIsClassifiedWithoutAuthorizingText() async {
        do {
            try await AutomationInputPolicy.waitUntilReady(timeout: 0.01, ready: { false }, timeoutError: .focusMismatch)
            XCTFail("Unconfirmed focus must not authorize typing")
        } catch { XCTAssertEqual((error as? AccessibilityActionError)?.code, "focus_mismatch") }
    }

    func testRestorationCannotOverrideAnotherActionOrUserFocus() {
        XCTAssertTrue(AutomationInputPolicy.shouldRestore(scheduledGeneration: 1, currentGeneration: 1,
            targetPID: 42, currentPID: 42, previousPID: 77))
        XCTAssertFalse(AutomationInputPolicy.shouldRestore(scheduledGeneration: 1, currentGeneration: 2,
            targetPID: 42, currentPID: 42, previousPID: 77))
        XCTAssertFalse(AutomationInputPolicy.shouldRestore(scheduledGeneration: 1, currentGeneration: 1,
            targetPID: 42, currentPID: 88, previousPID: 77))
    }

    func testGraphicsOnlyWindowsRemainObservable() {
        XCTAssertTrue(AccessibilityController.hasObservableWindow(accessibilityCount: 0, graphicsCount: 1))
        XCTAssertFalse(AccessibilityController.hasObservableWindow(accessibilityCount: 0, graphicsCount: 0))
    }

    func testOldObservationRevisionsAreRejected() throws {
        let controller = AccessibilityController()
        let display = DisplayDescriptor(id: 1, name: "fixture", x: 0, y: 0, width: 10, height: 10, isMain: true)
        let first = controller.snapshot(on: display)
        try controller.validateObservation(first.revision)
        let second = controller.snapshot(on: display)
        XCTAssertNotEqual(first.revision, second.revision)
        XCTAssertThrowsError(try controller.validateObservation(first.revision))
        XCTAssertThrowsError(try controller.validateObservation(nil))
        try controller.validateObservation(second.revision)
    }
}
