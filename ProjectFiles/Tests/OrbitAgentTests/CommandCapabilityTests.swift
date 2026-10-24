import Darwin
import XCTest
@testable import OrbitAgent

final class CommandCapabilityTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-capability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func tool(_ root: URL, name: String = "fixture tool", help: String = "printf '%s\\n' 'Options: --help --safe'; exit 0") throws -> URL {
        let path = root.appendingPathComponent(name)
        let source = "#!/bin/sh\nif [ \"$1\" = --help ]; then \(help); fi\nprintf '%s\\n' executed >> \"${0}.executions\"\nif [ -n \"$2\" ]; then /usr/bin/touch \"$2\"; fi\n"
        try Data(source.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }
    private func executor() -> TaskToolExecutor {
        TaskToolExecutor(profileProvider: { _, _ in .init(arguments: ["--help"], context: "fixture", exhaustiveLongOptions: true) })
    }
    private func action(_ executable: URL, _ root: URL, flag: String = "--safe") -> [String: Any] {
        ["type": "run_command", "argv": [executable.path, flag, root.appendingPathComponent("effect").path], "working_directory": root.path,
         "checks": [["type": "file_exists", "path": root.appendingPathComponent("effect").path]]]
    }
    private func rejected(_ executor: TaskToolExecutor, _ action: [String: Any], _ id: String, code: String) async {
        do { _ = try await executor.perform(action: action, commandBindingID: id); XCTFail("Uninspected command ran") }
        catch let error as TaskToolError { XCTAssertEqual(error.code, code) }
        catch { XCTFail("Unexpected error \(error)") }
    }

    func testHealthyInspectionBindsCanonicalToolAndExecutesExactlyOnce() async throws {
        let root = try fixture(), executable = try tool(root), executor = executor(), input = action(executable, root)
        let inspected = try await executor.inspectCommand(action: input)
        XCTAssertEqual(inspected["ready"] as? Bool, true)
        XCTAssertEqual(inspected["probes"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        let result = try await executor.perform(action: input, commandBindingID: inspected["inspection_id"] as? String)
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: executable.path + ".executions")), "executed\n")
        XCTAssertNil((result["command_capabilities"] as? [String: Any])?["inspection_id"])
    }

    func testUnsupportedFlagsRejectBeforeMutationAndReuseHelpForCorrectedFlags() async throws {
        let root = try fixture(), executable = try tool(root), executor = executor()
        let bad = action(executable, root, flag: "--made-up")
        let result = try await executor.inspectCommand(action: bad)
        XCTAssertEqual(result["ready"] as? Bool, false)
        XCTAssertEqual(result["error_code"] as? String, "command_options_unverified")
        await rejected(executor, bad, result["inspection_id"] as! String, code: "command_options_unverified")
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path + ".executions"))
        let good = try await executor.inspectCommand(action: action(executable, root))
        XCTAssertEqual(good["probes"] as? Int, 0)
        XCTAssertEqual(good["cache_hits"] as? Int, 1)
        XCTAssertEqual(good["ready"] as? Bool, true)
        let reused = try await executor.inspectCommand(action: action(executable, root))
        XCTAssertEqual(reused["probes"] as? Int, 0)
        XCTAssertEqual(reused["cache_hits"] as? Int, 0)
        XCTAssertEqual(reused["cache_hit"] as? Bool, true)
    }

    func testUnknownScriptsAreResolvedWithoutInventingAHelpInvocation() async throws {
        let root = try fixture(), executable = try tool(root), executor = TaskToolExecutor(), input = action(executable, root)
        let result = try await executor.inspectCommand(action: input)
        XCTAssertEqual(result["probes"] as? Int, 0)
        XCTAssertEqual((result["tools"] as? [[String: Any]])?.first?["option_status"] as? String, "unverified")
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path + ".executions"))
        _ = try await executor.perform(action: input, commandBindingID: result["inspection_id"] as? String)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: executable.path + ".executions")), "executed\n")
    }

    func testPressureEvictsHelpButPreservesInspectedExecutionAuthority() async throws {
        let monitor = MemoryPressureMonitor(listen: false)
        let root = try fixture(), executable = try tool(root), input = action(executable, root)
        let executor = TaskToolExecutor(profileProvider: { _, _ in
            .init(arguments: ["--help"], context: "fixture", exhaustiveLongOptions: true)
        }, memoryPressure: monitor)
        let inspected = try await executor.inspectCommand(action: input)
        XCTAssertEqual(inspected["probes"] as? Int, 1)
        monitor.receive(.warning)
        let reused = try await executor.inspectCommand(action: input)
        XCTAssertEqual(reused["inspection_id"] as? String, inspected["inspection_id"] as? String)
        XCTAssertEqual(reused["cache_hit"] as? Bool, true)
        let other = try await executor.inspectCommand(action: action(executable, root, flag: "--other"))
        XCTAssertEqual(other["probes"] as? Int, 1)
        XCTAssertEqual(other["cache_hits"] as? Int, 0)
        monitor.receive(.critical)
        _ = try await executor.perform(action: input, commandBindingID: inspected["inspection_id"] as? String)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: executable.path + ".executions")), "executed\n")
    }

    func testPressureDuringHelpProbePreventsLateCacheRefill() async throws {
        let monitor = MemoryPressureMonitor(listen: false), root = try fixture()
        let executable = try tool(root, help: "touch \"${0}.probing\"; sleep 0.15; printf '%s\\n' 'Options: --help --safe'; exit 0")
        let executor = TaskToolExecutor(profileProvider: { _, _ in
            .init(arguments: ["--help"], context: "fixture", exhaustiveLongOptions: true)
        }, memoryPressure: monitor)
        let input = action(executable, root)
        let pending = Task.detached { try await executor.inspectCommand(action: input) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: executable.path + ".probing"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path + ".probing"))
        monitor.receive(.critical)
        let inspected = try await pending.value
        XCTAssertEqual(inspected["ready"] as? Bool, true)
        let other = try await executor.inspectCommand(action: action(executable, root, flag: "--other"))
        XCTAssertEqual(other["probes"] as? Int, 1)
        XCTAssertEqual(other["cache_hits"] as? Int, 0)
        _ = try await executor.perform(action: input, commandBindingID: inspected["inspection_id"] as? String)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: executable.path + ".executions")), "executed\n")
    }

    func testChangedCommandAndWorkingDirectoryCannotBorrowABinding() async throws {
        let root = try fixture(), executable = try tool(root), executor = executor(), input = action(executable, root)
        let id = try await executor.inspectCommand(action: input)["inspection_id"] as! String
        var changed = input; changed["argv"] = [executable.path, "--help"]
        await rejected(executor, changed, id, code: "command_capabilities_changed")
        changed = input; changed["working_directory"] = FileManager.default.temporaryDirectory.path
        await rejected(executor, changed, id, code: "command_capabilities_changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
    }

    func testReplacementAndSymlinkRetargetingRejectBeforeExecution() async throws {
        let root = try fixture(), executable = try tool(root), executor = executor()
        let link = root.appendingPathComponent("selected")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let input = action(link, root)
        let id = try await executor.inspectCommand(action: input)["inspection_id"] as! String
        let other = try tool(root, name: "other")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        await rejected(executor, input, id, code: "command_capabilities_changed")
        let fresh = try await executor.inspectCommand(action: action(other, root))["inspection_id"] as! String
        try Data("#!/bin/sh\nexit 7\n".utf8).write(to: other, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
        await rejected(executor, action(other, root), fresh, code: "command_capabilities_changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
    }

    func testGenerationAndPauseResumeInvalidateExecutionAuthority() async throws {
        let root = try fixture(), executable = try tool(root), executor = executor(), input = action(executable, root)
        let lease = TaskLease()
        let id = try await TaskOwnership.$current.withValue(lease) { try await executor.inspectCommand(action: input)["inspection_id"] as! String }
        lease.pause(); lease.resume()
        await TaskOwnership.$current.withValue(lease) { await rejected(executor, input, id, code: "command_capabilities_changed") }
        await TaskOwnership.$current.withValue(TaskLease()) { await rejected(executor, input, id, code: "command_capabilities_changed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
    }

    func testEnvironmentChangesAndWorkingDirectorySymlinkRetargetingReject() async throws {
        let variable = "TASKPILOT_CAPABILITY_FIXTURE_ENV"
        let previous = ProcessInfo.processInfo.environment[variable]
        defer { if let previous { setenv(variable, previous, 1) } else { unsetenv(variable) } }
        let root = try fixture(), executable = try tool(root), executor = executor(), input = action(executable, root)
        setenv(variable, "first", 1)
        let id = try await executor.inspectCommand(action: input)["inspection_id"] as! String
        setenv(variable, "second", 1)
        await rejected(executor, input, id, code: "command_capabilities_changed")
        let alternate = root.appendingPathComponent("alternate"), link = root.appendingPathComponent("cwd")
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let aliased = action(executable, link)
        let fresh = try await executor.inspectCommand(action: aliased)["inspection_id"] as! String
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: alternate)
        await rejected(executor, aliased, fresh, code: "command_capabilities_changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.appendingPathComponent("effect").path))
    }

    func testMultipleToolsShareOneProbeDeadlineAndUnusableHelpDoesNotRejectRealFlags() async throws {
        let root = try fixture(), executor = executor()
        let tools = try (0..<5).map { try tool(root, name: "tool-\($0)", help: "/bin/sleep 0.6; printf '%s\\n' '--help --safe'; exit 0") }
        let source = tools.map { CommandExecutionPolicy.quoteLiteral($0.path) + " --safe" }.joined(separator: "; ")
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await executor.inspectCommand(action: ["type": "run_command", "command": source, "working_directory": root.path])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        XCTAssertLessThan(result["probes"] as! Int, tools.count)
        XCTAssertTrue(tools.allSatisfy { !FileManager.default.fileExists(atPath: $0.path + ".executions") })
        let badHelp = try tool(root, name: "unsupported-help", help: "printf '%s\\n' 'unknown option --help'; exit 0")
        let unverified = try await executor.inspectCommand(action: action(badHelp, root, flag: "--another-real-flag"))
        XCTAssertEqual(unverified["ready"] as? Bool, true)
        XCTAssertEqual((unverified["tools"] as! [[String: Any]])[0]["option_status"] as? String, "unverified")
    }

    func testLiteralPipelineBindsHeadsAndPreservesOperands() async throws {
        let root = try fixture(), executable = try tool(root), executor = executor()
        let text = "literal ' $() ; ` ${HOME}"
        let source = "printf '%s' " + CommandExecutionPolicy.quoteLiteral(text) + " | /bin/cat"
        let input: [String: Any] = ["type": "run_command", "command": source, "working_directory": root.path,
                                  "checks": [["type": "stdout_equals", "text": text]]]
        let inspected = try await executor.inspectCommand(action: input)
        XCTAssertEqual(inspected["resolution_complete"] as? Bool, true)
        let result = try await executor.perform(action: input, commandBindingID: inspected["inspection_id"] as? String)
        XCTAssertEqual(result["stdout"] as? String, text)
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path + ".executions"))
    }

    func testOptionValuesBeginningWithDashesAreNotMistakenForFlags() async throws {
        let help = "-g, --glob <GLOB>  Match pattern\n  --arg name value  Bind a value\n  --help  Show help\n"
        let values = CommandCapabilities.valueOptions(help)
        XCTAssertEqual(values["--glob"], 1)
        XCTAssertEqual(values["-g"], 1)
        XCTAssertEqual(values["--arg"], 2)
        XCTAssertEqual(CommandCapabilities.requestedLongOptions(["-g", "--literal-name", "--arg", "name", "--another-value", "--help"], takingValues: values), ["--arg", "--help"])
        let root = try fixture(), executable = try tool(root, help: "printf '%s\\n' '-g, --glob <GLOB>' '  --arg name value' '--help'; exit 0")
        let input: [String: Any] = ["type": "run_command", "argv": [executable.path, "--glob", "--literal-name", "--arg", "name", "--another-value"], "working_directory": root.path]
        let result = try await executor().inspectCommand(action: input)
        XCTAssertEqual(result["ready"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path + ".executions"))
        // Real help catalogs may omit accepted aliases/negations.
        XCTAssertEqual(CommandCapabilities.profile(path: "/usr/bin/curl", arguments: ["--no-location"])?.exhaustiveLongOptions, false)
        XCTAssertEqual(CommandCapabilities.profile(path: "/opt/homebrew/bin/jq", arguments: [])?.exhaustiveLongOptions, false)
    }

    func testShellBuiltinsRetainTheirMeaningAndInlinePathUsesItsOwnTool() async throws {
        let root = try fixture(), executor = executor()
        let builtin: [String: Any] = ["type": "run_command", "command": "which /bin/cat", "working_directory": root.path,
                                    "checks": [["type": "stdout_equals", "text": "/bin/cat\n"]]]
        let inspected = try await executor.inspectCommand(action: builtin)
        XCTAssertEqual(inspected["resolution_complete"] as? Bool, false)
        XCTAssertEqual(inspected["probes"] as? Int, 0)
        XCTAssertTrue((inspected["tools"] as! [[String: Any]]).isEmpty)
        let result = try await executor.perform(action: builtin, commandBindingID: inspected["inspection_id"] as? String)
        XCTAssertEqual(result["verified"] as? Bool, true)

        let executable = try tool(root, name: "taskpilot-inline-path")
        let source = "PATH=" + CommandExecutionPolicy.quoteLiteral(root.path) + " taskpilot-inline-path --safe " + CommandExecutionPolicy.quoteLiteral(root.appendingPathComponent("effect").path)
        let input: [String: Any] = ["type": "run_command", "command": source, "working_directory": root.path,
                                  "checks": [["type": "file_exists", "path": root.appendingPathComponent("effect").path]]]
        let binding = try await executor.inspectCommand(action: input)
        XCTAssertEqual(binding["resolution_complete"] as? Bool, true)
        XCTAssertEqual((binding["tools"] as! [[String: Any]])[0]["executable"] as? String, executable.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        let executed = try await executor.perform(action: input, commandBindingID: binding["inspection_id"] as? String)
        XCTAssertEqual(executed["verified"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: executable.path + ".executions")), "executed\n")
    }

    func testMissingToolAndSyntaxFailureCannotDispatchAnEarlierStatementOrReceipt() async throws {
        let root = try fixture(), executor = TaskToolExecutor(), lease = TaskLease()
        let marker = root.appendingPathComponent("effect")
        for source in ["/usr/bin/touch " + CommandExecutionPolicy.quoteLiteral(marker.path) + "; /missing/taskpilot-tool --flag", "touch effect; if then"] {
            let token: ActionReceiptStore.Token
            switch try lease.actionReceipts.begin(id: UUID().uuidString, payload: ["source": source]) {
            case .new(let value): token = value
            case .existing: fatalError()
            }
            let input: [String: Any] = ["type": "run_command", "command": source, "working_directory": root.path]
            let result = try await TaskOwnership.$current.withValue(lease) {
                try await TaskOwnership.$actionReceipt.withValue(token) { try await executor.inspectCommand(action: input) }
            }
            XCTAssertEqual(result["ready"] as? Bool, false)
            XCTAssertEqual(token.receipt["state"] as? String, "pending")
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testProbeOutputAndTimeAreBoundedAndIncompleteHelpIsNeverAnOptionClaim() async throws {
        let root = try fixture(), executor = executor()
        for help in ["/bin/sleep 5; exit 0", "while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done"] {
            let executable = try tool(root, name: UUID().uuidString, help: help)
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await executor.inspectCommand(action: action(executable, root))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2.5)
            let summary = (result["tools"] as! [[String: Any]])[0]
            XCTAssertEqual(summary["option_status"] as? String, "unverified")
            XCTAssertEqual(summary["complete_option_list"] as? Bool, false)
            XCTAssertLessThanOrEqual((summary["help_excerpt"] as? String)?.count ?? 0, 1800)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        }
    }

    func testStopDuringHelpProbeProducesNoBindingOrAction() async throws {
        let root = try fixture(), executable = try tool(root, help: "/bin/sleep 5; exit 0"), executor = executor(), lease = TaskLease()
        let pending = Task { try await TaskOwnership.$current.withValue(lease) { try await executor.inspectCommand(action: action(executable, root)) } }
        try await Task.sleep(for: .milliseconds(100))
        lease.revoke(); executor.cancelActiveCommand()
        do { _ = try await pending.value; XCTFail("Revoked probe returned execution authority") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
    }

    func testDynamicSourceHasExplicitLimitsAndNeverManufacturesAnExecutable() throws {
        let environment = TaskToolExecutor.commandEnvironment()
        for source in ["$tool --flag", "echo $(/bin/pwd)", "for f in *; do /bin/echo $f; done", "cd /tmp; ./tool --flag", "PATH=/tmp; ./tool --flag", "PATH=relative /bin/cat", "\\~/bin/cat --help", "cat <<EOF\nliteral data\nEOF"] {
            let policy = try CommandExecutionPolicy(action: ["type": "run_command", "command": source], environment: environment)
            let parsed = CommandCapabilities.source(policy)
            XCTAssertFalse(parsed.complete)
            XCTAssertTrue(parsed.invocations.isEmpty)
            XCTAssertNil(parsed.binding(parsed.invocations.map(\.name)))
        }
        XCTAssertEqual(CommandCapabilities.requestedLongOptions(["--safe=x", "--", "--literal-path"]), ["--safe"])
        XCTAssertNil(CommandCapabilities.profile(path: "/tmp/curl", arguments: ["--help"]))
        XCTAssertEqual(CommandCapabilities.profile(path: "/usr/bin/git", arguments: ["status", "--porcelain"])?.arguments,
                       ["--no-pager", "status", "-h"])
        XCTAssertEqual(CommandCapabilities.profile(path: "/usr/bin/git", arguments: ["-C", "/fixture", "status"])?.arguments,
                       ["--no-pager", "-C", "/fixture", "status", "-h"])
        XCTAssertEqual(CommandCapabilities.shortOptions("Options: -a, -B and --not-a-short-flag"), ["-a", "-B"])
        let quoted = try CommandExecutionPolicy(action: ["type": "run_command", "command": "\"/tmp/literal\\ path\""], environment: environment)
        XCTAssertEqual(CommandCapabilities.source(quoted).invocations.first?.name, "/tmp/literal\\ path")
    }

    func testBridgeInspectionIsTaskScopedAndDoesNotNeedADisplay() async throws {
        let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
        let lease = TaskLease(); try bridge.bind(lease)
        let request: [String: Any] = ["task_generation_id": lease.id, "instruction_revision": 0, "method": "inspect_command", "request_id": "probe",
                                     "params": ["action": ["type": "run_command", "argv": ["/usr/bin/true"]]]]
        let result = await bridge.handleOwned(request, lease: lease)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual((result["result"] as? [String: Any])?["ready"] as? Bool, true)
        XCTAssertNil(result["action_receipt"])
        var foreign = request; foreign["task_generation_id"] = TaskLease().id
        let rejected = await bridge.handleOwned(foreign, lease: lease)
        XCTAssertEqual(rejected["error_code"] as? String, "cancelled")
    }

    func testInspectionDiagnosticsDecodeOldHistoryAndPersistOnlyCounts() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let base = "\"planning\":1,\"verification\":0,\"retries\":0,\"model_switches\":0,\"cache_hits\":0,\"reconnects\":0"
        let old = try decoder.decode(AgentRequestMetrics.self, from: Data(("{" + base + "}").utf8))
        XCTAssertNil(old.commandInspections); XCTAssertNil(old.commandProbes)
        let current = try decoder.decode(AgentRequestMetrics.self, from: Data(("{" + base + ",\"command_inspections\":2,\"command_probes\":1,\"command_probe_cache_hits\":1,\"command_preflight_rejections\":1}").utf8))
        XCTAssertEqual(current.commandInspections, 2); XCTAssertEqual(current.commandProbes, 1)
        XCTAssertEqual(current.commandProbeCacheHits, 1); XCTAssertEqual(current.commandPreflightRejections, 1)
        XCTAssertEqual(old.summary, current.summary)
        let encoded = String(decoding: try JSONEncoder().encode(current), as: UTF8.self)
        XCTAssertFalse(encoded.contains("inspection_id")); XCTAssertFalse(encoded.contains("help_excerpt"))
    }
}
