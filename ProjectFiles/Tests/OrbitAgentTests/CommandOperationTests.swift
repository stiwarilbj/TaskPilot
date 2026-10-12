import XCTest
@testable import OrbitAgent

final class CommandOperationTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-operation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func action(_ kind: String, _ parameters: [String: Any]) -> [String: Any] {
        ["type": "run_command", "operation": parameters.merging(["type": kind]) { _, value in value }]
    }

    func testEachGeneratedRecipeCompilesIdempotentlyAndRetainsRequiredChecks() throws {
        for recipe in (ActionContract.definition["command_operations"] as! [String: [String: Any]]).values {
            let input: [String: Any] = ["type": "run_command", "operation": recipe["example"]!]
            let compiled = try ActionContract.validate(input)
            XCTAssertTrue((compiled["argv"] as! [String])[0].hasPrefix("/"))
            XCTAssertFalse((compiled["checks"] as! [Any]).isEmpty)
            XCTAssertTrue(NSDictionary(dictionary: compiled).isEqual(to: try ActionContract.validate(compiled)))
        }
        var value = action("create_directory", ["path": "/fixture/folder"])
        value["checks"] = [["type": "path_absent", "path": "/fixture/other"], ["type": "path_absent", "path": "/fixture/other"]]
        XCTAssertEqual((try ActionContract.validate(value)["checks"] as! [Any]).count, 2)
    }

    func testDirectoryAndTextOperationsUseLiteralArgumentsAndExactOutcomes() async throws {
        let root = try fixture(), executor = TaskToolExecutor()
        let name = "-n 'quotes' $(touch bad) `touch bad`; newline\n"
        let folder = root.appendingPathComponent(name).appendingPathComponent("child")
        let made = try await executor.perform(action: action("create_directory", ["path": folder.path]))
        XCTAssertEqual(made["verified"] as? Bool, true)
        XCTAssertEqual(made["execution_method"] as? String, "argument_array")
        let text = "%n $HOME $(touch bad) `touch bad`\n"
        let printed = try await executor.perform(action: action("print_text", ["text": text]))
        XCTAssertEqual(printed["stdout"] as? String, text)
        XCTAssertEqual(printed["verified"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
    }

    func testCopyAndMoveSnapshotExactEmptyTextAndBinaryContents() async throws {
        let root = try fixture(), executor = TaskToolExecutor()
        for bytes in [Data(), Data("literal text\n".utf8), Data([0, 255, 1, 127])] {
            for kind in ["copy_file", "move_file"] {
                let source = root.appendingPathComponent("source 'quote' $(touch bad) \(UUID().uuidString)")
                let destination = root.appendingPathComponent("destination -n \(UUID().uuidString)")
                try bytes.write(to: source)
                let result = try await executor.perform(action: action(kind, ["source": source.path, "destination": destination.path]))
                XCTAssertEqual(result["verified"] as? Bool, true, kind)
                XCTAssertEqual(try Data(contentsOf: destination), bytes)
                XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), kind == "copy_file")
                let checks = result["outcome_checks"] as! [[String: Any]]
                let snapshot = try XCTUnwrap(checks.first { $0["type"] as? String == "file_contents" })
                XCTAssertEqual(snapshot["path"] as? String, destination.path)
                XCTAssertEqual(Data(base64Encoded: snapshot["content"] as! String), bytes)
                var bound = try ActionContract.validate(action(kind, ["source": source.path, "destination": destination.path]))
                bound["checks"] = checks
                let readback = try await executor.recheck(action: bound)
                XCTAssertTrue((readback["checks"] as! [[String: Any]]).allSatisfy { $0["verified"] as? Bool == true })
                try Data("different".utf8).write(to: destination)
                let changed = try await executor.recheck(action: bound)
                XCTAssertTrue((changed["checks"] as! [[String: Any]]).contains { $0["verified"] as? Bool == false })
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
    }

    func testExistingDestinationsAndSymbolicSourcesRejectBeforeCopyingOrMoving() async throws {
        let root = try fixture(), executor = TaskToolExecutor(), source = root.appendingPathComponent("source")
        try Data("original".utf8).write(to: source)
        let destinations = [root.appendingPathComponent("file"), root.appendingPathComponent("folder"), root.appendingPathComponent("dangling")]
        try Data("keep".utf8).write(to: destinations[0])
        try FileManager.default.createDirectory(at: destinations[1], withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: destinations[2], withDestinationURL: root.appendingPathComponent("missing"))
        for kind in ["copy_file", "move_file"] {
            for destination in destinations {
                do { _ = try await executor.perform(action: action(kind, ["source": source.path, "destination": destination.path])); XCTFail("Overwrote a destination") }
                catch let error as TaskToolError { XCTAssertEqual(error.code, "invalid_action") }
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: destinations[0]), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinations[1].path), [])
        let link = root.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do { _ = try await executor.perform(action: action("copy_file", ["source": link.path, "destination": root.appendingPathComponent("copy").path])); XCTFail("Followed a symbolic source") }
        catch let error as TaskToolError { XCTAssertEqual(error.code, "invalid_action") }
    }

    func testRemovalNeverRecursesOrDeletesSymbolicLinksAndEmptyDirectoryChecksAreExact() async throws {
        let root = try fixture(), executor = TaskToolExecutor(), file = root.appendingPathComponent("file")
        let folder = root.appendingPathComponent("folder"), link = root.appendingPathComponent("link")
        try Data("keep".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for path in [folder.path, link.path] {
            do { _ = try await executor.perform(action: action("remove_file", ["path": path])); XCTFail("Removed a nonregular file") }
            catch let error as TaskToolError { XCTAssertEqual(error.code, "invalid_action") }
        }
        let child = folder.appendingPathComponent("child"); try Data().write(to: child)
        let nonempty = try await executor.perform(action: action("remove_empty_directory", ["path": folder.path]))
        XCTAssertEqual(nonempty["verified"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
        try FileManager.default.removeItem(at: child)
        let removedFolder = try await executor.perform(action: action("remove_empty_directory", ["path": folder.path]))
        let removedFile = try await executor.perform(action: action("remove_file", ["path": file.path]))
        let alreadyAbsent = try await executor.perform(action: action("remove_file", ["path": file.path]))
        for result in [removedFolder, removedFile, alreadyAbsent] { XCTAssertEqual(result["verified"] as? Bool, true) }
    }

    func testOversizedSourcesRejectBeforeMutationAndGeneralArgumentsRemainAvailable() async throws {
        let root = try fixture(), source = root.appendingPathComponent("large"), destination = root.appendingPathComponent("copy")
        try Data(repeating: 42, count: TaskToolExecutor.maximumReadBytes + 1).write(to: source)
        let executor = TaskToolExecutor()
        do { _ = try await executor.perform(action: action("copy_file", ["source": source.path, "destination": destination.path])); XCTFail("Copied an unbounded source") }
        catch let error as TaskToolError { XCTAssertTrue(error.localizedDescription.contains("at most")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let ordinary = try await executor.perform(action: ["type": "run_command", "argv": ["/bin/cp", "-n", source.path, destination.path],
                                                          "checks": [["type": "file_exists", "path": destination.path]]])
        XCTAssertEqual(ordinary["verified"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: destination))
    }

    func testWrongFlagsParametersAndForeignTaskCannotReachCommandExecution() async throws {
        let root = try fixture(), marker = root.appendingPathComponent("marker"), executor = TaskToolExecutor()
        var wrong = action("create_directory", ["path": marker.path]); wrong["argv"] = ["/usr/bin/touch", marker.path]
        for input in [wrong, action("create_directory", ["path": true]), action("copy_file", ["source": marker.path]),
                      action("remove_file", ["path": root.path, "recursive": true])] {
            do { _ = try await executor.perform(action: input); XCTFail("Invalid operation executed") }
            catch let error as TaskToolError { XCTAssertEqual(error.code, "invalid_action") }
        }
        let lease = TaskLease(); lease.revoke()
        do { _ = try await TaskOwnership.$current.withValue(lease) { try await executor.perform(action: action("create_directory", ["path": marker.path])) }; XCTFail("Retired task executed") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
