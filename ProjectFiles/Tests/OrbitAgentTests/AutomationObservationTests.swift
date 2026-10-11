import XCTest
@testable import OrbitAgent

final class AutomationObservationTests: XCTestCase {
    func testFocusedWindowPrecedesOtherWindowsWithinCaptureBudget() {
        XCTAssertEqual(AutomationObservationPolicy.windowOrder(count: 4, focusedIndex: 3, topmostIndex: 1), [3, 1, 0, 2])
        XCTAssertEqual(AutomationObservationPolicy.windowOrder(count: 3, focusedIndex: 2, topmostIndex: 2), [2, 0, 1])
    }

    func testDisplayTopmostWindowWinsWhenFocusedWindowIsElsewhereOrUnavailable() {
        XCTAssertEqual(AutomationObservationPolicy.windowOrder(count: 3, focusedIndex: nil, topmostIndex: 2), [2, 0, 1])
        XCTAssertEqual(AutomationObservationPolicy.windowOrder(count: 3, focusedIndex: 8, topmostIndex: 1), [1, 0, 2])
        XCTAssertEqual(AutomationObservationPolicy.windowOrder(count: 0, focusedIndex: 0, topmostIndex: nil), [])
    }

    func testWindowMatchUsesBoundsWithoutGuessingFromDuplicateTitles() {
        let frames = [CGRect(x: 0, y: 0, width: 500, height: 400), CGRect(x: 550, y: 0, width: 500, height: 400)]
        XCTAssertEqual(AutomationObservationPolicy.matchingWindowIndex(frames: frames, topmostFrame: frames[1]), 1)
        XCTAssertEqual(AutomationObservationPolicy.matchingWindowIndex(frames: frames, topmostFrame: CGRect(x: 551, y: 0, width: 499, height: 400)), 1)
        XCTAssertNil(AutomationObservationPolicy.matchingWindowIndex(frames: frames, topmostFrame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        XCTAssertNil(AutomationObservationPolicy.matchingWindowIndex(frames: frames, topmostFrame: nil))
        XCTAssertNil(AutomationObservationPolicy.matchingWindowIndex(frames: [frames[0], frames[0]], topmostFrame: frames[0]))
    }
}
