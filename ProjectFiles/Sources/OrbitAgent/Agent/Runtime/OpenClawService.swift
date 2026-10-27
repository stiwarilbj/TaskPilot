import AppKit
import Darwin
import Foundation
import CryptoKit
import Network
import OSLog

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
    static let modelReadinessArguments = ["models", "status", "--json"]
    static let primaryModelArguments = ["config", "get", "agents.defaults.model.primary"]
    static let dashboardArguments = ["dashboard", "--yes"]
    static let installedWithoutKeyExitStatus: Int32 = 10
    static let installURL = URL(string: "https://docs.openclaw.ai/install")!
    static let primaryGeminiModels = [
        "google/gemini-3.5-flash-lite",
        "google/gemini-3.1-flash-lite"
    ]
    static let fallbackGeminiModels = [
        "google/gemini-2.5-flash-lite",
        "google/gemini-3.8-flash",
        "google/gemini-3-flash-preview",
        "google/gemini-2.5-flash"
    ]
    static let allGeminiModels = primaryGeminiModels + fallbackGeminiModels
    // OpenClaw's base configuration still needs one default plus fallbacks;
    // TaskPilot starts with the Lite pair and retains the first successful model.
    static let primaryGeminiModel = primaryGeminiModels[0]

    private let lifecycleLock = NSLock()
    private var inFlightProbe: Task<OpenClawProbe, Never>?
    private var probeID = UUID()
    private var setupTask: Task<Void, Never>?
    private var provisionedConfiguration: String?
    private var provisionAfter = Date.distantPast
    private var provisioningFailures = 0
    private var provisionedCredential: String?
    private var clientFile: URL?
    private var host: SubprocessSupervisor?
    private var wakeObserver: NSObjectProtocol?
    private let network = NWPathMonitor()
    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,
            object:nil, queue:nil) { _ in Self.requestHealthRefresh() }
        network.pathUpdateHandler = { path in if path.status == .satisfied { Self.requestHealthRefresh() } }
        network.start(queue:DispatchQueue(label:"com.orbitagent.openclaw-network", qos:.utility))
    }
    private static func requestHealthRefresh() {
        guard FileManager.default.fileExists(atPath:ManagedOpenClawDescriptor.url.path) else { return }
        try? Data("{}".utf8).write(to:ManagedOpenClawDescriptor.root.appendingPathComponent("health-request.json"), options:.atomic)
    }

    deinit {
        network.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let clientFile { try? FileManager.default.removeItem(at: clientFile) }
    }

    /// Concurrent status checks join one local operation. The host, rather than
    /// callers, owns cadence and the persisted restart circuit.
    func probe() async -> OpenClawProbe {
        let (task, id) = lifecycleLock.withLock { () -> (Task<OpenClawProbe, Never>, UUID) in
            if let inFlightProbe { return (inFlightProbe, probeID) }
            probeID = UUID()
            let task = Task.detached(priority: .utility) { self.managedProbe() }
            inFlightProbe = task
            return (task, probeID)
        }
        let result = await task.value
        lifecycleLock.withLock { if probeID == id { inFlightProbe = nil } }
        return result
    }

    private func managedProbe(force: Bool = false) -> OpenClawProbe {
        let key = (try? GeminiAPIKeyStore().load()) ?? ""
        let runtime = BundledRuntimeLocator().executableURL
        do {
            try TaskTemporaryResourceLedger.prepareStartup()
            let current = try? ManagedOpenClawDescriptor.load()
            var directoryRepair = false
            do { try current?.checkPrivateDirectories() }
            catch PrivateDirectoryPermissions.Failure.permissions { directoryRepair = true }
            if force || directoryRepair || provisionedCredential != SHA256.hash(data: Data(key.utf8)).description ||
                current == nil || provisionedConfiguration != current?.configurationFingerprint {
                guard Date() >= provisionAfter else {
                    throw ManagedOpenClawError.command("Private OpenClaw installation is waiting for network recovery; TaskPilot will retry automatically.")
                }
                let resources = Bundle.main.resourceURL!.appendingPathComponent("OpenClaw/managed")
                let result = Self.run(executable: runtime,
                    arguments: ["--managed-openclaw", "ensure", "--managed-resources", resources.path],
                    timeout: 1200, input: Data((key + "\n").utf8))
                guard result.status == 0 else {
                    provisioningFailures += 1
                    provisionAfter = Date().addingTimeInterval(min(300, 30 * pow(2, Double(min(provisioningFailures - 1, 4)))))
                    throw ManagedOpenClawError.command(result.output)
                }
                provisioningFailures = 0; provisionAfter = .distantPast
                provisionedConfiguration = try ManagedOpenClawDescriptor.load().configurationFingerprint
                provisionedCredential = SHA256.hash(data: Data(key.utf8)).description
            }
            let descriptor = try ManagedOpenClawDescriptor.load()
            try descriptor.checkPrivateDirectories()
            if clientFile == nil { clientFile = try ManagedGatewayHost.registerClient() }
            if host?.isRunning != true {
                let process = SubprocessSupervisor()
                process.executableURL = Bundle.main.executableURL
                process.arguments = ["--managed-openclaw-host", ManagedOpenClawDescriptor.url.path, runtime.path]
                process.environment = descriptor.environment
                try process.run(); process.markOutputDrained(); host = process
            }
            // Startup may be in progress. Return promptly; ordinary refreshes
            // neither reset the circuit nor launch a provider generation.
            let healthURL = ManagedOpenClawDescriptor.root.appendingPathComponent("health.json")
            let health = (try? Data(contentsOf: healthURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let matchesInstance = health?["instance_id"] as? String == descriptor.instanceID &&
                health?["configuration_fingerprint"] as? String == descriptor.configurationFingerprint
            let ready = health.map { descriptor.acceptsHealth($0) } ?? false
            return OpenClawProbe(executableURL: URL(fileURLWithPath: descriptor.executable), version: descriptor.openclawVersion,
                configured: ready, detail: matchesInstance ? (health?["detail"] as? String ?? "Starting private OpenClaw") : "Starting TaskPilot’s private OpenClaw Gateway")
        } catch {
            return OpenClawProbe(executableURL: (try? ManagedOpenClawDescriptor.load()).map { URL(fileURLWithPath:$0.executable) },
                version:"", configured:false, detail:error.localizedDescription)
        }
    }

    func takeActivationVerification() -> Bool {
        let file = ManagedOpenClawDescriptor.root.appendingPathComponent("activation-verification.json")
        let claim = file.appendingPathExtension(UUID().uuidString)
        guard rename(file.path, claim.path) == 0 else { return false }
        try? FileManager.default.removeItem(at:claim)
        return true
    }

    @MainActor
    func openInstallGuide() {
        NSWorkspace.shared.open(Self.installURL)
    }

    func startAutomatedSetup(geminiAPIKey: String, onEvent: @escaping (OpenClawAutomatedSetupEvent) -> Void) throws {
        guard setupTask == nil else { throw OpenClawServiceError.automatedSetupAlreadyRunning }
        setupTask = Task {
            onEvent(.progress(0.1, "Preparing TaskPilot’s pinned private OpenClaw runtime…"))
            // Setup and automatic readiness share the same serialized provisioning path.
            let probe = await self.probe()
            guard !Task.isCancelled else { self.setupTask = nil; return }
            if !probe.installed { onEvent(.failed(probe.detail)); self.setupTask = nil; return }
            if geminiAPIKey.isEmpty { onEvent(.installed("Private OpenClaw installed; save a Gemini API key in Settings.")); self.setupTask = nil; return }
            onEvent(.progress(0.7, "Waiting for authenticated Gateway connectivity…"))
            var ready = probe.configured
            for _ in 0..<45 where !ready && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                ready = await self.probe().configured
            }
            guard !Task.isCancelled else { self.setupTask = nil; return }
            if ready {
                let checks = await GeminiModelVerifier().verify(apiKey: geminiAPIKey, models: Self.allGeminiModels)
                if checks.contains(where: { if case .working = $0.state { return true }; return false }) {
                    onEvent(.completed("Private OpenClaw verified through TaskPilot with image input and JSON output."))
                } else { onEvent(.failed("Gateway connected, but provider verification failed. Check the reported credential, quota, or capacity condition.")) }
            } else { onEvent(.failed("Private Gateway is still recovering. TaskPilot will keep checking automatically.")) }
            self.setupTask = nil
        }
    }

    func cancelAutomatedSetup() { setupTask?.cancel(); setupTask = nil }

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
        guard let descriptor = try? ManagedOpenClawDescriptor.load() else {
            throw OpenClawServiceError.dashboardUnavailable
        }
        let status = await Task.detached(priority: .userInitiated) {
            Self.runDiscardingOutput(
                executable: URL(fileURLWithPath: descriptor.executable),
                arguments: Self.dashboardArguments,
                timeout: 30
            )
        }.value
        guard status == 0 else {
            throw OpenClawServiceError.dashboardLaunchFailed
        }
    }

    /// Version 1: fixed Node/locale/PATH policy; explicit proxies retain their
    /// configuration with uppercase precedence. Diagnostics contain category bits only.
    static func managedEnvironment(inherited: [String: String] = ProcessInfo.processInfo.environment,
                                   nodePath: String? = nil) -> (values: [String: String], mismatchCode: Int) {
        let stripped = ["OPENCLAW_", "NODE_", "NPM_", "npm_", "GOOGLE_", "GEMINI_"]
        var env = inherited.filter { item in !stripped.contains { item.key.hasPrefix($0) } && !item.key.hasPrefix("LC_") }
        env["LANG"] = "en_US.UTF-8"; env["LC_ALL"] = "en_US.UTF-8"; env.removeValue(forKey: "LANGUAGE")
        env["PATH"] = (nodePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin"
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"] {
            if let value = inherited[name] ?? inherited[name.lowercased()] {
                env[name] = value; env[name.lowercased()] = value
            }
        }
        env["OPENCLAW_HIDE_BANNER"] = "1"; env["OPENCLAW_SUPPRESS_NOTES"] = "1"; env["OPENCLAW_NO_RESPAWN"] = "1"
        var code = 0
        if inherited.keys.contains(where: { $0.hasPrefix("NODE_") || $0.hasPrefix("NPM_") || $0.hasPrefix("npm_") }) { code |= 1 }
        if Set(inherited.keys).union(env.keys).contains(where: {
            ($0 == "LANG" || $0 == "LANGUAGE" || $0.hasPrefix("LC_")) && inherited[$0] != env[$0]
        }) { code |= 2 }
        if ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].contains(where: {
            inherited[$0] != env[$0] || inherited[$0.lowercased()] != env[$0.lowercased()]
        }) { code |= 4 }
        if inherited["PATH"] != env["PATH"] { code |= 8 }
        Logger(subsystem: "com.orbitagent.controller", category: "ManagedEnvironment")
            .debug("Managed environment policy 1 mismatch code \(code, privacy: .public)")
        return (env, code)
    }

    static func candidateExecutableURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        guard let descriptor = try? ManagedOpenClawDescriptor.load() else { return [] }
        return [URL(fileURLWithPath: descriptor.executable)]
    }

    static func firstExecutable(
        from candidates: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    // Same stable inode and flock protocol as Python configuration_transaction.
    // Never hold this lease while waiting for an explicit generation check.
    static func configurationLease(root: URL? = nil, timeout: TimeInterval = 5) -> Int32? {
        let directory = root ?? ProcessInfo.processInfo.environment["ORBIT_RUNTIME_STATE_DIRECTORY"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Orbit Agent", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let descriptor = open(directory.appendingPathComponent("openclaw-configuration.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if flock(descriptor, LOCK_SH | LOCK_NB) == 0 { return descriptor }
            guard errno == EWOULDBLOCK || errno == EINTR else { break }
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        close(descriptor)
        return nil
    }

    struct CommandResult {
        let status: Int32
        let output: String
    }

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        outputSpillRoot: URL = FileManager.default.temporaryDirectory,
        input: Data? = nil, environment: [String: String]? = nil,
        cancellation: OpenClawCommandCancellation? = nil
    ) -> CommandResult {
        let process = SubprocessSupervisor()
        do {
            if cancellation?.isCancelled == true { return CommandResult(status: -2, output: "OpenClaw check cancelled") }
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment ?? managedEnvironment().values
            let pipe = try input.map { _ in try SubprocessSupervisor.makePrivatePipe() }
            if let pipe { process.standardInput = pipe }
            let exit = ProcessExitNotification(process)
            cancellation?.bind(process, exit: exit)
            defer { cancellation?.unbind() }
            defer { process.terminationHandler = nil }
            let capture = try BufferedProcessOutput(maximumBytes: 262144, combinedLimit: 1048576, merged: true, spillRoot: outputSpillRoot,
                                                   onInterruption: { exit.interrupt() })
            defer { capture.close() }
            process.standardOutput = capture.stdout
            process.standardError = capture.stderr
            try process.run()
            if cancellation?.isCancelled == true { process.beginTeardown() }
            if let pipe, let input {
                try pipe.fileHandleForWriting.write(contentsOf: input)
                try pipe.fileHandleForWriting.close()
            }
            capture.closeWriters()
            let status = waitForCommand(process, exit: exit, timeout: timeout)
            let output = try capture.finish().stdout
            process.markOutputDrained()
            if status == -2 { return CommandResult(status: status, output: "OpenClaw status check timed out") }
            guard !output.truncated else { return CommandResult(status: -1, output: "OpenClaw status output was incomplete") }
            return CommandResult(status: status,
                output: String(data: output.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        } catch {
            if process.snapshot.launched {
                process.beginTeardown()
                _ = process.waitForTree(ignoreInterrupt: true)
            }
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    /// Runs commands whose output may contain an authenticated local URL.
    /// Neither stdout nor stderr is captured, logged, or surfaced by TaskPilot.
    static func runDiscardingOutput(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> Int32 {
        let process = SubprocessSupervisor()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = managedEnvironment().values
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exit = ProcessExitNotification(process)
        defer { process.terminationHandler = nil }
        do {
            try process.run()
        } catch {
            return -1
        }

        let status = waitForCommand(process, exit: exit, timeout: timeout)
        process.markOutputDrained() // Both streams were explicitly discarded.
        return status
    }

    private static func waitForCommand(_ process: SubprocessSupervisor, exit: ProcessExitNotification, timeout: TimeInterval) -> Int32 {
        let deadline = DispatchTime.now() + timeout
        if case .exited(let status) = exit.wait(until: deadline),
           case .finished = process.waitForTree(until: deadline) { return status }
        process.beginTeardown()
        _ = process.waitForTree(ignoreInterrupt: true)
        _ = exit.waitForExit()
        return -2
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
