import Darwin
import Foundation

enum TaskToolError: LocalizedError {
    case invalidAction(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAction(let message), .operationFailed(let message):
            return message
        }
    }
}

/// Executes the non-visual tools that the user explicitly delegates to TaskPilot.
/// All results return through the same JSON bridge as visible Accessibility
/// actions, so OpenClaw receives bounded, structured evidence instead of a
/// second unobserved agent channel.
final class TaskToolExecutor {
    static let supportedActions: Set<String> = [
        "read_file", "write_file", "run_command"
    ]
    static let maximumReadBytes = 128 * 1024
    static let maximumWriteBytes = 2 * 1024 * 1024
    static let maximumCommandOutputBytes = 64 * 1024
    static let maximumCommandLength = 16 * 1024
    static let maximumCommandTimeout: TimeInterval = 900
    private let commandLock = NSLock()
    private var activeCommand: Process?

    func perform(action: [String: Any]) async throws -> [String: Any] {
        guard let type = action["type"] as? String else {
            throw TaskToolError.invalidAction("The tool action has no type")
        }
        switch type {
        case "read_file":
            return try readFile(action)
        case "write_file":
            return try writeFile(action)
        case "run_command":
            return try runCommand(action)
        default:
            throw TaskToolError.invalidAction("Unsupported task tool: \(type)")
        }
    }

    func pauseActiveCommand() {
        signalActiveCommand(SIGSTOP)
    }

    func resumeActiveCommand() {
        signalActiveCommand(SIGCONT)
    }

    func cancelActiveCommand() {
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

        let requestedLimit = Self.intValue(action["max_bytes"]) ?? Self.maximumReadBytes
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
            "truncated": truncated
        ]
    }

    private func writeFile(_ action: [String: Any]) throws -> [String: Any] {
        let url = try Self.fileURL(from: action)
        guard let content = action["content"] as? String else {
            throw TaskToolError.invalidAction("write_file requires content")
        }
        let encoding = (action["encoding"] as? String ?? "utf-8").lowercased()
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

        let mode = (action["mode"] as? String ?? "overwrite").lowercased()
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

        let createParents = action["create_parents"] as? Bool ?? true
        let parent = url.deletingLastPathComponent()
        if createParents {
            do {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
            } catch {
                throw TaskToolError.operationFailed(
                    "\(TaskPilotIdentity.displayName) could not create the destination folder: \(error.localizedDescription)"
                )
            }
        }

        do {
            if mode == "append", FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            throw TaskToolError.operationFailed(
                "\(TaskPilotIdentity.displayName) could not write \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }

        let verified: Bool
        let finalSize: Int
        do {
            let written = try Data(contentsOf: url)
            finalSize = written.count
            verified = mode == "append" ? written.suffix(data.count) == data : written == data
        } catch {
            throw TaskToolError.operationFailed(
                "\(TaskPilotIdentity.displayName) wrote \(url.lastPathComponent), but could not verify it: \(error.localizedDescription)"
            )
        }
        guard verified else {
            throw TaskToolError.operationFailed(
                "\(TaskPilotIdentity.displayName) wrote \(url.lastPathComponent), but its contents did not verify"
            )
        }

        return [
            "message": "\(mode == "append" ? "Appended" : "Wrote") and verified \(data.count) bytes in \(url.lastPathComponent)",
            "path": url.path,
            "bytes_written": data.count,
            "file_size": finalSize,
            "mode": mode,
            "verified": true
        ]
    }

    private func runCommand(_ action: [String: Any]) throws -> [String: Any] {
        guard let rawCommand = action["command"] as? String else {
            throw TaskToolError.invalidAction("run_command requires command")
        }
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw TaskToolError.invalidAction("run_command requires a non-empty command")
        }
        guard command.utf8.count <= Self.maximumCommandLength else {
            throw TaskToolError.invalidAction(
                "run_command is limited to \(Self.maximumCommandLength) command bytes"
            )
        }

        let workingDirectory: URL
        if let path = action["working_directory"] as? String, !path.isEmpty {
            workingDirectory = Self.expandedFileURL(path)
        } else {
            workingDirectory = FileManager.default.homeDirectoryForCurrentUser
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workingDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw TaskToolError.invalidAction(
                "The command working directory does not exist: \(workingDirectory.path)"
            )
        }

        let requestedTimeout = Self.doubleValue(action["timeout_seconds"]) ?? 120
        let timeout = min(Self.maximumCommandTimeout, max(0.2, requestedTimeout))
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-command-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [environment["PATH"], fallbackPath]
            .compactMap { $0 }
            .joined(separator: ":")
        environment["TERM"] = "dumb"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw TaskToolError.operationFailed(
                "\(TaskPilotIdentity.displayName) could not start the command: \(error.localizedDescription)"
            )
        }
        // Keep the shell and any child processes in one task-owned group so
        // TaskPilot's Pause and Stop controls apply to the entire command tree.
        _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
        commandLock.lock()
        activeCommand = process
        commandLock.unlock()
        defer {
            commandLock.lock()
            if activeCommand === process { activeCommand = nil }
            commandLock.unlock()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let stdout = try Self.boundedText(from: stdoutURL)
        let stderr = try Self.boundedText(from: stderrURL)
        return [
            "message": timedOut
                ? "Command timed out after \(String(format: "%.1f", timeout)) seconds"
                : "Command finished with exit code \(process.terminationStatus)",
            "command": command,
            "working_directory": workingDirectory.path,
            "exit_code": Int(process.terminationStatus),
            "timed_out": timedOut,
            "stdout": stdout.text,
            "stderr": stderr.text,
            "stdout_truncated": stdout.truncated,
            "stderr_truncated": stderr.truncated
        ]
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

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
