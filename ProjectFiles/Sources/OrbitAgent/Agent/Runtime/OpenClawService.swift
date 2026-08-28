import AppKit
import Darwin
import Foundation

struct OpenClawProbe: Equatable, Sendable {
    let executableURL: URL?
    let version: String
    let configured: Bool
    let detail: String

    var installed: Bool { executableURL != nil }
}

enum OpenClawAutomatedSetupEvent: Equatable {
    case progress(Double, String)
    case installed(String)
    case completed(String)
    case failed(String)
}

final class OpenClawService {
    static let setupArguments = ["agents", "list", "--json"]
    static let modelReadinessArguments = ["models", "status", "--json", "--check"]
    static let primaryModelArguments = ["config", "get", "agents.defaults.model.primary"]
    static let dashboardArguments = ["dashboard", "--yes"]
    static let installedWithoutKeyExitStatus: Int32 = 10
    static let installURL = URL(string: "https://docs.openclaw.ai/install")!
    static let allGeminiModels = [
        "google/gemini-3.5-flash",
        "google/gemini-3-flash-preview",
        "google/gemini-3.1-flash-lite",
        "google/gemini-2.5-flash",
        "google/gemini-2.5-flash-lite"
    ]
    // OpenClaw's base configuration still needs one default plus fallbacks;
    // TaskPilot's runtime independently round-robins the complete list above.
    static let primaryGeminiModel = allGeminiModels[0]
    static let fallbackGeminiModels = Array(allGeminiModels.dropFirst())

    private let setupIOQueue = DispatchQueue(label: "com.orbitagent.openclaw-setup-io")
    private var automatedSetupProcess: Process?
    private var automatedSetupBuffer = Data()
    private var automatedSetupReceivedFailure = false
    private var automatedSetupReportedInstalledOnly = false
    private var automatedSetupHandler: ((OpenClawAutomatedSetupEvent) -> Void)?

    func probe() async -> OpenClawProbe {
        await Task.detached(priority: .utility) {
            Self.probeSynchronously()
        }.value
    }

    @MainActor
    func openInstallGuide() {
        NSWorkspace.shared.open(Self.installURL)
    }

    func startAutomatedSetup(
        geminiAPIKey: String,
        onEvent: @escaping (OpenClawAutomatedSetupEvent) -> Void
    ) throws {
        guard automatedSetupProcess == nil else {
            throw OpenClawServiceError.automatedSetupAlreadyRunning
        }
        let scriptURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("OpenClaw", isDirectory: true)
            .appendingPathComponent("taskpilot-openclaw-bootstrap.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw OpenClawServiceError.automatedSetupHelperMissing
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        automatedSetupBuffer.removeAll(keepingCapacity: true)
        automatedSetupReceivedFailure = false
        automatedSetupReportedInstalledOnly = false
        automatedSetupHandler = onEvent
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeAutomatedSetupOutput(data)
        }
        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.setupIOQueue.async {
                output.fileHandleForReading.readabilityHandler = nil
                let receivedFailure = self.automatedSetupReceivedFailure
                self.automatedSetupProcess = nil
                if terminated.terminationStatus == 0 {
                    self.emitAutomatedSetupEvent(
                        .completed("OpenClaw is ready for \(TaskPilotIdentity.displayName)."),
                        through: self.automatedSetupHandler
                    )
                } else if terminated.terminationStatus == Self.installedWithoutKeyExitStatus {
                    if !self.automatedSetupReportedInstalledOnly {
                        self.emitAutomatedSetupEvent(
                            .installed("OpenClaw is installed. Add a Gemini API key whenever you are ready."),
                            through: self.automatedSetupHandler
                        )
                    }
                } else if !receivedFailure {
                    let message = terminated.terminationReason == .uncaughtSignal
                        ? "OpenClaw setup was stopped."
                        : "OpenClaw setup ended before verification completed."
                    self.emitAutomatedSetupEvent(.failed(message), through: self.automatedSetupHandler)
                }
                self.automatedSetupHandler = nil
            }
        }

        automatedSetupProcess = process
        do {
            try process.run()
            // The key is intentionally written only to stdin. It never appears
            // in Process.arguments, Process.environment, progress, or logs.
            try input.fileHandleForWriting.write(contentsOf: Data((geminiAPIKey + "\n").utf8))
            try input.fileHandleForWriting.close()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            automatedSetupProcess = nil
            automatedSetupHandler = nil
            throw error
        }
    }

    func cancelAutomatedSetup() {
        guard let process = automatedSetupProcess, process.isRunning else { return }
        kill(process.processIdentifier, SIGTERM)
        process.terminate()
    }

    @MainActor
    func openSetupTerminal() throws {
        let setupURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("OpenClaw", isDirectory: true)
            .appendingPathComponent("openclaw-setup.command")
        guard FileManager.default.isExecutableFile(atPath: setupURL.path) else {
            throw OpenClawServiceError.setupHelperMissing
        }
        NSWorkspace.shared.open(setupURL)
    }

    func openDashboard() async throws {
        guard let executable = Self.firstExecutable(from: Self.candidateExecutableURLs()) else {
            throw OpenClawServiceError.dashboardUnavailable
        }
        let status = await Task.detached(priority: .userInitiated) {
            Self.runDiscardingOutput(
                executable: executable,
                arguments: Self.dashboardArguments,
                timeout: 30
            )
        }.value
        guard status == 0 else {
            throw OpenClawServiceError.dashboardLaunchFailed
        }
    }

    static func candidateExecutableURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var paths: [String] = []
        if let configured = environment["ORBIT_OPENCLAW_PATH"], !configured.isEmpty {
            paths.append(configured)
        }
        paths.append(contentsOf: (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("openclaw").path })
        paths.append(contentsOf: [
            "/opt/homebrew/bin/openclaw",
            "/usr/local/bin/openclaw",
            homeDirectory.appendingPathComponent(".openclaw/bin/openclaw").path,
            homeDirectory.appendingPathComponent(".local/bin/openclaw").path,
            homeDirectory.appendingPathComponent(".npm-global/bin/openclaw").path
        ])
        var seen = Set<String>()
        return paths.compactMap { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    static func firstExecutable(
        from candidates: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func probeSynchronously() -> OpenClawProbe {
        guard let executable = firstExecutable(from: candidateExecutableURLs()) else {
            return OpenClawProbe(
                executableURL: nil,
                version: "",
                configured: false,
                detail: "OpenClaw is not installed"
            )
        }

        let versionResult = run(executable: executable, arguments: ["--version"], timeout: 8)
        let version = versionResult.output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? "Installed"
        let setupResult = run(
            executable: executable,
            arguments: setupArguments,
            timeout: 15
        )
        let modelResult = run(
            executable: executable,
            arguments: modelReadinessArguments,
            timeout: 20
        )
        let primaryModelResult = run(
            executable: executable,
            arguments: primaryModelArguments,
            timeout: 8
        )
        let usesRequestedPrimary = primaryModelResult.status == 0 &&
            primaryModelResult.output.contains(primaryGeminiModel)
        if setupResult.status == 0 && modelResult.status == 0 && usesRequestedPrimary {
            return OpenClawProbe(
                executableURL: executable,
                version: version,
                configured: true,
                detail: "OpenClaw agent and model configuration are available"
            )
        }

        if modelResult.status != 0 || !usesRequestedPrimary {
            return OpenClawProbe(
                executableURL: executable,
                version: version,
                configured: false,
                detail: "OpenClaw is installed. Add and verify the requested Gemini model chain to enable Run."
            )
        }

        let rawDetail = setupResult.output
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init) ?? "Run openclaw setup to choose a model and start OpenClaw"
        let detail = String(rawDetail.prefix(240))
        return OpenClawProbe(
            executableURL: executable,
            version: version,
            configured: false,
            detail: detail
        )
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return CommandResult(status: -2, output: "OpenClaw status check timed out")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    /// Runs commands whose output may contain an authenticated local URL.
    /// Neither stdout nor stderr is captured, logged, or surfaced by TaskPilot.
    private static func runDiscardingOutput(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return -2
        }
        return process.terminationStatus
    }

    private func consumeAutomatedSetupOutput(_ data: Data) {
        setupIOQueue.async { [weak self] in
            guard let self else { return }
            self.automatedSetupBuffer.append(data)
            while let newline = self.automatedSetupBuffer.firstIndex(of: 0x0A) {
                let lineData = self.automatedSetupBuffer[..<newline]
                self.automatedSetupBuffer.removeSubrange(...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                self.consumeAutomatedSetupLine(line)
            }
        }
    }

    private func consumeAutomatedSetupLine(_ rawLine: String) {
        guard rawLine.hasPrefix("ORBIT_SETUP|") else { return }
        let parts = rawLine.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return }
        let type = String(parts[1])
        let message = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "error" {
            automatedSetupReceivedFailure = true
            emitAutomatedSetupEvent(.failed(message), through: automatedSetupHandler)
        } else if type == "installed" {
            automatedSetupReportedInstalledOnly = true
            emitAutomatedSetupEvent(.installed(message), through: automatedSetupHandler)
        } else if let progress = Double(type) {
            emitAutomatedSetupEvent(
                .progress(min(max(progress, 0), 1), message),
                through: automatedSetupHandler
            )
        }
    }

    private func emitAutomatedSetupEvent(
        _ event: OpenClawAutomatedSetupEvent,
        through handler: ((OpenClawAutomatedSetupEvent) -> Void)?
    ) {
        guard let handler else { return }
        DispatchQueue.main.async {
            handler(event)
        }
    }
}

private enum OpenClawServiceError: LocalizedError {
    case setupHelperMissing
    case automatedSetupHelperMissing
    case automatedSetupAlreadyRunning
    case dashboardUnavailable
    case dashboardLaunchFailed

    var errorDescription: String? {
        switch self {
        case .setupHelperMissing:
            return "The OpenClaw setup helper is missing from this \(TaskPilotIdentity.displayName) build"
        case .automatedSetupHelperMissing:
            return "The automated OpenClaw installer is missing from this \(TaskPilotIdentity.displayName) build"
        case .automatedSetupAlreadyRunning:
            return "OpenClaw setup is already running"
        case .dashboardUnavailable:
            return "OpenClaw is not installed yet"
        case .dashboardLaunchFailed:
            return "OpenClaw could not start its authenticated dashboard. Click Recheck, then try again."
        }
    }
}
