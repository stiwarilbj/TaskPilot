import CoreGraphics
import Foundation

enum ScreenCoordinateError: LocalizedError {
    case invalidGeometry, outsideImage, outsideDisplay, captureChanged
    var errorDescription: String? {
        switch self {
        case .invalidGeometry: return "The captured screen coordinate geometry is invalid"
        case .outsideImage: return "The point or crop is outside the captured image"
        case .outsideDisplay: return "The point is outside the assigned display"
        case .captureChanged: return "The display geometry changed during screen capture"
        }
    }
}

/// All image and action coordinates enter Quartz's global, top-left point
/// space here. Image dimensions are actual CGImage pixels, never display points
/// or an assumed Retina scale. Normalized actions always cover the full display.
struct ScreenCoordinateMapping: Equatable {
    static let version = 1
    static let normalizedExtent: CGFloat = 1000
    static let edgeInset: CGFloat = 0.5
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let fullImageSize: CGSize
    let sourceRect: CGRect
    let imageSize: CGSize

    init(displayID: CGDirectDisplayID, displayBounds: CGRect, imageSize: CGSize,
         fullImageSize: CGSize? = nil, sourceRect: CGRect? = nil) throws {
        let full = fullImageSize ?? imageSize
        let source = sourceRect ?? CGRect(origin: .zero, size: full)
        guard Self.valid(displayBounds), Self.validPixels(full), Self.validPixels(imageSize),
              Self.valid(source), Self.contains(source, in: CGRect(origin: .zero, size: full)) else {
            throw ScreenCoordinateError.invalidGeometry
        }
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.fullImageSize = full
        self.sourceRect = source
        self.imageSize = imageSize
    }

    static func displayOnly(_ display: DisplayDescriptor) throws -> Self {
        // This image is a unit square, not a screenshot or an assumed pixel size.
        try Self(displayID: display.id, displayBounds: display.frame, imageSize: CGSize(width: 1, height: 1))
    }

    func validate(display: DisplayDescriptor) throws {
        guard display.id == displayID, display.frame == displayBounds else {
            throw AccessibilityActionError.staleObservation
        }
    }

    func globalPoint(fromNormalized point: CGPoint) throws -> CGPoint {
        guard Self.contains(point, in: CGRect(x: 0, y: 0, width: Self.normalizedExtent, height: Self.normalizedExtent)) else {
            throw ScreenCoordinateError.outsideDisplay
        }
        return CGPoint(x: displayBounds.minX + point.x / Self.normalizedExtent * displayBounds.width,
                       y: displayBounds.minY + point.y / Self.normalizedExtent * displayBounds.height)
    }

    func normalizedPoint(fromGlobal point: CGPoint) throws -> CGPoint {
        guard Self.contains(point, in: displayBounds) else { throw ScreenCoordinateError.outsideDisplay }
        return CGPoint(x: (point.x - displayBounds.minX) / displayBounds.width * Self.normalizedExtent,
                       y: (point.y - displayBounds.minY) / displayBounds.height * Self.normalizedExtent)
    }

    func globalPoint(fromImage point: CGPoint) throws -> CGPoint {
        guard Self.contains(point, in: CGRect(origin: .zero, size: imageSize)) else { throw ScreenCoordinateError.outsideImage }
        return CGPoint(x: displayBounds.minX + (sourceRect.minX + point.x / imageSize.width * sourceRect.width) / fullImageSize.width * displayBounds.width,
                       y: displayBounds.minY + (sourceRect.minY + point.y / imageSize.height * sourceRect.height) / fullImageSize.height * displayBounds.height)
    }

    func imagePoint(fromGlobal point: CGPoint) throws -> CGPoint {
        let normalized = try normalizedPoint(fromGlobal: point)
        let pixel = CGPoint(x: normalized.x / Self.normalizedExtent * fullImageSize.width,
                            y: normalized.y / Self.normalizedExtent * fullImageSize.height)
        guard Self.contains(pixel, in: sourceRect) else { throw ScreenCoordinateError.outsideImage }
        return CGPoint(x: (pixel.x - sourceRect.minX) / sourceRect.width * imageSize.width,
                       y: (pixel.y - sourceRect.minY) / sourceRect.height * imageSize.height)
    }

    /// Compose a crop in the current presented image, including a resized crop.
    /// Cropping does not change the meaning of full-display action coordinates.
    func cropped(to rectangle: CGRect, outputSize: CGSize? = nil) throws -> Self {
        guard Self.valid(rectangle), Self.contains(rectangle, in: CGRect(origin: .zero, size: imageSize)) else {
            throw ScreenCoordinateError.outsideImage
        }
        let source = CGRect(x: sourceRect.minX + rectangle.minX / imageSize.width * sourceRect.width,
                            y: sourceRect.minY + rectangle.minY / imageSize.height * sourceRect.height,
                            width: rectangle.width / imageSize.width * sourceRect.width,
                            height: rectangle.height / imageSize.height * sourceRect.height)
        return try Self(displayID: displayID, displayBounds: displayBounds, imageSize: outputSize ?? rectangle.size,
                        fullImageSize: fullImageSize, sourceRect: source)
    }

    func eventPoint(fromNormalized point: CGPoint) throws -> CGPoint {
        let global = try globalPoint(fromNormalized: point)
        // The inclusive 1000 endpoint describes an image edge. An event at
        // maxX/maxY belongs to the neighboring screen, so keep it just inside.
        return CGPoint(x: global.x >= displayBounds.maxX ? displayBounds.maxX - min(Self.edgeInset, displayBounds.width / 2) : global.x,
                       y: global.y >= displayBounds.maxY ? displayBounds.maxY - min(Self.edgeInset, displayBounds.height / 2) : global.y)
    }

    func eventPoint(fromUnit point: CGPoint) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else { throw ScreenCoordinateError.outsideDisplay }
        return try eventPoint(fromNormalized: CGPoint(x: min(1, max(0, point.x)) * Self.normalizedExtent,
                                                       y: min(1, max(0, point.y)) * Self.normalizedExtent))
    }

    func metadata(revision: String) -> [String: Any] {
        func rect(_ r: CGRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        func size(_ s: CGSize) -> [String: Int] { ["width": Int(s.width), "height": Int(s.height)] }
        return ["version": Self.version, "display_id": displayID, "observation_revision": revision,
                "axes": "quartz_top_left", "normalized_extent": Int(Self.normalizedExtent),
                "edge_inset_points": Self.edgeInset,
                "display_bounds": rect(displayBounds), "full_image_size": size(fullImageSize),
                "source_rect": rect(sourceRect), "image_size": size(imageSize),
                "normalized_to_global": ["x_scale": displayBounds.width / Self.normalizedExtent,
                    "y_scale": displayBounds.height / Self.normalizedExtent,
                    "x_offset": displayBounds.minX, "y_offset": displayBounds.minY],
                "image_to_global": ["x_scale": sourceRect.width / imageSize.width / fullImageSize.width * displayBounds.width,
                    "y_scale": sourceRect.height / imageSize.height / fullImageSize.height * displayBounds.height,
                    "x_offset": displayBounds.minX + sourceRect.minX / fullImageSize.width * displayBounds.width,
                    "y_offset": displayBounds.minY + sourceRect.minY / fullImageSize.height * displayBounds.height]]
    }

    static func fittedImageSize(source: CGSize, maximum: CGSize) throws -> CGSize {
        guard validPixels(source), validPixels(maximum) else { throw ScreenCoordinateError.invalidGeometry }
        let scale = min(1, maximum.width / source.width, maximum.height / source.height)
        return CGSize(width: max(1, (source.width * scale).rounded()), height: max(1, (source.height * scale).rounded()))
    }

    static func appKitPoint(_ point: CGPoint, display: DisplayDescriptor, screenFrame: CGRect) throws -> CGPoint {
        let normalized = try displayOnly(display).normalizedPoint(fromGlobal: point)
        guard valid(screenFrame) else { throw ScreenCoordinateError.invalidGeometry }
        return CGPoint(x: screenFrame.minX + normalized.x / normalizedExtent * screenFrame.width,
                       y: screenFrame.maxY - normalized.y / normalizedExtent * screenFrame.height)
    }

    private static func valid(_ r: CGRect) -> Bool {
        [r.origin.x, r.origin.y, r.width, r.height, r.maxX, r.maxY].allSatisfy { $0.isFinite && abs($0) <= 10_000_000 }
            && r.size.width > 0 && r.size.height > 0 && r.maxX > r.minX && r.maxY > r.minY
    }
    private static func validPixels(_ s: CGSize) -> Bool {
        [s.width, s.height].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 10_000_000 && $0.rounded() == $0 }
    }
    private static func contains(_ p: CGPoint, in r: CGRect) -> Bool {
        p.x.isFinite && p.y.isFinite && p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }
    private static func contains(_ candidate: CGRect, in r: CGRect) -> Bool {
        contains(candidate.origin, in: r) && contains(CGPoint(x: candidate.maxX, y: candidate.maxY), in: r)
    }
}
