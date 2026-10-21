import Darwin
import Foundation
import CryptoKit

enum TaskToolError: LocalizedError {
    case invalidAction(String)
    case operationFailed(String)
    case uncertainDelivery(String)
    case commandCapability(String, String)

    var code: String {
        switch self {
        case .invalidAction: return "invalid_action"
        case .operationFailed: return "delivery_rejected"
        case .uncertainDelivery: return "delivery_uncertain"
        case .commandCapability(let code, _): return code
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidAction(let message), .operationFailed(let message), .uncertainDelivery(let message):
            return message
        case .commandCapability(_, let message): return message
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
    private var activeCommand: SubprocessSupervisor?
    private var activeCommandExit: ProcessExitNotification?
    private var commandCancelled = false
    private var commandPaused = false
    private let capabilityLock = NSLock()
    private var commandBindings: [String: CommandCapabilities.Binding] = [:]
    private var helpCache: [String: (created: TimeInterval, result: [String: Any])] = [:]
    private var helpCacheEpoch: UInt64 = 0
    private var pressureRegistration: MemoryPressureMonitor.Registration?
    private let profileProvider: (String, [String?]) -> CommandCapabilities.Profile?
    private let outputSpillRoot: URL

    init(profileProvider: @escaping (String, [String?]) -> CommandCapabilities.Profile? = CommandCapabilities.profile,
         outputSpillRoot: URL = FileManager.default.temporaryDirectory,
         memoryPressure: MemoryPressureMonitor = .shared) {
        self.profileProvider = profileProvider
        self.outputSpillRoot = outputSpillRoot
        pressureRegistration = memoryPressure.register { [weak self] in self?.evictDisposableCaches() }
    }

    private func evictDisposableCaches() {
        capabilityLock.withLock { helpCache.removeAll(); helpCacheEpoch &+= 1 }
        // Inspected command bindings remain authoritative until task teardown.
    }

    func resetCommandCapabilities() {
        capabilityLock.withLock { commandBindings.removeAll(); helpCache.removeAll(); helpCacheEpoch &+= 1 }
    }

    static func commandEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        var seen: Set<String> = []
        environment["PATH"] = [environment["PATH"] ?? "", fallback].joined(separator: ":").split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        environment["TERM"] = "dumb"
        return environment
    }

    /// A probe has no action receipt: neither syntax checking nor help output
    /// can acknowledge delivery of the original command or prove its outcome.
    func inspectCommand(action input: [String: Any]) async throws -> [String: Any] {
        try await TaskOwnership.checkpoint()
        let lease = TaskOwnership.current
        return try await withTaskCancellationHandler {
            try TaskOwnership.$actionReceipt.withValue(nil) {
                var probes = 0, hits = 0
                do { return try prepareCommand(input, diagnostics: { probes = $0; hits = $1 }).result }
                catch let error as TaskToolError {
                    return ["ready": false, "error_code": error.code, "message": error.localizedDescription,
                            "capability_version": CommandCapabilities.version, "probes": probes, "cache_hits": hits]
                }
            }
        } onCancel: { lease?.wakePausedWorkers(); self.cancelActiveCommand() }
    }

    func perform(action input: [String: Any], commandBindingID: String? = nil) async throws -> [String: Any] {
        try await TaskOwnership.withCancellationWakeup {
            try await performOwned(action: input, commandBindingID: commandBindingID)
        }
    }

    private func performOwned(action input: [String: Any], commandBindingID: String?) async throws -> [String: Any] {
        try await TaskOwnership.checkpoint()
        let action: [String: Any]
        do { action = try ActionContract.validate(input) }
        catch { throw TaskToolError.invalidAction(error.localizedDescription) }
        switch ActionKind(rawValue: action["type"] as! String)! {
        case .read_file: return try readFile(action)
        case .write_file: return try writeFile(action)
        case .run_command:
            return try await withTaskCancellationHandler {
                try runCommand(action, bindingID: commandBindingID)
            } onCancel: { self.cancelActiveCommand() }
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
        let verified = !checks.isEmpty && checks.allSatisfy { $0["verified"] as? Bool == true }
        return try ActionContract.validateCheckBatch(["requested_checks": requested, "checks": checks,
            "outcome": verified ? "verified" : "delivered_unconfirmed", "verified": verified,
            "verification_scope": "requested_outcomes"])
    }

    func pauseActiveCommand() {
        commandLock.lock(); commandPaused = true; let process = activeCommand; commandLock.unlock()
        Self.signal(process, SIGSTOP)
    }

    func resumeActiveCommand() {
        commandLock.lock(); commandPaused = false; let process = activeCommand; commandLock.unlock()
        Self.signal(process, SIGCONT)
    }

    func cancelActiveCommand() {
        commandLock.lock(); commandCancelled = true
        let process = activeCommand, exit = activeCommandExit
        commandLock.unlock()
        exit?.interrupt()
        process?.interrupt()
        Self.signal(process, SIGCONT)
        Self.signal(process, SIGTERM)
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
            "action_type": "read_file", "outcome": "verified", "verified": true, "verification_scope": "file_read",
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
            "action_type": "write_file", "verification_scope": "file_write",
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

    private func prepareCommand(_ input: [String: Any], diagnostics: ((Int, Int) -> Void)? = nil) throws -> CommandCapabilities.Binding {
        var probes = 0, cacheHits = 0
        defer { diagnostics?(probes, cacheHits) }
        try TaskOwnership.check()
        let generation = TaskOwnership.current?.id
        let suspension = TaskOwnership.current?.suspensionRevision ?? 0
        let action = try ActionContract.validate(input)
        guard action["type"] as? String == "run_command", action["operation"] == nil else {
            throw TaskToolError.invalidAction("Capability inspection requires a general run_command action")
        }
        commandLock.withLock { commandCancelled = false }
        var environment = Self.commandEnvironment()
        let policy = try CommandExecutionPolicy(action: action, environment: environment)
        let directoryIdentity = try CommandCapabilities.Identity(policy.workingDirectoryInput, directory: true)
        let shellIdentity = policy.shellSource == nil ? nil : try CommandCapabilities.Identity(policy.executable)
        environment["PWD"] = policy.workingDirectory.path
        let key = try CommandCapabilities.digest(["action": action, "environment": environment])
        let existing = capabilityLock.withLock { commandBindings.values.first { $0.actionKey == key && $0.generation == TaskOwnership.current?.id } }
        if let existing, (try? existing.validate()) != nil {
            cacheHits += 1
            var result = existing.result
            result["cache_hit"] = true; result["probes"] = 0; result["cache_hits"] = 0
            return .init(id: existing.id, created: existing.created, actionKey: key, generation: existing.generation, suspension: existing.suspension,
                policy: existing.policy, environment: existing.environment, directory: existing.directory, shell: existing.shell,
                tools: existing.tools, source: existing.source, result: result)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + CommandCapabilities.probeBudget
        if let source = policy.shellSource {
            let syntax = try executeProcess(executable: policy.executable, arguments: ["-f", "-n", "-c", source],
                policy: policy, environment: environment, prefix: "syntax",
                timeout: CommandCapabilities.probeBudget, probe: true)
            guard !syntax.timedOut, syntax.status == 0 else {
                throw TaskToolError.commandCapability("command_syntax", "Shell syntax check failed before execution: " + syntax.stderr.text)
            }
        }
        var source = CommandCapabilities.source(policy)
        if policy.shellSource != nil, source.complete, !source.invocations.isEmpty {
            // Ask the same shell about literal heads. PATH lookup alone cannot
            // distinguish a builtin/alias/function from an external program.
            let names = source.invocations.map(\.name)
            if names.contains(where: { $0.contains("\n") }) || deadline <= ProcessInfo.processInfo.systemUptime {
                source = .init(invocations: [], complete: false, builtinOnly: false, characters: source.characters)
            } else {
                let resolution = try executeProcess(executable: policy.executable,
                    arguments: ["-f", "-c", "builtin whence -w -- \"$@\"", "taskpilot-command-inspection"] + names,
                    policy: policy, environment: environment, prefix: "resolution",
                    timeout: min(0.8, deadline - ProcessInfo.processInfo.systemUptime), probe: true)
                var lines = resolution.stdout.text.split(separator: "\n").map(String.init)
                if !resolution.timedOut, !resolution.stdout.truncated, lines.count == names.count {
                    for index in names.indices where lines[index] == names[index] + ": none" {
                        // Inline PATH prefixes are resolved separately below;
                        // they cannot turn a builtin into an external command.
                        if source.invocations[index].overrides["PATH"] != nil {
                            lines[index] = names[index] + ": command"
                        } else {
                            throw TaskToolError.commandCapability("command_tool_missing", "Executable '\(names[index])' was not found by the inspected shell")
                        }
                    }
                }
                if resolution.timedOut || resolution.stdout.truncated || lines != names.map({ $0 + ": command" }) {
                    // Preserve shell behavior whenever resolution is ambiguous
                    // or a builtin/function/alias must retain its semantics.
                    source = .init(invocations: [], complete: false, builtinOnly: false, characters: source.characters)
                }
            }
        }
        var tools: [CommandCapabilities.Tool] = [], unsupported: [String] = []
        for invocation in source.invocations {
            try TaskOwnership.check()
            var toolEnvironment = environment
            toolEnvironment.merge(invocation.overrides) { _, new in new }
            let executable = try CommandExecutionPolicy.resolveExecutable(invocation.name, cwd: policy.workingDirectory, environment: toolEnvironment)
            let identity = try CommandCapabilities.Identity(executable)
            var summary: [String: Any] = ["name": invocation.name, "executable": identity.path,
                "option_status": "unverified", "reason": "No established help-only probe is available for this tool"]
            if let profile = profileProvider(identity.path, invocation.arguments) {
                let cacheKey = try CommandCapabilities.digest(["path": identity.path, "device": identity.device, "inode": identity.inode,
                    "size": identity.size, "modified": [identity.modified.tv_sec, identity.modified.tv_nsec],
                    "changed": [identity.changed.tv_sec, identity.changed.tv_nsec], "environment": toolEnvironment,
                    "directory": policy.workingDirectory.path, "probe": profile.arguments])
                let (cached, cacheEpoch) = capabilityLock.withLock { (helpCache[cacheKey], helpCacheEpoch) }
                if let cached, ProcessInfo.processInfo.systemUptime - cached.created < 120 {
                    summary.merge(cached.result) { _, new in new }; cacheHits += 1
                } else if deadline > ProcessInfo.processInfo.systemUptime {
                    probes += 1
                    let result = try executeProcess(executable: URL(fileURLWithPath: identity.path), arguments: profile.arguments,
                        policy: policy, environment: toolEnvironment, prefix: "probe-\(probes)",
                        timeout: min(0.8, deadline - ProcessInfo.processInfo.systemUptime), probe: true)
                    let help = result.stdout.text + "\n" + result.stderr.text
                    let flags = CommandCapabilities.longOptions(help).sorted()
                    let shortFlags = CommandCapabilities.shortOptions(help).sorted()
                    let helpExit = result.status == 0 || (URL(fileURLWithPath: identity.path).lastPathComponent == "git" && profile.context != "global" && result.status == 129 && help.contains("usage:"))
                    let rejectedHelp = help.range(of: "unknown option|unrecognized option|illegal option|invalid option|unsupported option", options: [.regularExpression, .caseInsensitive]) != nil
                    let complete = helpExit && !rejectedHelp && !result.timedOut && !result.stdout.truncated && !result.stderr.truncated && !help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let probed: [String: Any] = ["context": profile.context, "option_status": complete ? "inspected" : "unverified",
                        "supported_long_options": Array(flags.prefix(256)), "help_excerpt": String(help.prefix(1800)),
                        "supported_short_options": Array(shortFlags.prefix(128)),
                        "value_options": CommandCapabilities.valueOptions(help),
                        "help_truncated": !complete || help.count > 1800, "probe_exit_code": Int(result.status),
                        "complete_option_list": complete && profile.exhaustiveLongOptions && !flags.isEmpty && flags.count <= 256,
                        "reason": complete ? "Options observed through the resolved executable's help interface" : "Help probe was incomplete; do not infer missing options"]
                    summary.merge(probed) { _, new in new }
                    if complete {
                        capabilityLock.withLock {
                            guard helpCacheEpoch == cacheEpoch else { return }
                            if helpCache.count >= CommandCapabilities.maximumBindings { helpCache.removeAll() }
                            helpCache[cacheKey] = (ProcessInfo.processInfo.systemUptime, probed)
                        }
                    }
                } else { summary["reason"] = "The shared local probe deadline elapsed; options remain unverified" }
            }
            // Only exhaustive, complete interfaces justify a negative claim.
            // Dynamic arguments and interpreter/script flags are never guessed.
            if summary["complete_option_list"] as? Bool == true, invocation.arguments.allSatisfy({ $0 != nil }) {
                let known = Set(summary["supported_long_options"] as? [String] ?? [])
                let missing = CommandCapabilities.requestedLongOptions(invocation.arguments, takingValues: summary["value_options"] as? [String: Int] ?? [:]).subtracting(known)
                if !missing.isEmpty { summary["unadvertised_options"] = missing.sorted(); unsupported.append(contentsOf: missing.sorted()) }
            }
            guard try CommandCapabilities.Identity(executable) == identity else {
                throw TaskToolError.commandCapability("command_capabilities_changed", "The executable changed while its options were being inspected; no command was delivered")
            }
            tools.append(.init(invocation: invocation, identity: identity, environment: toolEnvironment, summary: summary))
        }
        let id = UUID().uuidString
        let result: [String: Any] = ["ready": unsupported.isEmpty, "inspection_id": id,
            "capability_version": CommandCapabilities.version, "tools": tools.map(\.summary),
            "resolution_complete": source.complete, "builtin_only": source.builtinOnly,
            "message": unsupported.isEmpty ? "Command tools inspected; unverified capabilities remain explicit" : "Options are not advertised by the inspected tool: " + unsupported.joined(separator: ", "),
            "error_code": unsupported.isEmpty ? "" : "command_options_unverified",
            "probes": probes, "cache_hits": cacheHits, "cache_hit": false,
            "limitations": source.complete ? [] : ["Dynamic or unsupported shell structure: only the outer shell is bound; child executable resolution and options remain unverified"]]
        let binding = CommandCapabilities.Binding(id: id, created: ProcessInfo.processInfo.systemUptime, actionKey: key, generation: generation,
            suspension: suspension, policy: policy, environment: environment,
            directory: directoryIdentity, shell: shellIdentity,
            tools: tools, source: source, result: result)
        try binding.validate()
        capabilityLock.withLock {
            if commandBindings.count >= CommandCapabilities.maximumBindings { commandBindings.removeAll() }
            commandBindings[id] = binding
        }
        return binding
    }

    private func runCommand(_ action: [String: Any], bindingID: String?) throws -> [String: Any] {
        try TaskOwnership.check()
        commandLock.lock(); commandCancelled = false; commandLock.unlock()
        try Task.checkCancellation()
        let binding: CommandCapabilities.Binding?
        if action["operation"] != nil { binding = nil }
        else if let bindingID {
            guard let owned = capabilityLock.withLock({ commandBindings[bindingID] }) else {
                throw TaskToolError.commandCapability("command_capabilities_changed", "No matching command inspection belongs to this task; inspect again")
            }
            var currentEnvironment = Self.commandEnvironment(); currentEnvironment["PWD"] = owned.policy.workingDirectory.path
            guard try CommandCapabilities.digest(["action": action, "environment": currentEnvironment]) == owned.actionKey else {
                throw TaskToolError.commandCapability("command_capabilities_changed", "The command or environment differs from its inspection; no command was delivered")
            }
            binding = owned
        } else {
            binding = try TaskOwnership.$actionReceipt.withValue(nil) { try prepareCommand(action) }
        }
        if let binding, binding.result["ready"] as? Bool != true {
            throw TaskToolError.commandCapability("command_options_unverified", binding.result["message"] as? String ?? "Inspect the requested command options before execution")
        }
        try binding?.validate()
        var environment = binding?.environment ?? Self.commandEnvironment()
        let policy = try binding?.policy ?? CommandExecutionPolicy(action: action, environment: environment)
        environment["PWD"] = policy.workingDirectory.path
        if binding == nil, let source = policy.shellSource {
            // -n parses the complete source without executing substitutions or
            // earlier statements. -f avoids user startup scripts in both phases.
            let syntax = try executeProcess(executable: policy.executable, arguments: ["-f", "-n", "-c", source],
                                            policy: policy, environment: environment,
                                            prefix: "syntax", timeout: min(5, policy.timeout))
            guard !syntax.timedOut, syntax.status == 0 else {
                throw TaskToolError.invalidAction("Shell syntax check failed before execution: " + syntax.stderr.text)
            }
        }
        let execution = try executeProcess(executable: binding?.executable ?? policy.executable, arguments: binding?.arguments ?? policy.arguments,
                                           policy: policy, environment: environment,
                                           prefix: "command", timeout: policy.timeout,
                                           validate: { try binding?.validate() })
        let checks = policy.checks.map { $0.evaluate(stdout: execution.stdout.text, stdoutTruncated: execution.stdout.truncated) }
        let executed = !execution.timedOut && execution.status == 0
        let verified = executed && !checks.isEmpty && checks.allSatisfy { $0["verified"] as? Bool == true }
        var result: [String: Any] = [
            "action_type": "run_command",
            "message": execution.timedOut
                ? "Command timed out; inspect its effects before retrying"
                : execution.persistent ? "Command launcher finished; explicitly requested background work remains supervised. Parent exit does not establish service readiness."
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
        if let operation = action["operation"] {
            result["command_operation"] = operation
            result["outcome_checks"] = policy.outcomeChecks
        }
        if let binding {
            // This summary proves inspection only, never a requested effect.
            result["command_capabilities"] = binding.result.filter { !["inspection_id"].contains($0.key) }
        }
        return result
    }

    private func executeProcess(executable: URL, arguments: [String], policy: CommandExecutionPolicy,
                                environment: [String: String], prefix: String, timeout: TimeInterval,
                                probe: Bool = false, validate: () throws -> Void = {})
        throws -> (status: Int32, timedOut: Bool, persistent: Bool, stdout: (text: String, truncated: Bool), stderr: (text: String, truncated: Bool)) {
        let process = SubprocessSupervisor()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = policy.workingDirectory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let exit = ProcessExitNotification(process)
        defer { process.terminationHandler = nil }
        let capture: BufferedProcessOutput
        do {
            capture = try BufferedProcessOutput(maximumBytes: Self.maximumCommandOutputBytes,
                combinedLimit: probe ? CommandCapabilities.outputLimit : nil,
                spillRoot: outputSpillRoot, onInterruption: { exit.interrupt(); process.interrupt() })
        } catch {
            throw TaskToolError.operationFailed("Could not prepare command output; the command was not executed")
        }
        var retainedCapture = false
        defer { if !retainedCapture { capture.close() } }
        process.standardOutput = capture.stdout
        process.standardError = capture.stderr
        let lease = TaskOwnership.current
        let revocation = lease?.observeRevocation { exit.interrupt(); process.interrupt() }
        defer { if let revocation { lease?.removeRevocationObserver(revocation) } }

        // Always acquire the ownership gate before the command lock. Pause
        // cannot strand a launcher holding the lock Resume needs.
        func launch() throws {
            try validate()
            try TaskOwnership.commit {
                commandLock.lock(); defer { commandLock.unlock() }
                if commandCancelled { throw CancellationError() }
                do { try BackendTelemetry.current.measure(.commandLaunch, items: arguments.count) { _ in try process.run() } }
                catch { throw TaskToolError.operationFailed("Could not start the command: \(error.localizedDescription)") }
                activeCommand = process
                activeCommandExit = exit
                if commandPaused { process.signal(SIGSTOP) }
            }
        }
        // Resolve identity inside the lease boundary, before receipt dispatch.
        // This catches observed replacement; filesystem actors are not atomic
        // with Process.run and can still race a later child executable lookup.
        if let lease = TaskOwnership.current { try lease.commit { try launch() } }
        else { try launch() }
        capture.closeWriters()
        defer {
            commandLock.lock()
            if activeCommand === process { activeCommand = nil; activeCommandExit = nil }
            commandLock.unlock()
        }
        let deadline = DispatchTime.now() + timeout
        let parentEnded: Bool
        switch exit.wait(until: deadline) {
        case .exited: parentEnded = true
        case .interrupted, .timedOut: parentEnded = false
        }
        commandLock.lock(); let cancelled = commandCancelled; commandLock.unlock()
        let persistent = parentEnded && process.terminationStatus == 0 && prefix == "command" && !probe &&
            lease?.permitsPersistentProcesses == true && process.snapshot.descendants > 0 && !cancelled && !Task.isCancelled
        var timedOut = !parentEnded || capture.statistics.limitExceeded
        if persistent {
            do { try lease?.ownPersistentProcess(process) }
            catch { process.beginTeardown(); _ = process.waitForTree(ignoreInterrupt: true); throw error }
        } else {
            if !timedOut, case .finished = process.waitForTree(until: deadline) { }
            else { timedOut = true }
            if timedOut { process.beginTeardown() }
            // No handoff until descendants (including inherited writers) end.
            _ = process.waitForTree(ignoreInterrupt: true)
        }
        let status = exit.waitForExit()!
        let cancelledAfterWait = commandLock.withLock { commandCancelled }
        if cancelledAfterWait || Task.isCancelled || lease?.state == .draining || lease?.state == .retired {
            if !persistent { process.beginTeardown(); _ = process.waitForTree(ignoreInterrupt: true) }
            throw CancellationError()
        }
        do {
            let output = try capture.finish(keepDraining: persistent)
            if persistent {
                retainedCapture = true
                process.whenTreeExits { capture.close(); process.markOutputDrained() }
            } else { process.markOutputDrained() }
            // A fast exit can precede its last read notification. The final
            // drain still enforces the aggregate help-probe budget.
            timedOut = timedOut || capture.statistics.limitExceeded
            return (status, timedOut, persistent, (output.stdout.text, output.stdout.truncated), (output.stderr.text, output.stderr.truncated))
        } catch {
            if probe || prefix == "syntax" { throw TaskToolError.operationFailed("Preflight output could not be read; the command was not executed") }
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

    private static func signal(_ process: SubprocessSupervisor?, _ signal: Int32) {
        process?.signal(signal)
    }
}
