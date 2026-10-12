import XCTest
import CoreGraphics
@testable import OrbitAgent

final class ScreenCoordinateMappingTests: XCTestCase {
    private let bounds = CGRect(x: -2560, y: -500, width: 2560, height: 1600)
    private func point(_ values: [Double]) -> CGPoint { CGPoint(x: values[0], y: values[1]) }
    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, file: file, line: line)
    }

    func testSharedNativePythonGeometryAndAuthoritativeMetadata() throws {
        let fields = ActionContract.definition["fields"] as! [String: [String: Any]]
        for axis in ["x", "y"] {
            XCTAssertEqual((fields[axis]?["min"] as? NSNumber)?.doubleValue, 0)
            XCTAssertEqual((fields[axis]?["max"] as? NSNumber)?.doubleValue,
                           Double(ScreenCoordinateMapping.normalizedExtent))
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/screen-coordinate-cases.json")
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        XCTAssertEqual(corpus["version"] as? Int, ScreenCoordinateMapping.version)
        for fixture in corpus["cases"] as! [[String: Any]] {
            let d = fixture["display"] as! [String: Double]
            let metadata = fixture["coordinate_mapping"] as! [String: Any]
            let full = metadata["full_image_size"] as! [String: Double]
            let image = metadata["image_size"] as! [String: Double]
            let crop = metadata["source_rect"] as! [String: Double]
            let mapping = try ScreenCoordinateMapping(displayID: UInt32(d["id"]!),
                displayBounds: CGRect(x: d["x"]!, y: d["y"]!, width: d["width"]!, height: d["height"]!),
                imageSize: CGSize(width: image["width"]!, height: image["height"]!),
                fullImageSize: CGSize(width: full["width"]!, height: full["height"]!),
                sourceRect: CGRect(x: crop["x"]!, y: crop["y"]!, width: crop["width"]!, height: crop["height"]!))
            let normalized = point(fixture["normalized"] as! [Double])
            let pixel = point(fixture["pixel"] as! [Double])
            let global = point(fixture["global"] as! [Double])
            assertPoint(try mapping.globalPoint(fromNormalized: normalized), global)
            assertPoint(try mapping.globalPoint(fromImage: pixel), global)
            assertPoint(try mapping.normalizedPoint(fromGlobal: global), normalized)
            assertPoint(try mapping.imagePoint(fromGlobal: global), pixel)
            assertPoint(try mapping.eventPoint(fromNormalized: normalized), global)
            XCTAssertEqual(mapping.metadata(revision: "fixture:accepted") as NSDictionary, metadata as NSDictionary,
                           fixture["name"] as! String)
        }
    }

    func testNestedResizedCropsComposeWithoutChangingActionSpace() throws {
        let original = try ScreenCoordinateMapping(displayID: 2, displayBounds: bounds,
            imageSize: CGSize(width: 2048, height: 1280))
        let crop = try original.cropped(to: CGRect(x: 512, y: 320, width: 1024, height: 640),
            outputSize: CGSize(width: 512, height: 320))
        let nested = try crop.cropped(to: CGRect(x: 128, y: 80, width: 256, height: 160),
            outputSize: CGSize(width: 1024, height: 640))
        let expected = CGPoint(x: -1600, y: 100)
        assertPoint(try nested.globalPoint(fromImage: .zero), expected)
        assertPoint(try nested.globalPoint(fromImage: CGPoint(x: 512, y: 320)), CGPoint(x: -1280, y: 300))
        assertPoint(try nested.globalPoint(fromNormalized: CGPoint(x: 375, y: 375)), expected)
        XCTAssertThrowsError(try nested.imagePoint(fromGlobal: CGPoint(x: bounds.minX, y: bounds.minY)))
        for invalid in [CGRect(x: -1, y: 0, width: 10, height: 10), CGRect(x: 2040, y: 0, width: 10, height: 10), .zero] {
            XCTAssertThrowsError(try original.cropped(to: invalid))
        }
    }

    func testInclusiveActionEdgesDeliverInsideAssignedDisplay() throws {
        for rectangle in [CGRect(x: 0, y: 0, width: 1440, height: 900), bounds,
                          CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
                          CGRect(x: 0, y: 0, width: 0.25, height: 0.25)] {
            let mapping = try ScreenCoordinateMapping(displayID: 1, displayBounds: rectangle,
                imageSize: CGSize(width: 100, height: 100))
            let outer = try mapping.globalPoint(fromNormalized: CGPoint(x: 1000, y: 1000))
            XCTAssertEqual(outer, CGPoint(x: rectangle.maxX, y: rectangle.maxY))
            let event = try mapping.eventPoint(fromNormalized: CGPoint(x: 1000, y: 1000))
            XCTAssertTrue(rectangle.contains(event))
            XCTAssertLessThan(event.x, rectangle.maxX)
            XCTAssertLessThan(event.y, rectangle.maxY)
            assertPoint(try mapping.eventPoint(fromUnit: CGPoint(x: 1, y: 1)), event)
            assertPoint(try mapping.eventPoint(fromNormalized: .zero), rectangle.origin)
        }
    }

    func testInvalidGeometryAndOutOfRangeInputsNeverProduceDeliveryPoints() throws {
        for frame in [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 1),
                      CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)] {
            XCTAssertThrowsError(try ScreenCoordinateMapping(displayID: 1, displayBounds: frame, imageSize: CGSize(width: 10, height: 10)))
        }
        for size in [CGSize.zero, CGSize(width: 1.5, height: 10), CGSize(width: CGFloat.infinity, height: 10)] {
            XCTAssertThrowsError(try ScreenCoordinateMapping(displayID: 1, displayBounds: bounds, imageSize: size))
        }
        let mapping = try ScreenCoordinateMapping(displayID: 1, displayBounds: bounds, imageSize: CGSize(width: 100, height: 100))
        for point in [CGPoint(x: -0.01, y: 5), CGPoint(x: 1000.01, y: 5), CGPoint(x: CGFloat.nan, y: 5)] {
            XCTAssertThrowsError(try mapping.eventPoint(fromNormalized: point))
        }
        XCTAssertThrowsError(try mapping.globalPoint(fromImage: CGPoint(x: 101, y: 5)))
        XCTAssertThrowsError(try mapping.eventPoint(fromUnit: CGPoint(x: CGFloat.infinity, y: 0)))
    }

    func testDisplayChangesRejectBeforeAnyEvent() throws {
        let mapping = try ScreenCoordinateMapping(displayID: 2, displayBounds: bounds, imageSize: CGSize(width: 2048, height: 1280))
        var deliveries = 0
        for descriptor in [
            DisplayDescriptor(id: 3, name: "Fixture", x: -2560, y: -500, width: 2560, height: 1600, isMain: false),
            DisplayDescriptor(id: 2, name: "Fixture", x: -2561, y: -500, width: 2560, height: 1600, isMain: false),
            DisplayDescriptor(id: 2, name: "Fixture", x: -2560, y: -500, width: 1920, height: 1080, isMain: false)
        ] {
            XCTAssertThrowsError(try AutomationTargetPolicy.deliver(preflight: { try mapping.validate(display: descriptor) },
                event: { deliveries += 1 })) { error in
                XCTAssertEqual((error as? AccessibilityActionError)?.code, "stale_target")
            }
        }
        XCTAssertEqual(deliveries, 0)
    }

    func testCaptureSizingAndAppKitAxisConversionUseSameGeometry() throws {
        XCTAssertEqual(try ScreenCoordinateMapping.fittedImageSize(source: CGSize(width: 3840, height: 2160),
            maximum: CGSize(width: 2048, height: 1280)), CGSize(width: 2048, height: 1152))
        XCTAssertEqual(try ScreenCoordinateMapping.fittedImageSize(source: CGSize(width: 800, height: 600),
            maximum: CGSize(width: 2048, height: 1280)), CGSize(width: 800, height: 600))
        XCTAssertThrowsError(try ScreenCoordinateMapping.fittedImageSize(source: .zero, maximum: CGSize(width: 10, height: 10)))
        let display = DisplayDescriptor(id: 1, name: "Fixture", x: -1920, y: -1080, width: 1920, height: 1080, isMain: false)
        assertPoint(try ScreenCoordinateMapping.appKitPoint(CGPoint(x: -1440, y: -270), display: display,
            screenFrame: CGRect(x: -1920, y: 900, width: 1920, height: 1080)), CGPoint(x: -1440, y: 1170))
    }
}
