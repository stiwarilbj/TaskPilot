import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenCaptureError: LocalizedError {
    case pipelineBusy
    case displayUnavailable
    case couldNotWriteImage
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .pipelineBusy: return "The local capture pipeline has reached its bounded capacity"
        case .displayUnavailable: return "The agent display is not available to ScreenCaptureKit"
        case .couldNotWriteImage: return "The agent-screen image could not be written"
        case .permissionDenied(let detail):
            return detail.isEmpty
                ? "Application, window, and display capture are off for this \(TaskPilotIdentity.displayName) build"
                : detail
        }
    }
}

enum ScreenCaptureAuthorization: Equatable {
    case authorized
    case denied
    case restartRequired(String)
    case unavailable(String)
}

struct CapturedScreen {
    let url: URL
    let frame: CapturedFrame
    var coordinates: ScreenCoordinateMapping { frame.coordinates }
    var image: CGImage { frame.image }
    var frameID: UUID { frame.id }
}

actor ScreenCaptureService {
    static let maximumVisionWidth = 2048.0
    static let maximumVisionHeight = 1280.0
    static let maximumPreviewWidth = 1440.0
    static let maximumPreviewHeight = 900.0

    private let contentCache = PressureSensitiveCache<(content: SCShareableContent, created: ContinuousClock.Instant)>()
    private let contentCacheLifetime: Duration = .milliseconds(750)
    typealias Acquirer = @Sendable (DisplayDescriptor, Bool, Bool) async throws -> CGImage
    private let acquisitionQueue: CaptureAcquisitionQueue
    private let encoder: CapturePNGEncoder
    private let acquirer: Acquirer?

    init(acquisitionQueue: CaptureAcquisitionQueue = CaptureAcquisitionQueue(),
         encoder: CapturePNGEncoder = CapturePNGEncoder(), acquirer: Acquirer? = nil) {
        self.acquisitionQueue = acquisitionQueue; self.encoder = encoder; self.acquirer = acquirer
    }

    /// Reads macOS' existing TCC decision without invoking ScreenCaptureKit.
    ///
    /// `SCShareableContent` and `SCScreenshotManager` are access operations,
    /// not status APIs. Calling either while permission is absent can make
    /// macOS present its native Screen Recording prompt, so startup/readiness
    /// polling must stay on this quiet preflight path.
    nonisolated static func preflightAuthorizationStatus(
        granted: Bool = CGPreflightScreenCaptureAccess()
    ) -> ScreenCaptureAuthorization {
        granted ? .authorized : .denied
    }

    /// Returns the current capture authorization. Pixel verification is used
    /// only after an explicit user action such as Recheck Permissions. Even
    /// then, a real capture is attempted only when preflight already says the
    /// switch is On, so verification can never create an unsolicited prompt.
    func authorizationStatus(verifyPixels: Bool = false) async -> ScreenCaptureAuthorization {
        guard Self.preflightAuthorizationStatus() == .authorized else {
            contentCache.evict()
            return .denied
        }
        guard verifyPixels else {
            return .authorized
        }

        do {
            let reservation = try await acquisitionQueue.acquire(.evidence)
            do {
                let status = try await verifyAuthorizationPixels()
                await acquisitionQueue.acquired(reservation)
                try reservation.check()
                return status
            } catch {
                await acquisitionQueue.acquired(reservation)
                throw error
            }
        } catch is CancellationError { return .unavailable("The capture permission check was cancelled") }
        catch {
            contentCache.evict()
            return .restartRequired(error.localizedDescription)
        }
    }

    private func verifyAuthorizationPixels() async throws -> ScreenCaptureAuthorization {
        let content = try await shareableContent(forceRefresh: true)
        guard let display = content.displays.first else {
            return .unavailable("macOS returned no capturable display")
        }
        let excludedApps = controllerApplications(in: content)
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.showsCursor = false
        configuration.capturesAudio = false
        _ = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return .authorized
    }

    func isAuthorized() async -> Bool {
        await authorizationStatus(verifyPixels: false) == .authorized
    }

    /// Acquisition and compression have separate capacity and execution lanes.
    func acquire(display: DisplayDescriptor, forceRefresh: Bool = false) async throws -> CapturedFrame {
        try await TaskOwnership.checkpoint()
        let queue = acquisitionQueue, owner = TaskOwnership.current
        let reservation = try await LocalOperationBudget.bounded(phase: "capture_queue") {
            try await queue.acquire(.evidence, owner: owner)
        }
        do {
            try reservation.check(); try LocalOperationBudget.check("capture_acquisition")
            let image: CGImage
            if let acquirer { image = try await acquirer(display, forceRefresh, false) }
            else { image = try await acquireTaskImage(display: display, forceRefresh: forceRefresh) }
            try reservation.check()
            let coordinates = try ScreenCoordinateMapping(displayID: display.id, displayBounds: display.frame,
                imageSize: CGSize(width: image.width, height: image.height))
            let frame = CapturedFrame(image: image, coordinates: coordinates, reservation: reservation)
            await acquisitionQueue.acquired(reservation)
            try frame.check(); try LocalOperationBudget.check("capture_acquisition")
            return frame
        } catch {
            await acquisitionQueue.acquired(reservation)
            throw error
        }
    }

    func encode(_ frame: CapturedFrame) async throws -> CapturedScreen {
        let encoder = encoder
        let url = try await LocalOperationBudget.bounded(phase: "capture_encoding") { try await encoder.encode(frame) }
        return CapturedScreen(url: url, frame: frame)
    }

    func capture(display: DisplayDescriptor, forceRefresh: Bool = false) async throws -> CapturedScreen {
        let frame = try await acquire(display: display, forceRefresh: forceRefresh)
        return try await encode(frame)
    }

    private func acquireTaskImage(display: DisplayDescriptor, forceRefresh: Bool) async throws -> CGImage {
        let captureSpan = BackendTelemetry.current.begin(.capture)
        defer { captureSpan.finish(Task.isCancelled ? .cancelled : .failed) }
        guard Self.preflightAuthorizationStatus() == .authorized else {
            throw ScreenCaptureError.permissionDenied("Screen capture is not authorized for this TaskPilot process")
        }
        var content: SCShareableContent
        do {
            content = try await shareableContent(forceRefresh: forceRefresh)
        } catch {
            throw permissionError(for: error)
        }
        if content.displays.first(where: { $0.displayID == display.id })?.frame != display.frame {
            content = try await shareableContent(forceRefresh: true)
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw ScreenCaptureError.displayUnavailable
        }
        guard scDisplay.frame == display.frame else { throw ScreenCoordinateError.captureChanged }

        let excludedApps = controllerApplications(in: content)
        let filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        let sourceWidth = Double(scDisplay.width)
        let sourceHeight = Double(scDisplay.height)
        // Preserve small status-bar numbers and canvas/game text for OpenClaw.
        // The previous 1440×900 ceiling could shrink an 856-point game window
        // to less than 500 pixels on a high-resolution virtual display.
        let fitted = try ScreenCoordinateMapping.fittedImageSize(
            source: CGSize(width: sourceWidth, height: sourceHeight),
            maximum: CGSize(width: Self.maximumVisionWidth, height: Self.maximumVisionHeight))
        configuration.width = Int(fitted.width)
        configuration.height = Int(fitted.height)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            contentCache.evict()
            throw permissionError(for: error)
        }
        try TaskOwnership.check()
        guard CGDisplayBounds(display.id) == display.frame else { throw ScreenCoordinateError.captureChanged }
        captureSpan.record(items: image.width * image.height)
        captureSpan.finish(.succeeded)
        return image
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try BackendTelemetry.current.measure(.pngEncoding, inputBytes: image.bytesPerRow * image.height) { span in
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw ScreenCaptureError.couldNotWriteImage
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ScreenCaptureError.couldNotWriteImage
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            span.record(outputBytes: size, items: image.width * image.height)
        }
    }

    /// Captures a local-only viewer frame. Unlike the OpenClaw frame, this keeps
    /// TaskPilot's click-through cursor overlay so the user can watch exactly where
    /// the agent is pointing without moving their hardware cursor.
    func capturePreview(display: DisplayDescriptor) async throws -> CGImage {
        let reservation = try await acquisitionQueue.acquire(.preview)
        do {
            try reservation.check()
            let image: CGImage
            if let acquirer { image = try await acquirer(display, false, true) }
            else { image = try await acquirePreviewImage(display: display) }
            await acquisitionQueue.acquired(reservation)
            try reservation.check()
            return image
        } catch {
            await acquisitionQueue.acquired(reservation)
            throw error
        }
    }

    private func acquirePreviewImage(display: DisplayDescriptor) async throws -> CGImage {
        let span = BackendTelemetry.current.begin(.previewCapture)
        defer { span.finish(Task.isCancelled ? .cancelled : .failed) }
        let content: SCShareableContent
        do {
            content = try await shareableContent()
        } catch {
            throw permissionError(for: error)
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw ScreenCaptureError.displayUnavailable
        }
        // On the main display, excluding TaskPilot prevents a recursive viewer and
        // keeps the protected controller unavailable to manual remote input.
        // The background display keeps TaskPilot's blue cursor overlay visible.
        let excludedApps = display.isMain ? controllerApplications(in: content) : []
        let filter = SCContentFilter(display: scDisplay,
                                     excludingApplications: excludedApps,
                                     exceptingWindows: [])
        let sourceWidth = Double(scDisplay.width)
        let sourceHeight = Double(scDisplay.height)
        let fitted = try ScreenCoordinateMapping.fittedImageSize(
            source: CGSize(width: sourceWidth, height: sourceHeight),
            maximum: CGSize(width: Self.maximumPreviewWidth, height: Self.maximumPreviewHeight))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(fitted.width)
        configuration.height = Int(fitted.height)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            span.record(items: image.width * image.height)
            span.finish(.succeeded)
            return image
        } catch {
            contentCache.evict()
            throw permissionError(for: error)
        }
    }

    private func shareableContent(forceRefresh: Bool = false) async throws -> SCShareableContent {
        let now = ContinuousClock.now
        let snapshot = contentCache.snapshot()
        if !forceRefresh, let cached = snapshot.value,
           now - cached.created < contentCacheLifetime {
            return cached.content
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        contentCache.store((content, now), epoch: snapshot.epoch)
        return content
    }

    private func permissionError(for error: Error) -> ScreenCaptureError {
        if !CGPreflightScreenCaptureAccess() {
            return .permissionDenied(
                "Application, window, and display capture are off for this exact \(TaskPilotIdentity.displayName) build. Open Setup to request access or open Screen Recording Settings."
            )
        }
        return .permissionDenied(
            "macOS could not capture the selected screen: \(error.localizedDescription)"
        )
    }

    private func controllerApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        let controllerBundleID = Bundle.main.bundleIdentifier
        return content.applications.filter { app in
            guard let controllerBundleID else { return app.processID == getpid() }
            return app.bundleIdentifier == controllerBundleID || app.processID == getpid()
        }
    }
}
