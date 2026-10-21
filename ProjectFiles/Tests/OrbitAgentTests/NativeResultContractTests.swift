import Foundation
import XCTest
@testable import OrbitAgent

final class NativeResultContractTests: XCTestCase {
    func testSharedNativeProtocolCorpus() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-result-cases.json")
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        for entry in corpus["cases"] as! [[String: Any]] {
            let name = entry["name"] as! String, schema = entry["schema"] as! String
            let value = entry["value"] as! [String: Any], action = entry["action"] as? [String: Any]
            do {
                switch schema {
                case "action_result": try ActionContract.validateNativeResult(value, action: action)
                case "readback": try ActionContract.validateNativeReadback(value, action: action!)
                case "receipt": try ActionContract.validateNativeReceipt(value, actionID: entry["action_id"] as? String, action: action)
                case "check_batch": try ActionContract.validateCheckBatch(value)
                case "evidence": try ActionContract.validateNativeEvidence(value)
                default: try ActionContract.validateNativePayload(schema, value)
                }
                XCTAssertNil(entry["error"], name)
            } catch let error as ActionContract.NativeProtocolError {
                XCTAssertEqual(error.message, entry["error"] as? String, name)
            } catch { XCTFail("Unexpected error for \(name): \(error)") }
        }
    }

    func testMalformedResultsNeverConfirmAndPostDispatchErrorsKeepUncertainty() throws {
        for dispatched in [false, true] {
            let store = ActionReceiptStore(generation: UUID().uuidString), id = UUID().uuidString
            let action: [String: Any] = ["type": "focus", "element_id": "fixture:field"]
            guard case .new(let token) = try store.begin(id: id, payload: action) else { return XCTFail("No receipt") }
            if dispatched { try token.dispatched() }
            for malformed in [["message": "accepted"], ["outcome": "verified"],
                              ["action_type": "focus", "outcome": "verified", "verified": false, "verification_scope": "focus"]] as [[String: Any]] {
                XCTAssertThrowsError(try token.complete(malformed)) { XCTAssertTrue($0 is ActionContract.NativeProtocolError) }
                XCTAssertEqual(token.receipt["terminal"] as? Bool, false)
                XCTAssertNil(token.receipt["result"])
            }
            token.fail(ActionContract.NativeProtocolError(message: "result.verified is required"), code: "protocol_error")
            XCTAssertEqual(token.receipt["state"] as? String, dispatched ? "unconfirmed" : "rejected")
            XCTAssertEqual(token.receipt["error_code"] as? String, "protocol_error")
            try ActionContract.validateNativeReceipt(token.receipt, actionID: id, action: action)
            guard case .existing = try store.begin(id: id, payload: action) else { return XCTFail("Malformed reply authorized replay") }
        }
    }

    func testActualNativeFileAndCommandResultsMatchContractWithoutDesktopAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("proof").path, tool = TaskToolExecutor()
        let write: [String: Any] = ["type": "write_file", "path": path, "content": "Exact\n"]
        let read: [String: Any] = ["type": "read_file", "path": path, "max_bytes": 2]
        let command: [String: Any] = ["type": "run_command", "argv": ["/usr/bin/printf", "Exact"],
                                    "checks": [["type": "stdout_equals", "text": "Exact"]]]
        for action in [write, read, command] {
            try ActionContract.validateNativeResult(try await tool.perform(action: action), action: action)
        }
        try ActionContract.validateCheckBatch(try await tool.recheck(action: write))
        try Data("changed".utf8).write(to: URL(fileURLWithPath: path))
        let changed = try await tool.recheck(action: write)
        try ActionContract.validateCheckBatch(changed)
        XCTAssertEqual(changed["outcome"] as? String, "delivered_unconfirmed")
        XCTAssertEqual(changed["verified"] as? Bool, false)
    }
}
