import Foundation

/// Locates the Python runtime packaged inside TaskPilot.app.
final class BundledRuntimeLocator {
    var executableURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("AgentRuntime", isDirectory: true)
            .appendingPathComponent("orbit_openclaw_runtime")
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }
}
