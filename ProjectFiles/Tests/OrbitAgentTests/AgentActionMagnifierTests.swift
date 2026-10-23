import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OrbitAgent

final class AgentActionMagnifierTests: XCTestCase {
    private let displayFrame = CGRect(x: -2560, y: -500, width: 256, height: 160)
    private var mapping: ScreenCoordinateMapping {
        get throws {
            try ScreenCoordinateMapping(displayID: 7, displayBounds: displayFrame,
                imageSize: CGSize(width: 512, height: 320))
        }
    }

    private func request(actionID: String, generationID: String, map: ScreenCoordinateMapping,
                         sequence: UInt64 = 1,
                         breadcrumb: String = "Save → Export dialog → Preview") -> AgentActionMagnifierRequest {
        AgentActionMagnifierRequest(actionID: actionID, generationID: generationID, sequence: sequence,
            observationRevision: "accepted-revision", displayID: map.displayID,
            displayFrame: map.displayBounds, mapping: map, actionTitle: "Clicked", breadcrumb: breadcrumb,
            pointer: CGPoint(x: -2432, y: -420), target: CGRect(x: -2442, y: -425, width: 20, height: 10),
            reader: nil)
    }

    private func makePNG(at url: URL) throws {
        let context = CGContext(data: nil, width: 512, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 320))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testAcceptedRetinaFrameCanBeCroppedAfterItsPathIsUnlinked() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("magnifier-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try makePNG(at: url)
        let map = try mapping
        let source = try AgentMagnifierImageSource(url: url, mapping: map, protectedTargets: [])
        try FileManager.default.removeItem(at: url)

        let crop = try XCTUnwrap(source.makeReader()?.crop(
            target: CGRect(x: -2442, y: -425, width: 20, height: 10),
            pointer: CGPoint(x: -2432, y: -420)))
        XCTAssertEqual(crop.image.width, 240)
        XCTAssertEqual(crop.image.height, 140)
        XCTAssertEqual(crop.pointer.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(crop.pointer.y, 0.5, accuracy: 0.01)
        XCTAssertNotNil(crop.target)
        XCTAssertEqual(crop.target?.width ?? 0, 40.0 / 240.0, accuracy: 0.01)
    }

    func testCropIsSuppressedWhenItWouldIncludeAProtectedField() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("magnifier-secure-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try makePNG(at: url)
        let source = try AgentMagnifierImageSource(url: url, mapping: mapping,
            protectedTargets: [CGRect(x: -2440, y: -424, width: 16, height: 8)])
        XCTAssertNil(source.makeReader()?.crop(target: nil, pointer: CGPoint(x: -2432, y: -420)))
    }

    func testResizedCroppedObservationUsesItsComposedImageMapping() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("magnifier-cropped-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try makePNG(at: url)
        let cropped = try mapping.cropped(to: CGRect(x: 128, y: 80, width: 256, height: 160),
                                          outputSize: CGSize(width: 512, height: 320))
        let source = try AgentMagnifierImageSource(url: url, mapping: cropped, protectedTargets: [])
        let crop = try XCTUnwrap(source.makeReader()?.crop(target: nil, pointer: CGPoint(x: -2432, y: -420)))
        XCTAssertEqual(crop.image.width, 480)
        XCTAssertEqual(crop.image.height, 280)
        XCTAssertEqual(crop.pointer.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(crop.pointer.y, 0.5, accuracy: 0.01)
    }

    func testPlacementFlipsAtEdgesAndAvoidsViewerBadges() {
        let letterboxed = AgentScreenCursorMapper.fittedContentRect(
            displaySize: CGSize(width: 256, height: 160), viewportSize: CGSize(width: 620, height: 600))
        XCTAssertGreaterThan(letterboxed.minY, 0)
        let center = AgentScreenCursorMapper.point(normalizedPoint: CGPoint(x: 0.5, y: 0.5), in: letterboxed)
        XCTAssertEqual(center.x, 310, accuracy: 0.01)
        XCTAssertEqual(center.y, 300, accuracy: 0.01)
        let bounds = CGRect(x: 0, y: 0, width: 620, height: 500)
        let reserved = [CGRect(x: 0, y: 0, width: 280, height: 52),
                        CGRect(x: 0, y: 452, width: 620, height: 48)]
        let frame = AgentActionMagnifierLayout.frame(cursor: CGPoint(x: 610, y: 490),
            size: CGSize(width: 240, height: 236), bounds: bounds, reserved: reserved)
        XCTAssertTrue(bounds.contains(frame))
        XCTAssertTrue(reserved.allSatisfy { !frame.intersects($0) })
        let smallScale = AgentActionMagnifierLayout.scale(in: CGSize(width: 180, height: 150))
        XCTAssertGreaterThan(smallScale, 0)
        XCTAssertLessThan(smallScale, 1)
    }

    func testCaptionUsesObservedStructureAndSafeCoordinateOnlyFallback() {
        XCTAssertEqual(AgentActionMagnifierCaption.breadcrumb(target: "Save", containers: ["Export dialog"],
            application: "Preview"), "Save → Export dialog → Preview")
        XCTAssertEqual(AgentActionMagnifierCaption.breadcrumb(target: " ", containers: [],
            application: "Preview"), "Screen location → Preview")
        XCTAssertEqual(AgentActionMagnifierCaption.actionTitle(for: "press"), "Pressed")
        XCTAssertEqual(AgentActionMagnifierCaption.actionTitle(for: "click"), "Clicked")
        XCTAssertEqual(AgentActionMagnifierCaption.actionTitle(for: "double_click"), "Double-clicked")
        XCTAssertEqual(AgentActionMagnifierCaption.actionTitle(for: "scroll"), "Scrolled")
        XCTAssertNil(AgentActionMagnifierCaption.actionTitle(for: "type_text"))
        XCTAssertEqual(AgentActionMagnifierState.uncertain.title, "Delivery uncertain")
        XCTAssertEqual(AgentActionMagnifierState.rejected.title, "Not delivered")
        XCTAssertEqual(AgentActionMagnifierState.confirmed("dialog_appeared").title,
            "Result confirmed: dialog appeared")
    }

    @MainActor
    func testPinFreezesSnapshotAndFollowLatestAdoptsNewestConfirmation() throws {
        let model = AgentActionMagnifierModel()
        let generation = UUID().uuidString.lowercased()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        let map = try mapping
        model.beginTask(generation)
        model.show(request(actionID: first, generationID: generation, map: map))
        model.update(actionID: first, generationID: generation, state: .delivered("Clicked"))
        model.pin()

        model.update(actionID: first, generationID: generation, state: .confirmed("dialog_appeared"))
        XCTAssertEqual(model.presentation?.state, .delivered("Clicked"))
        model.show(request(actionID: second, generationID: generation, map: map, sequence: 2, breadcrumb: "Open → App"))
        XCTAssertEqual(model.presentation?.request.actionID, first)
        XCTAssertTrue(model.presentation?.hasNewerAction == true)
        model.update(actionID: second, generationID: generation, state: .confirmed("field_value"))
        model.followLatest()
        XCTAssertEqual(model.presentation?.request.actionID, second)
        XCTAssertEqual(model.presentation?.state, .confirmed("field_value"))
        XCTAssertFalse(model.isPinned)

        model.expire(actionID: first, generationID: generation)
        XCTAssertEqual(model.presentation?.request.actionID, second)
        model.expire(actionID: second, generationID: "stale-generation")
        XCTAssertEqual(model.presentation?.request.actionID, second)
        model.expire(actionID: second, generationID: generation)
        XCTAssertNil(model.presentation)
    }

    @MainActor
    func testOutOfOrderTargetAndDeliveryEventsCannotReplaceANewerAction() throws {
        let model = AgentActionMagnifierModel()
        let generation = UUID().uuidString.lowercased()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        let map = try mapping
        model.beginTask(generation)
        model.show(request(actionID: second, generationID: generation, map: map, sequence: 2))
        model.show(request(actionID: first, generationID: generation, map: map, sequence: 1))
        model.update(actionID: first, generationID: generation, sequence: 1, state: .delivered("Clicked"))
        XCTAssertEqual(model.presentation?.request.actionID, second)
        XCTAssertEqual(model.presentation?.state, .targeting)
    }

    @MainActor
    func testTextOnlyExplanationRemainsAvailableWhenAcceptedPixelsCannotBeRead() throws {
        let model = AgentActionMagnifierModel()
        let generation = UUID().uuidString.lowercased()
        let action = UUID().uuidString.lowercased()
        model.beginTask(generation)
        model.show(request(actionID: action, generationID: generation, map: try mapping, breadcrumb: "Screen location → Preview"))
        model.update(actionID: action, generationID: generation, state: .delivered("Clicked"))

        XCTAssertNil(model.presentation?.crop)
        XCTAssertEqual(model.presentation?.request.breadcrumb, "Screen location → Preview")
        XCTAssertEqual(model.presentation?.state, .delivered("Clicked"))
    }

    func testPrivateConfirmationEventsRequireKnownActionGenerationAndSupportedScope() {
        let generation = UUID().uuidString.lowercased()
        let action = UUID().uuidString.lowercased()
        func message(_ overrides: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["kind": "action_presentation", "task_generation_id": generation,
                "action_id": action, "state": "confirmed", "verification_scope": "dialog_appeared"]
            value.merge(overrides) { _, new in new }
            return value
        }
        XCTAssertEqual(AgentActionPresentationMessage.parse(message(), generationID: generation,
            knownActionIDs: [action]), AgentActionPresentationMessage(actionID: action,
                generationID: generation, verificationScope: "dialog_appeared"))
        XCTAssertNil(AgentActionPresentationMessage.parse(message(), generationID: "other",
            knownActionIDs: [action]))
        XCTAssertNil(AgentActionPresentationMessage.parse(message(), generationID: generation,
            knownActionIDs: []))
        XCTAssertNil(AgentActionPresentationMessage.parse(message(["verification_scope": "screen_changed"]),
            generationID: generation, knownActionIDs: [action]))
        XCTAssertNil(AgentActionPresentationMessage.parse(message(["state": "delivered"]),
            generationID: generation, knownActionIDs: [action]))
        XCTAssertNil(AgentActionPresentationMessage.parse(message(["private_text": "secret"]),
            generationID: generation, knownActionIDs: [action]))
    }
}
