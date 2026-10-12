import Darwin
import Foundation
import CryptoKit

enum TaskToolError: LocalizedError {
    case invalidAction(String)
    case operationFailed(String)
    case uncertainDelivery(String)

    var code: String {
        switch self {
        case .invalidAction: return "invalid_action"
        case .operationFailed: return "delivery_rejected"
        case .uncertainDelivery: return "delivery_uncertain"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidAction(let message), .operationFailed(let message), .uncertainDelivery(let message):
            return message
        }
    }
}

/// Executes the non-visual tools that the user explicitly delegates to TaskPilot.
/// All results return through the same JSON bridge as visible Accessibility
/// actions, so OpenClaw receives bounded, structured evidence instead of a
/// second unobserved agent channel.
final class TaskToolExecutor {
    static let supportedActions = Set(ActionKind.allCases.filter { $0.owner == .task_tool }.map(\.rawValue))
    static let maximumReadBytes = ActionContract.limit("read_bytes")
    static let maximumWriteBytes = ActionContract.limit("write_bytes")
    static let maximumCommandOutputBytes = ActionContract.limit("command_output_bytes")
    static let maximumCommandLength = ActionContract.limit("command_bytes")
    static let maximumCommandTimeout = TimeInterval(ActionContract.limit("command_timeout"))
    private let commandLock = NSLock()
    private var activeCommand: Process?
    private var commandCancelled = false
    private var commandPaused = false

    func perform(action input: [String: Any]) async throws -> [String: Any] {
        try await TaskOwnership.checkpoint()
        let action: [String: Any]
        do { action = try ActionContract.validate(input) }
        catch { throw TaskToolError.invalidAction(error.localizedDescription) }
        switch ActionKind(rawValue: action["type"] as! String)! {
        case .read_file: return try readFile(action)
        case .write_file: return try writeFile(action)
        case .run_command: return try runCommand(action)
        case .none, .press, .focus, .set_value, .click, .double_click, .type_text, .key, .scroll, .launch_app, .open_route, .wait, .navigate_browser:
            throw TaskToolError.invalidAction("Unsupported task tool: \(action["type"]!)")
        }
    }

    /// Private completion readback. Validates the original payload but never
    /// dispatches it, starts a process, or replays a mutation.
    func recheck(action input: [String: Any]) async throws -> [String: Any] {
        try await TaskOwnership.checkpoint()
        let action: [String: Any]
        do { action = try ActionContract.validate(input) }
        catch { throw TaskToolError.invalidAction(error.localizedDescription) }
        if action["type"] as? String == "read_file" { return try readFile(action) }
        let requested: [[String: Any]]
        if action["type"] as? String == "write_file", (action["mode"] as? String ?? "overwrite") == "overwrite" {
            requested = [["type": "file_contents", "path": action["path"]!,
                          "content": action["content"]!, "encoding": action["encoding"] ?? "utf-8"]]
        } else if action["type"] as? String == "run_command" {
            requested = (action["checks"] as? [[String: Any]] ?? []).filter { $0["type"] as? String != "stdout_equals" }
        } else { throw TaskToolError.invalidAction("Only native file outcomes can be rechecked") }
        return try await checkOutcomes(requested)
    }

    /// Read-only expected effect check; no action dispatch or command launch.
    func checkOutcome(_ input: Any) async throws -> [String: Any] {
        let check: [String: Any]
        do { check = try ActionContract.validateOutcomeCheck(input) }
        catch { throw TaskToolError.invalidAction(error.localizedDescription) }
        guard check["type"] as? String != "stdout_equals" else {
            throw TaskToolError.invalidAction("Standalone checks cannot inspect command output")
        }
        return try await checkOutcomes([check])
    }

    private func checkOutcomes(_ input: [[String: Any]]) async throws -> [String: Any] {
        var requested: [[String: Any]] = []
        for check in input {
            do { requested.append(try ActionContract.validateOutcomeCheck(check)) }
            catch { throw TaskToolError.invalidAction(error.localizedDescription) }
        }
        var checks: [[String: Any]] = []
        for check in requested {
            try await TaskOwnership.checkpoint()
            let path = Self.expandedFileURL(check["path"] as! String)
            var expected: Data?
            if check["type"] as? String == "file_contents" {
                let content = check["content"] as! String
                expected = check["encoding"] as? String == "base64" ? Data(base64Encoded: content)! : Data(content.utf8)
            }
            checks.append(CommandExecutionPolicy.Check(type: check["type"] as! String, path: path,
                                                       expected: expected, text: nil).evaluate(stdout: "", stdoutTruncated: false))
        }
        try TaskOwnership.check()
        return ["requested_checks": requested, "checks": checks]
    }

    func pauseActiveCommand() {
        commandLock.lock(); commandPaused = true; commandLock.unlock()
        signalActiveCommand(SIGSTOP)
    }

    func resumeActiveCommand() {
        commandLock.lock(); commandPaused = false; commandLock.unlock()
        signalActiveCommand(SIGCONT)
    }

    func cancelActiveCommand() {
        commandLock.lock(); commandCancelled = true; commandLock.unlock()
        signalActiveCommand(SIGCONT)
        signalActiveCommand(SIGTERM)
    }

    private func readFile(_ action: [String: Any]) throws -> [String: Any] {
        let url = try Self.fileURL(from: action)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw TaskToolError.operationFailed("No readable file exists at \(url.path)")
        }

        let requestedLimit = (action["max_bytes"] as? NSNumber)?.intValue ?? (ActionContract.defaultValue(.read_file, "max_bytes") as! NSNumber).intValue
        let limit = min(Self.maximumReadBytes, max(1, requestedLimit))
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw TaskToolError.operationFailed(
                "\(TaskPilotIdentity.displayName) could not open \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw TaskToolError.operationFailed(
                "\(TaskPilotIdentity.displayName) could not read \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        let truncated = data.count > limit
        let bounded = Data(data.prefix(limit))
        let content: String
        let encoding: String
        if let text = String(data: bounded, encoding: .utf8) {
            content = text
            encoding = "utf-8"
        } else {
            content = bounded.base64EncodedString()
            encoding = "base64"
        }
        return [
            "message": "Read \(bounded.count) bytes from \(url.lastPathComponent)" +
                (truncated ? " (output truncated)" : ""),
            "path": url.path,
            "content": content,
            "encoding": encoding,
            "bytes_returned": bounded.count,
            "content_sha256": SHA256.hash(data: bounded).map { String(format: "%02x", $0) }.joined(),
            "truncated": truncated
        ]
    }

    private func writeFile(_ action: [String: Any]) throws -> [String: Any] {
        let url = try Self.fileURL(from: action)
        guard let content = action["content"] as? String else {
            throw TaskToolError.invalidAction("write_file requires content")
        }
        let encoding = (action["encoding"] as? String ?? ActionContract.defaultValue(.write_file, "encoding") as! String).lowercased()
        let data: Data
        switch encoding {
        case "utf-8", "utf8":
            data = Data(content.utf8)
        case "base64":
            guard let decoded = Data(base64Encoded: content) else {
                throw TaskToolError.invalidAction("write_file received invalid base64 content")
            }
            data = decoded
        default:
            throw TaskToolError.invalidAction("write_file supports utf-8 or base64 encoding")
        }
        guard data.count <= Self.maximumWriteBytes else {
            throw TaskToolError.invalidAction(
                "write_file is limited to \(Self.maximumWriteBytes) bytes per action"
            )
        }

        let mode = (action["mode"] as? String ?? ActionContract.defaultValue(.write_file, "mode") as! String).lowercased()
        guard mode == "overwrite" || mode == "append" else {
            throw TaskToolError.invalidAction("write_file mode must be overwrite or append")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw TaskToolError.invalidAction("write_file cannot replace a directory")
        }
        if Self.isSymbolicLink(url) {
            throw TaskToolError.invalidAction("write_file will not overwrite a symbolic link")
        }

        let createParents = action["create_parents"] as? Bool ?? ActionContract.defaultValue(.write_file, "create_parents") as! Bool
        let parent = url.deletingLastPathComponent()
        if createParents {
            do {
                try TaskOwnership.commit {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                }
            } catch {
                throw TaskToolError.operationFailed(
                    "\(TaskPilotIdentity.displayName) could not create the destination folder: \(error.localizedDescription)"
                )
            }
        }

        do {
            try TaskOwnership.commit {
            if mode == "append", FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            }
        } catch {
            throw TaskToolError.uncertainDelivery(
                "\(TaskPilotIdentity.displayName) could not write \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }

        try TaskOwnership.check()
        let verified: Bool
        let finalSize: Int
        do {
            let written = try Data(contentsOf: url)
            finalSize = written.count
            verified = mode == "append" ? written.suffix(data.count) == data : written == data
        } catch {
            throw TaskToolError.uncertainDelivery(
                "\(TaskPilotIdentity.displayName) wrote \(url.lastPathComponent), but could not verify it: \(error.localizedDescription)"
            )
        }
        guard verified else {
            throw TaskToolError.uncertainDelivery(
                "\(TaskPilotIdentity.displayName) wrote \(url.lastPathComponent), but its contents did not verify"
            )
        }

        return [
            "message": "\(mode == "append" ? "Appended" : "Wrote") and verified \(data.count) bytes in \(url.lastPathComponent)",
            "path": url.path,
            "bytes_written": data.count,
            "content_sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "file_size": finalSize,
            "mode": mode,
            "verified": true,
            "outcome": "verified"
        ]
    }

    private func runCommand(_ action: [String: Any]) throws -> [String: Any] {
        try TaskOwnership.check()
        commandLock.lock(); commandCancelled = false; commandLock.unlock()
        try Task.checkCancellation()
        var environment = ProcessInfo.processInfo.environment
        let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [environment["PATH"], fallbackPath].compactMap { $0 }.joined(separator: ":")
        environment["TERM"] = "dumb"
        let policy = try CommandExecutionPolicy(action: action, environment: environment)
        environment["PWD"] = policy.workingDirectory.path
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        if let source = policy.shellSource {
            // -n parses the complete source without executing substitutions or
            // earlier statements. -f avoids user startup scripts in both phases.
            let syntax = try executeProcess(executable: policy.executable, arguments: ["-f", "-n", "-c", source],
                                            policy: policy, environment: environment,
                                            directory: temporaryDirectory, prefix: "syntax", timeout: min(5, policy.timeout))
            guard !syntax.timedOut, syntax.status == 0 else {
                throw TaskToolError.invalidAction("Shell syntax check failed before execution: " + syntax.stderr.text)
            }
        }
        let execution = try executeProcess(executable: policy.executable, arguments: policy.arguments,
                                           policy: policy, environment: environment,
                                           directory: temporaryDirectory, prefix: "command", timeout: policy.timeout)
        let checks = policy.checks.map { $0.evaluate(stdout: execution.stdout.text, stdoutTruncated: execution.stdout.truncated) }
        let executed = !execution.timedOut && execution.status == 0
        let verified = executed && !checks.isEmpty && checks.allSatisfy { $0["verified"] as? Bool == true }
        return [
            "message": execution.timedOut
                ? "Command timed out; inspect its effects before retrying"
                : verified ? "Command finished and its requested outcome checks passed"
                : "Command finished with exit code \(execution.status); its requested outcome is not verified",
            "command": policy.displayCommand,
            "working_directory": policy.workingDirectory.path,
            "execution_method": policy.shellSource == nil ? "argument_array" : "shell",
            "syntax_checked": policy.shellSource != nil,
            "exit_code": Int(execution.status),
            "timed_out": execution.timedOut,
            "executed": executed,
            "verified": verified,
            "outcome": verified ? "verified" : "delivered_unconfirmed",
            "verification_scope": checks.isEmpty ? "execution_only" : "requested_outcomes",
            "checks": checks,
            "stdout": execution.stdout.text,
            "stderr": execution.stderr.text,
            "stdout_truncated": execution.stdout.truncated,
            "stderr_truncated": execution.stderr.truncated
        ]
    }

    private func executeProcess(executable: URL, arguments: [String], policy: CommandExecutionPolicy,
                                environment: [String: String], directory: URL, prefix: String, timeout: TimeInterval)
        throws -> (status: Int32, timedOut: Bool, stdout: (text: String, truncated: Bool), stderr: (text: String, truncated: Bool)) {
        let stdoutURL = directory.appendingPathComponent(prefix + "-stdout")
        let stderrURL = directory.appendingPathComponent(prefix + "-stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdoutHandle.close(); try? stderrHandle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = policy.workingDirectory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        // Always acquire the ownership gate before the command lock. Pause
        // cannot strand a launcher holding the lock Resume needs.
        try TaskOwnership.commit {
            commandLock.lock(); defer { commandLock.unlock() }
            if commandCancelled { throw CancellationError() }
            do { try process.run() }
            catch { throw TaskToolError.operationFailed("Could not start the command: \(error.localizedDescription)") }
            _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
            activeCommand = process
            if commandPaused, Darwin.kill(-process.processIdentifier, SIGSTOP) != 0 {
                Darwin.kill(process.processIdentifier, SIGSTOP)
            }
        }
        defer {
            commandLock.lock()
            if activeCommand === process { activeCommand = nil }
            commandLock.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            if Task.isCancelled || (TaskOwnership.current?.state == .draining) || (TaskOwnership.current?.state == .retired) { cancelActiveCommand() }
            commandLock.lock(); let cancelled = commandCancelled; commandLock.unlock()
            if cancelled { break }
            Thread.sleep(forTimeInterval: 0.025)
        }
        let timedOut = process.isRunning
        if timedOut {
            signalActiveCommand(SIGCONT)
            signalActiveCommand(SIGTERM)
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.025) }
            // Also kill children that outlive their shell.
            if Darwin.kill(-process.processIdentifier, SIGKILL) != 0, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        commandLock.lock(); let cancelled = commandCancelled; commandLock.unlock()
        if cancelled || Task.isCancelled {
            Darwin.kill(-process.processIdentifier, SIGKILL)
            throw CancellationError()
        }
        try? stdoutHandle.synchronize(); try? stderrHandle.synchronize()
        do {
            return (process.terminationStatus, timedOut, try Self.boundedText(from: stdoutURL), try Self.boundedText(from: stderrURL))
        } catch {
            if prefix == "syntax" { throw TaskToolError.operationFailed("Shell syntax-check output could not be read; the command was not executed") }
            throw TaskToolError.uncertainDelivery("The command ended, but its output could not be read; inspect its effects before running it again")
        }
    }

    private static func fileURL(from action: [String: Any]) throws -> URL {
        guard let path = action["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskToolError.invalidAction("The file action requires path")
        }
        return expandedFileURL(path)
    }

    static func expandedFileURL(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            absolute = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(expanded)
                .path
        }
        return URL(fileURLWithPath: absolute).standardizedFileURL
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeSymbolicLink
    }

    private static func boundedText(from url: URL) throws -> (text: String, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumCommandOutputBytes + 1) ?? Data()
        let truncated = data.count > maximumCommandOutputBytes
        return (
            String(decoding: data.prefix(maximumCommandOutputBytes), as: UTF8.self),
            truncated
        )
    }

    private func signalActiveCommand(_ signal: Int32) {
        commandLock.lock()
        let process = activeCommand
        commandLock.unlock()
        guard let process, process.isRunning else { return }
        if Darwin.kill(-process.processIdentifier, signal) != 0 {
            Darwin.kill(process.processIdentifier, signal)
        }
    }


}
