import XCTest
@testable import OrbitAgent

final class CommandExecutionTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testArgumentArraysKeepPathsLiteralAndVerifyExistence() async throws {
        let root = try fixture()
        let marker = root.appendingPathComponent("unwanted")
        let file = root.appendingPathComponent("spaces 'quotes' $(touch unwanted) `touch unwanted` ; newline\n.txt")
        let result = try await TaskToolExecutor().perform(action: [
            "type": "run_command", "argv": ["/usr/bin/touch", file.path], "working_directory": root.path,
            "checks": [["type": "file_exists", "path": file.path]]
        ])
        XCTAssertEqual(result["execution_method"] as? String, "argument_array")
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual(result["verification_scope"] as? String, "requested_outcomes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLiteralShellQuotingPreservesMetacharactersAndApostrophes() async throws {
        let root = try fixture()
        let value = root.appendingPathComponent("a 'quote' $HOME $(touch unwanted) `touch unwanted`\n.txt").path
        let result = try await TaskToolExecutor().perform(action: [
            "type": "run_command", "command": "printf '%s' " + CommandExecutionPolicy.quoteLiteral(value),
            "working_directory": root.path, "checks": [["type": "stdout_equals", "text": value]]
        ])
        XCTAssertEqual(result["syntax_checked"] as? Bool, true)
        XCTAssertEqual(result["stdout"] as? String, value)
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unwanted").path))
    }

    func testSyntaxPreflightRejectsBeforeAnyStatementOrSubstitutionRuns() async throws {
        let root = try fixture()
        let script = "touch earlier; echo $(touch substitution); if then"
        do {
            _ = try await TaskToolExecutor().perform(action: ["type": "run_command", "command": script, "working_directory": root.path])
            XCTFail("Invalid shell source ran")
        } catch let error as TaskToolError {
            XCTAssertEqual(error.code, "command_syntax")
            XCTAssertTrue(error.localizedDescription.contains("syntax check failed before execution"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testInvalidDirectoriesAndParameterTypesRejectBeforeExecution() async throws {
        let root = try fixture()
        let file = root.appendingPathComponent("ordinary-file")
        try Data().write(to: file)
        let badActions: [[String: Any]] = [
            ["working_directory": "relative"], ["working_directory": root.appendingPathComponent("missing").path],
            ["working_directory": file.path], ["working_directory": false], ["working_directory": "/tmp\0x"],
            ["timeout_seconds": true], ["timeout_seconds": "1"], ["timeout_seconds": Double.infinity],
            ["timeout_seconds": 0.1], ["timeout_seconds": 901],
            ["checks": [["type": "file_contents", "path": file.path]]],
            ["checks": [["type": "file_exists", "path": file.path, "content": "irrelevant"]]],
            ["checks": [["type": "file_exists", "path": "relative"]]], ["checks": []],
            ["argv": ["/bin/echo", true]], ["argv": []], ["argv": ["/missing/executable"]],
            ["argv": ["/bin/echo", "x\0y"]], ["argv": ["/bin/echo"], "command": "true"]
        ]
        for parameters in badActions {
            var action: [String: Any] = ["type": "run_command", "argv": ["/usr/bin/touch", root.appendingPathComponent("unexpected").path], "working_directory": root.path]
            action.merge(parameters) { _, value in value }
            do { _ = try await TaskToolExecutor().perform(action: action); XCTFail("Accepted \(parameters)") }
            catch let error as TaskToolError {
                XCTAssertEqual(error.code, (parameters["argv"] as? [String]) == ["/missing/executable"] ? "command_tool_missing" : "invalid_action")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
    }

    func testSuccessfulExitCannotVerifyMissingOutcome() async throws {
        let root = try fixture()
        let result = try await TaskToolExecutor().perform(action: [
            "type": "run_command", "argv": ["/usr/bin/true"],
            "checks": [["type": "file_exists", "path": root.appendingPathComponent("missing").path]]
        ])
        XCTAssertEqual(result["exit_code"] as? Int, 0)
        XCTAssertEqual(result["verified"] as? Bool, false)
        XCTAssertEqual(result["outcome"] as? String, "delivered_unconfirmed")
    }

    func testExactContentsRejectPrefixesAndSupportBinaryAndEmptyFiles() async throws {
        let root = try fixture()
        let file = root.appendingPathComponent("contents")
        for (bytes, expected, encoding, verified) in [
            (Data("hello extra".utf8), "hello", "utf-8", false),
            (Data("hello".utf8), "hello", "utf-8", true),
            (Data([0, 255, 1]), "AP8B", "base64", true),
            (Data(), "", "utf-8", true)
        ] {
            try bytes.write(to: file)
            let result = try await TaskToolExecutor().perform(action: [
                "type": "run_command", "argv": ["/usr/bin/true"],
                "checks": [["type": "file_contents", "path": file.path, "content": expected, "encoding": encoding]]
            ])
            XCTAssertEqual(result["verified"] as? Bool, verified)
        }
    }

    func testDirectoryAndAbsenceChecksDoNotConfuseFilesOrDanglingLinks() async throws {
        let root = try fixture()
        let missing = root.appendingPathComponent("missing")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        for (kind, path, verified) in [("directory_exists", root.path, true), ("file_exists", root.path, false),
                                       ("path_absent", missing.path, true), ("path_absent", link.path, false)] {
            let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": ["/usr/bin/true"],
                                                                     "checks": [["type": kind, "path": path]]])
            XCTAssertEqual(result["verified"] as? Bool, verified)
        }
    }

    func testNonzeroExitAndTruncatedOutputCannotClaimVerifiedOutcomes() async throws {
        let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "command": "printf exact; exit 2",
                                                                  "checks": [["type": "stdout_equals", "text": "exact"]]])
        XCTAssertEqual(result["verified"] as? Bool, false)
        let large = try await TaskToolExecutor().perform(action: ["type": "run_command", "command": "printf '%65537s' ''",
                                                                 "checks": [["type": "stdout_equals", "text": String(repeating: " ", count: 65536)]]])
        XCTAssertEqual(large["stdout_truncated"] as? Bool, true)
        XCTAssertEqual(large["verified"] as? Bool, false)
    }

    func testArgumentExecutableResolutionUsesValidatedWorkingDirectory() async throws {
        let root = try fixture().appendingPathComponent("folder with spaces")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": ["pwd"], "working_directory": root.path,
                                                                  "checks": [["type": "stdout_equals", "text": root.resolvingSymlinksInPath().path + "\n"]]])
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual(result["working_directory"] as? String, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(result["stdout"] as? String, root.resolvingSymlinksInPath().path + "\n")
    }

    func testCancellationStopsPendingCommandWithoutClaimingSuccess() async throws {
        let executor = TaskToolExecutor()
        let command = Task.detached { try await executor.perform(action: ["type": "run_command", "argv": ["/bin/sleep", "5"]]) }
        try await Task.sleep(nanoseconds: 150_000_000)
        executor.cancelActiveCommand()
        do { _ = try await command.value; XCTFail("Cancelled command returned success") }
        catch is CancellationError { }
    }
}
