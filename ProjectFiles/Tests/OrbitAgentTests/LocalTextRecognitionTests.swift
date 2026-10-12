import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import OrbitAgent

final class LocalTextRecognitionTests: XCTestCase {
    private func image(width: Int = 1000, height: Int = 600, text: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if text {
            let string = NSAttributedString(string: "SAVE REPORT", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 32, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 30, y: 45)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        return try XCTUnwrap(context.makeImage())
    }
    private func snapshot(elements: [[String: Any]] = [], available: Bool = false, partial: Bool = true) -> AccessibilitySnapshot {
        AccessibilitySnapshot(revision: "staged", elements: elements,
            applications: [["pid": 42, "accessibility_available": available]], installedApplications: [], systemContext: [:],
            completeness: ["state": partial ? "partial" : "complete", "limitations": partial ? [["pid": 42]] : []])
    }
    private func scene(_ windows: [ScreenTextWindow] = [.init(pid: 42, id: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 600))]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["windows": windows.map { w in
            ["pid": w.pid, "window": w.id, "layer": w.layer, "frame": [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height]] as [String: Any]
        }]), as: UTF8.self)
    }
    private func mapping() throws -> ScreenCoordinateMapping {
        try ScreenCoordinateMapping(displayID: 1, displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 600), imageSize: CGSize(width: 1000, height: 600))
    }
    private func match(text: String = "Save", confidence: Double = 0.99, x: Double = 100) -> ScreenTextMatch {
        ScreenTextMatch(text: text, confidence: confidence, frame: CGRect(x: x, y: 100, width: 70, height: 20))
    }

    func testVisionBottomLeftBoxesUseCentralMappingWithRetinaNegativeOriginsAndCrops() throws {
        let base = try ScreenCoordinateMapping(displayID: 1, displayBounds: CGRect(x: -1000, y: -400, width: 1000, height: 600), imageSize: CGSize(width: 2000, height: 1200))
        let full = try LocalTextRecognition.globalFrame(CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.1), coordinates: base)
        XCTAssertEqual(full.minX, -800, accuracy: 0.001); XCTAssertEqual(full.minY, -160, accuracy: 0.001)
        XCTAssertEqual(full.width, 100, accuracy: 0.001); XCTAssertEqual(full.height, 60, accuracy: 0.001)
        let crop = try base.cropped(to: CGRect(x: 400, y: 480, width: 200, height: 120), outputSize: CGSize(width: 400, height: 240))
        XCTAssertEqual(try LocalTextRecognition.globalFrame(CGRect(x: 0, y: 0, width: 1, height: 1), coordinates: crop), full)
        for invalid in [CGRect(x: -1, y: 0, width: 1, height: 1), .zero,
                        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)] {
            XCTAssertThrowsError(try LocalTextRecognition.globalFrame(invalid, coordinates: base))
        }
    }

    func testHealthyNativeControlsAddNoRecognitionWorkOrCrops() async throws {
        let native = snapshot(elements: [["pid": 42, "id": "ax:save", "role": "AXButton", "actions": ["AXPress"]]], available: true, partial: false)
        var calls = 0
        let result = try await LocalTextRecognition.supplement(image: image(), coordinates: mapping(), snapshot: native,
            scene: scene(), keywords: [], budget: 1, recognize: { _, _, _ in calls += 1; return [] })
        XCTAssertEqual(calls, 0); XCTAssertEqual(result.state, "not_needed")
        XCTAssertTrue(result.targets.isEmpty); XCTAssertTrue(result.crops.isEmpty)
    }

    func testWindowRaiseAndMenuBarActionsDoNotHideAPoorlyExposedCanvas() {
        let rows: [[String: Any]] = [["pid": 42, "role": "AXWindow", "actions": ["AXRaise"]],
                                    ["pid": 42, "role": "AXMenuBarItem", "actions": ["AXPress"]]]
        XCTAssertEqual(LocalTextRecognition.neededPIDs(snapshot(elements: rows, available: true, partial: false)), [42])
    }

    func testGraphicsOnlyWindowsSupplyProvisionalTargetsAndSameImageCrops() async throws {
        var calls = 0
        let result = try await LocalTextRecognition.supplement(image: image(), coordinates: mapping(), snapshot: snapshot(),
            scene: scene(), keywords: ["save"], budget: 1, recognize: { _, _, _ in calls += 1; return [self.match()] })
        XCTAssertEqual(calls, 1); XCTAssertEqual(result.state, "recognized")
        XCTAssertEqual(result.targets.count, 1); XCTAssertEqual(result.crops.count, 1)
        let metadata = try result.metadata(revision: "accepted", coordinates: mapping())
        let row = try XCTUnwrap((metadata["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["candidate_id"] as? String, "accepted:text:0")
        XCTAssertNil(row["element_id"]); XCTAssertNil(row["role"])
        XCTAssertEqual(row["provisional"] as? Bool, true)
        XCTAssertEqual(row["pid"] as? Int, 42); XCTAssertEqual(row["graphics_window_id"] as? Int, 7)
        XCTAssertNotNil(Data(base64Encoded: try XCTUnwrap(result.crops[0]["data"] as? String)))
    }

    func testSecureAppsAndOverlappingSecureWindowsAreNeverRecognizedOrCropped() async throws {
        let secure = ["pid": 42, "role": "AXSecureTextField", "value": "[secure]"] as [String: Any]
        XCTAssertTrue(LocalTextRecognition.neededPIDs(snapshot(elements: [secure])).isEmpty)
        var calls = 0
        let result = try await LocalTextRecognition.supplement(image: image(), coordinates: mapping(),
            snapshot: snapshot(elements: [["pid": 43, "role": "AXTextField", "value": "[secure]"]]),
            scene: scene([.init(pid: 43, id: 8, frame: CGRect(x: 10, y: 10, width: 500, height: 200)),
                          .init(pid: 42, id: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 600))]),
            keywords: [], budget: 1, recognize: { _, _, _ in calls += 1; return [self.match()] })
        XCTAssertEqual(calls, 0); XCTAssertTrue(result.targets.isEmpty); XCTAssertTrue(result.crops.isEmpty)
    }

    func testOccludedLabelsAndAlreadyExposedControlsAreNotNewTextTargets() async throws {
        let native = snapshot(elements: [["pid": 42, "actions": ["AXPress"], "frame": ["x": 200, "y": 90, "width": 100, "height": 50]]])
        let result = try await LocalTextRecognition.supplement(image: image(), coordinates: mapping(), snapshot: native,
            scene: scene([.init(pid: 43, id: 8, frame: CGRect(x: 90, y: 90, width: 100, height: 40)),
                          .init(pid: 42, id: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 600))]),
            keywords: [], budget: 1, recognize: { _, _, _ in [self.match(), self.match(x: 210), self.match(x: 400)] })
        XCTAssertEqual(result.targets.count, 1); XCTAssertEqual(result.targets[0].match.frame.minX, 400)
    }

    func testRecognizedTargetsAreBoundedRankedAndRepeatedLabelsRemainExplicit() async throws {
        let matches = (0..<60).map { i in ScreenTextMatch(text: i == 59 ? "Export" : "Save", confidence: 0.99,
            frame: CGRect(x: 100 + i % 10 * 80, y: 50 + i / 10 * 40, width: 60, height: 20)) }
        let result = try await LocalTextRecognition.supplement(image: image(), coordinates: mapping(), snapshot: snapshot(),
            scene: scene(), keywords: ["export"], budget: 1, recognize: { _, _, _ in matches })
        XCTAssertEqual(result.targets.count, 48); XCTAssertEqual(result.crops.count, 2); XCTAssertEqual(result.state, "partial")
        XCTAssertEqual(result.targets[0].match.text, "Export")
        let rows = try XCTUnwrap(try result.metadata(revision: "r", coordinates: mapping())["targets"] as? [[String: Any]])
        XCTAssertEqual(rows[1]["repeated_text_count"] as? Int, 47)
    }

    func testTransientWindowsOccludePrimaryLabelsEvenForTheSameApp() async throws {
        let result = try await LocalTextRecognition.supplement(image: image(), coordinates: mapping(), snapshot: snapshot(),
            scene: scene([.init(pid: 42, id: 8, frame: CGRect(x: 90, y: 90, width: 100, height: 40), layer: 3),
                          .init(pid: 42, id: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 600))]),
            keywords: [], budget: 1, recognize: { _, _, _ in [self.match(), self.match(x: 400)] })
        XCTAssertEqual(result.targets.count, 1); XCTAssertEqual(result.targets[0].match.frame.minX, 400)
        XCTAssertEqual(result.targets[0].window.id, 7)
    }

    func testConfidenceAndAmbiguityNeverAuthorizeExecution() throws {
        let window = ScreenTextWindow(pid: 42, id: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        var snapshot = ScreenTextSnapshot(targets: [.init(match: match(confidence: 0.7), window: window)])
        XCTAssertThrowsError(try snapshot.target(at: CGPoint(x: 120, y: 110), pid: 42))
        snapshot.targets = [.init(match: match(), window: window), .init(match: match(text: "Other"), window: window)]
        XCTAssertThrowsError(try snapshot.target(at: CGPoint(x: 120, y: 110), pid: 42))
        XCTAssertNil(try snapshot.target(at: CGPoint(x: 120, y: 110), pid: 43))
    }

    func testFreshTextMustMatchLabelPositionSizeAndSingleCandidateBeforeDelivery() throws {
        let target = ScreenTextTarget(match: match(), window: .init(pid: 42, id: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 600)))
        let point = CGPoint(x: 120, y: 110)
        try LocalTextRecognition.validate(target, matches: [match()], point: point)
        var delivered = 0
        for matches in [[], [match(text: "Delete")], [match(x: 110)], [match(confidence: 0.6)], [match(), match(text: "Other")]] {
            XCTAssertThrowsError(try AutomationTargetPolicy.deliver(preflight: {
                try LocalTextRecognition.validate(target, matches: matches, point: point)
            }, event: { delivered += 1 }))
        }
        XCTAssertEqual(delivered, 0)
    }

    func testBudgetAndRecognitionFailureRemainPartialWithoutAnotherModelOrAction() async throws {
        var calls = 0
        let result = try await LocalTextRecognition.supplement(image: image(), coordinates: mapping(), snapshot: snapshot(),
            scene: scene(), keywords: [], budget: 0, recognize: { _, _, _ in calls += 1; return [] })
        XCTAssertEqual(calls, 0); XCTAssertEqual(result.state, "partial")
        let failed = try await LocalTextRecognition.supplement(image: image(), coordinates: mapping(), snapshot: snapshot(),
            scene: scene(), keywords: [], budget: 1, recognize: { _, _, _ in throw ScreenCoordinateError.outsideImage })
        XCTAssertEqual(failed.state, "partial"); XCTAssertTrue(failed.targets.isEmpty)
    }

    func testRevokedRecognitionCannotPublishAndLeaseRetirementDiscardsText() async throws {
        let lease = TaskLease()
        try lease.bindScreenText(ScreenTextSnapshot(state: "partial"), revision: "r")
        XCTAssertNotNil(try lease.screenTextSnapshot(revision: "r"))
        XCTAssertNil(try lease.screenTextSnapshot(revision: "old"))
        lease.pause(); lease.resume()
        XCTAssertThrowsError(try lease.screenTextSnapshot(revision: "r"))
        try lease.bindScreenText(ScreenTextSnapshot(state: "partial"), revision: "fresh")
        do {
            _ = try await TaskOwnership.$current.withValue(lease) {
                try await LocalTextRecognition.supplement(image: image(), coordinates: mapping(), snapshot: snapshot(),
                    scene: scene(), keywords: [], budget: 1, recognize: { _, _, _ in lease.revoke(); return [self.match()] })
            }
            XCTFail("Revoked recognition must not publish")
        } catch { XCTAssertTrue(error is CancellationError) }
        lease.retire()
        XCTAssertThrowsError(try lease.screenTextSnapshot(revision: "fresh"))
    }

    func testActualVisionRecognizesAnOffscreenSyntheticImageWithoutDesktopAccess() async throws {
        let image = try image(width: 400, height: 120, text: true)
        let map = try ScreenCoordinateMapping(displayID: 1, displayBounds: CGRect(x: -200, y: 50, width: 200, height: 60),
            imageSize: CGSize(width: 400, height: 120))
        let matches = try await LocalTextRecognition.recognize(image, map, 10)
        let text = try XCTUnwrap(matches.first { $0.text == "SAVE" })
        let second = try XCTUnwrap(matches.first { $0.text == "REPORT" })
        XCTAssertEqual(text.lineText, "SAVE REPORT")
        XCTAssertLessThan(text.frame.maxX, second.frame.minX)
        XCTAssertGreaterThanOrEqual(text.confidence, 0.8)
        XCTAssertTrue(map.displayBounds.contains(text.frame))
        XCTAssertGreaterThan(text.frame.minX, -200); XCTAssertGreaterThan(text.frame.minY, 50)
    }
}
