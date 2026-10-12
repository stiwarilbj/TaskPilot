import CryptoKit
import XCTest
@testable import OrbitAgent

final class EvidenceReadbackTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testWriteAndReadEvidenceHashesExactBytesIncludingEmptyAndBinary() async throws {
        let root = try fixture(), tools = TaskToolExecutor()
        for bytes in [Data(), Data(" A\n".utf8), Data([0, 255, 128, 1])] {
            let file = root.appendingPathComponent(UUID().uuidString)
            let written = try await tools.perform(action: ["type": "write_file", "path": file.path,
                                                          "content": bytes.base64EncodedString(), "encoding": "base64"])
            let read = try await tools.perform(action: ["type": "read_file", "path": file.path])
            XCTAssertEqual(written["content_sha256"] as? String, hash(bytes))
            XCTAssertEqual(read["content_sha256"] as? String, hash(bytes))
            XCTAssertEqual(read["truncated"] as? Bool, false)
        }
    }

    func testReadbackRejectsChangedContentsWithoutReplayingWrite() async throws {
        let file = try fixture().appendingPathComponent("result"), tools = TaskToolExecutor()
        let action: [String: Any] = ["type": "write_file", "path": file.path, "content": "original"]
        _ = try await tools.perform(action: action)
        try Data("changed".utf8).write(to: file)
        let result = try await tools.recheck(action: action)
        XCTAssertEqual((result["checks"] as? [[String: Any]])?.first?["verified"] as? Bool, false)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
    }

    func testReadbackVerifiesLargeExactContentsAndRejectsMatchingPrefix() async throws {
        let file = try fixture().appendingPathComponent("large"), tools = TaskToolExecutor()
        let content = String(repeating: "A", count: TaskToolExecutor.maximumReadBytes + 100)
        let action: [String: Any] = ["type": "write_file", "path": file.path, "content": content]
        _ = try await tools.perform(action: action)
        let read = try await tools.perform(action: ["type": "read_file", "path": file.path])
        XCTAssertEqual(read["truncated"] as? Bool, true)
        let checked = try await tools.recheck(action: action)
        let first = (checked["checks"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["verified"] as? Bool, true)
        XCTAssertEqual(first?["content_sha256"] as? String, hash(Data(content.utf8)))
        try Data((content + "extra").utf8).write(to: file)
        let changed = try await tools.recheck(action: action)
        XCTAssertEqual((changed["checks"] as? [[String: Any]])?.first?["verified"] as? Bool, false)
    }

    func testCommandReadbackNeverRunsOriginalCommandAndIgnoresHistoricalStdout() async throws {
        let root = try fixture(), file = root.appendingPathComponent("result"), marker = root.appendingPathComponent("must-not-run")
        try Data("A".utf8).write(to: file)
        let result = try await TaskToolExecutor().recheck(action: ["type": "run_command",
            "argv": ["/usr/bin/touch", marker.path], "checks": [
                ["type": "file_contents", "path": file.path, "content": "A"],
                ["type": "stdout_equals", "text": "old output"]]])
        let checks = result["checks"] as? [[String: Any]]
        XCTAssertEqual(checks?.count, 1)
        XCTAssertEqual(checks?.first?["verified"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(result["exit_code"])
    }

    func testEveryCommandCheckRetainsItsOwnEvidenceScope() async throws {
        let root = try fixture(), file = root.appendingPathComponent("a")
        try Data("A".utf8).write(to: file)
        let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": ["/usr/bin/printf", "A"],
            "checks": [["type": "file_contents", "path": file.path, "content": "A"],
                       ["type": "file_exists", "path": root.appendingPathComponent("missing").path],
                       ["type": "stdout_equals", "text": "A"]]])
        let checks = result["checks"] as! [[String: Any]]
        XCTAssertEqual(result["verified"] as? Bool, false)
        XCTAssertEqual(checks[0]["content_sha256"] as? String, hash(Data("A".utf8)))
        XCTAssertEqual(checks[1]["verified"] as? Bool, false)
        XCTAssertNil(checks[1]["content_sha256"])
        XCTAssertEqual(checks[2]["text_sha256"] as? String, hash(Data("A".utf8)))
    }

    func testReadbackRejectsInvalidPayloadAndHistoricalAppendWithoutEffects() async throws {
        let file = try fixture().appendingPathComponent("a"), tools = TaskToolExecutor()
        let invalid: [[String: Any]] = [
            ["type": "write_file", "path": file.path, "content": true],
            ["type": "write_file", "path": file.path, "content": "A", "mode": "append"],
            ["type": "run_command", "argv": ["/usr/bin/touch", file.path], "checks": [["type": "file_contents", "path": file.path]]],
            ["type": "press", "element_id": "unobserved"]
        ]
        for action in invalid {
            do { _ = try await tools.recheck(action: action); XCTFail("Invalid readback accepted") }
            catch { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        }
    }

    func testRevokedTaskCannotReadBackOrPublishEvidence() async throws {
        let lease = TaskLease(); lease.revoke()
        do {
            _ = try await TaskOwnership.$current.withValue(lease) {
                try await TaskToolExecutor().recheck(action: ["type": "read_file", "path": "/unobserved"])
            }
            XCTFail("A revoked task acquired evidence")
        } catch is CancellationError { }
    }

    func testPrivateEvidenceCountsDecodeWithoutChangingOldDiagnostics() throws {
        let legacy = Data("{\"planning\":1,\"verification\":0,\"retries\":0,\"modelSwitches\":0,\"cacheHits\":0,\"reconnects\":0}".utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentRequestMetrics.self, from: legacy).evidenceChecks)
        let current = Data("{\"planning\":1,\"verification\":1,\"retries\":0,\"modelSwitches\":0,\"cacheHits\":0,\"reconnects\":0,\"evidenceChecks\":2,\"coverageRejections\":1,\"requirementsProven\":3}".utf8)
        let result = try JSONDecoder().decode(AgentRequestMetrics.self, from: current)
        XCTAssertEqual(result.evidenceChecks, 2)
        XCTAssertEqual(result.coverageRejections, 1)
        XCTAssertEqual(result.requirementsProven, 3)
    }
}
