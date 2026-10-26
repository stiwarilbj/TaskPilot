import ApplicationServices
import XCTest
@testable import OrbitAgent

final class ObservationAccessibilityReadsTests: XCTestCase {
    func testRepeatedSlowReadsShortCircuitAndReportDeferredSubtree() {
        var time: Double = 0
        var nativeCalls = 0
        var deferredReports = 0
        let identity = AutomationApplicationIdentity(pid: 424242, bundleID: "fixture", bundlePath: "/fixture",
            name: "Fixture", launchDate: Date(timeIntervalSince1970: 1))
        let graph = NativeAccessibilityGraph<Int>(stallThreshold: 2, stallWindow: 5, stallCooldown: 2,
            processIdentity: identity, now: { time }, hash: { UInt($0) }, equal: ==)
        let element = AXUIElementCreateApplication(pid_t(identity.pid))
        let context = ObservationAccessibilityReads.Context(deadline: 5, now: { time },
            report: { _, _, _ in }, retried: {}, shouldRetry: { false },
            shouldDefer: { _ in graph.shouldDefer(9, processIdentity: identity) },
            stalled: { _ in graph.recordTimeout(9, processIdentity: identity) },
            deferred: { _, attribute in
                XCTAssertEqual(attribute, "AXTitle")
                deferredReports += 1
            }, setTimeout: { _, _ in })

        for _ in 0..<2 {
            let result = context.read(element, attribute: "AXTitle") {
                nativeCalls += 1
                time += 0.1
                return AXError.cannotComplete
            }
            XCTAssertEqual(result, AXError.cannotComplete)
        }
        XCTAssertEqual(deferredReports, 1)
        XCTAssertTrue(graph.shouldDefer(9, processIdentity: identity))

        let skipped = context.read(element, attribute: "AXTitle") {
            nativeCalls += 1
            return AXError.success
        }
        XCTAssertEqual(skipped, AXError.cannotComplete)
        XCTAssertEqual(nativeCalls, 2)
        XCTAssertEqual(deferredReports, 1)
    }
}
