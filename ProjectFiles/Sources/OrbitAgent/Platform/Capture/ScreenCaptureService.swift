import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenCaptureError: LocalizedError {
    case displayUnavailable
    case couldNotWriteImage
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
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

actor ScreenCaptureService {
    static let maximumVisionWidth = 2048.0
    static let maximumVisionHeight = 1280.0
    static let maximumPreviewWidth = 1440.0
    static let maximumPreviewHeight = 900.0

    private var cachedContent: SCShareableContent?
    private var contentCachedAt: ContinuousClock.Instant?
    private let contentCacheLifetime: Duration = .milliseconds(750)

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
            cachedContent = nil
            contentCachedAt = nil
            return .denied
        }
        guard verifyPixels else {
            return .authorized
        }

        do {
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
        } catch {
            cachedContent = nil
            contentCachedAt = nil
            // macOS commonly updates the Settings switch before the running
            // process receives a usable ScreenCaptureKit authorization. Report
            // the switch as On while requiring an automatic relaunch before a
            // task can start.
            return .restartRequired(error.localizedDescription)
        }
    }

    func isAuthorized() async -> Bool {
        await authorizationStatus(verifyPixels: false) == .authorized
    }

    func capture(display: DisplayDescriptor) async throws -> URL {
        let content: SCShareableContent
        do {
            content = try await shareableContent()
        } catch {
            throw permissionError(for: error)
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw ScreenCaptureError.displayUnavailable
        }

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
        let scale = min(
            1.0,
            Self.maximumVisionWidth / sourceWidth,
            Self.maximumVisionHeight / sourceHeight
        )
        configuration.width = max(1, Int((sourceWidth * scale).rounded()))
        configuration.height = max(1, Int((sourceHeight * scale).rounded()))
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
            cachedContent = nil
            contentCachedAt = nil
            throw permissionError(for: error)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrbitAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("screen-\(UUID().uuidString).png")
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
        return url
    }

    /// Captures a local-only viewer frame. Unlike the OpenClaw frame, this keeps
    /// TaskPilot's click-through cursor overlay so the user can watch exactly where
    /// the agent is pointing without moving their hardware cursor.
    func capturePreview(display: DisplayDescriptor) async throws -> CGImage {
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
        let scale = min(
            1.0,
            Self.maximumPreviewWidth / sourceWidth,
            Self.maximumPreviewHeight / sourceHeight
        )
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((sourceWidth * scale).rounded()))
        configuration.height = max(1, Int((sourceHeight * scale).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            cachedContent = nil
            contentCachedAt = nil
            throw permissionError(for: error)
        }
    }

    private func shareableContent(forceRefresh: Bool = false) async throws -> SCShareableContent {
        let now = ContinuousClock.now
        if !forceRefresh,
           let cachedContent,
           let contentCachedAt,
           now - contentCachedAt < contentCacheLifetime {
            return cachedContent
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        cachedContent = content
        contentCachedAt = now
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
