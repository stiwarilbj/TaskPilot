import Foundation
import XCTest
@testable import OrbitAgent

final class ExpectedOutcomeTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func verified(_ result: [String: Any]) -> Bool {
        (result["checks"] as? [[String: Any]])?.first?["verified"] as? Bool == true
    }

    func testFileChecksInspectExactContentsAndRejectMatchingPrefixesWithoutWriting() async throws {
        let directory = try fixture(), file = directory.appendingPathComponent("note")
        try Data("wanted suffix".utf8).write(to: file)
        let tools = TaskToolExecutor()
        let wrong = try await tools.checkOutcome(["type": "file_contents", "path": file.path, "content": "wanted"])
        XCTAssertFalse(verified(wrong))
        let exact = try await tools.checkOutcome(["type": "file_contents", "path": file.path, "content": "wanted suffix"])
        XCTAssertTrue(verified(exact))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "wanted suffix")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["note"])
    }

    func testBinaryEmptyExistenceDirectoryAndAbsenceChecks() async throws {
        let directory = try fixture(), file = directory.appendingPathComponent("binary")
        let bytes = Data([0, 255, 10]); try bytes.write(to: file)
        let tools = TaskToolExecutor()
        let binary = try await tools.checkOutcome(["type": "file_contents", "path": file.path, "content": bytes.base64EncodedString(), "encoding": "base64"])
        XCTAssertTrue(verified(binary))
        let exists = try await tools.checkOutcome(["type": "file_exists", "path": file.path])
        let folder = try await tools.checkOutcome(["type": "directory_exists", "path": directory.path])
        let absent = try await tools.checkOutcome(["type": "path_absent", "path": directory.appendingPathComponent("missing").path])
        XCTAssertTrue(verified(exists)); XCTAssertTrue(verified(folder)); XCTAssertTrue(verified(absent))
        try Data().write(to: file)
        let empty = try await tools.checkOutcome(["type": "file_contents", "path": file.path, "content": ""])
        XCTAssertTrue(verified(empty))
    }

    func testInvalidChecksAndCommandParametersReachNoExecutor() async throws {
        let directory = try fixture(), file = directory.appendingPathComponent("untouched")
        let checks: [[String: Any]] = [
            ["type": "file_contents", "path": file.path, "content": 42],
            ["type": "file_contents", "path": file.path, "content": "!", "encoding": "base64"],
            ["type": "file_contents", "path": "relative", "content": ""],
            ["type": "file_contents", "path": file.path, "content": String(repeating: "x", count: 2097153)],
            ["type": "file_exists", "path": file.path, "command": "touch injected"],
            ["type": "stdout_equals", "text": "cannot inspect a running command"]]
        let tools = TaskToolExecutor()
        for check in checks {
            do { _ = try await tools.checkOutcome(check); XCTFail("Invalid standalone check accepted") }
            catch { XCTAssertEqual((error as? TaskToolError)?.code, "invalid_action") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testPrivateBridgeCheckNeedsOwnershipButNoDisplayOrActionReceipt() async throws {
        let directory = try fixture(), file = directory.appendingPathComponent("note")
        try Data("wanted".utf8).write(to: file)
        let lease = TaskLease()
        let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
        try bridge.bind(lease)
        let request: [String: Any] = ["task_generation_id": lease.id, "instruction_revision": 0, "working_document_revision": 0, "request_id": "expected-check", "method": "check_effect",
                                      "params": ["check": ["type": "file_contents", "path": file.path, "content": "wanted"]]]
        let response = await bridge.handleOwned(request, lease: lease)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertTrue(verified(response["result"] as! [String: Any]))
        XCTAssertNil(response["action_receipt"])
        var foreign = request; foreign["task_generation_id"] = UUID().uuidString
        let stale = await bridge.handleOwned(foreign, lease: lease)
        XCTAssertEqual(stale["ok"] as? Bool, false)
        lease.revoke()
        let stopped = await bridge.handleOwned(request, lease: lease)
        XCTAssertEqual(stopped["ok"] as? Bool, false)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "wanted")
    }

    func testGeneratedStandaloneCheckErrorsHavePrecisePaths() throws {
        XCTAssertThrowsError(try ActionContract.validateOutcomeCheck(["type": "file_contents", "path": "/fixture/note", "content": true], path: "expected_result")) { error in
            XCTAssertEqual(error.localizedDescription, "expected_result.content must be a string")
        }
        let value: [String: Any] = ["type": "file_exists", "path": "/fixture/note"]
        XCTAssertEqual(try ActionContract.validateOutcomeCheck(value)["path"] as? String, "/fixture/note")
    }

    func testPrivateDiagnosticsDecodeOlderHistoryWithoutChangingSummary() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let older = try decoder.decode(AgentRequestMetrics.self, from: Data("{\"planning\":1,\"verification\":0,\"retries\":0,\"model_switches\":0,\"cache_hits\":0,\"reconnects\":0}".utf8))
        XCTAssertNil(older.effectChecks); XCTAssertNil(older.verifiedEffects); XCTAssertNil(older.unconfirmedEffects)
        let current = try decoder.decode(AgentRequestMetrics.self, from: Data("{\"planning\":1,\"verification\":0,\"retries\":0,\"model_switches\":0,\"cache_hits\":0,\"reconnects\":0,\"effect_checks\":3,\"verified_effects\":1,\"unconfirmed_effects\":0}".utf8))
        XCTAssertEqual(current.effectChecks, 3); XCTAssertEqual(current.verifiedEffects, 1); XCTAssertEqual(current.unconfirmedEffects, 0)
    }
}
