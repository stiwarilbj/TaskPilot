import Foundation
import XCTest
@testable import OrbitAgent

final class ActionReceiptTests: XCTestCase {
    private static let focused: [String: Any] = ["action_type": "focus", "outcome": "verified", "verified": true, "verification_scope": "focus"]
    private static let unconfirmed: [String: Any] = ["action_type": "press", "outcome": "delivered_unconfirmed", "verified": false, "verification_scope": "delivery_only"]
    private let payload: [String: Any] = ["action": ["type": "focus", "element_id": "fixture:send"]]
    private func token(_ lease: TaskLease, id: String, payload: [String: Any]) throws -> ActionReceiptStore.Token {
        switch try lease.commit({ try lease.actionReceipts.begin(id: id, payload: payload) }) {
        case .new(let token): return token
        case .existing: throw ActionReceiptStore.ReceiptError(code: "fixture", message: "Expected new work")
        }
    }
    private func bridge(_ lease: TaskLease) throws -> AgentAutomationBridge {
        let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
        try bridge.bind(lease)
        return bridge
    }

    func testConcurrentDuplicateClaimsDeliverOnlyOnce() async throws {
        let lease = TaskLease(), id = UUID().uuidString, payload = self.payload
        let deliveries = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    switch try lease.commit({ try lease.actionReceipts.begin(id: id, payload: payload) }) {
                    case .new(let token):
                        let count = try TaskOwnership.$current.withValue(lease) {
                            try TaskOwnership.$actionReceipt.withValue(token) {
                                try TaskOwnership.commit { 1 }
                            }
                        }
                        try token.complete(Self.focused)
                        return count
                    case .existing: return 0
                    }
                }
            }
            var count = 0
            for try await delivered in group { count += delivered }
            return count
        }
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(lease.actionReceipts.duplicateCount, 49)
        XCTAssertEqual(lease.actionReceipts.lookup(id)["state"] as? String, "confirmed")
    }

    func testReceiptIsDispatchedInsideAtomicDeliveryBoundary() throws {
        let lease = TaskLease(), id = UUID().uuidString
        let receipt = try token(lease, id: id, payload: payload)
        XCTAssertEqual(receipt.receipt["state"] as? String, "pending")
        try TaskOwnership.$current.withValue(lease) {
            try TaskOwnership.$actionReceipt.withValue(receipt) {
                try TaskOwnership.commit {
                    XCTAssertEqual(receipt.receipt["state"] as? String, "dispatched")
                    XCTAssertEqual(receipt.receipt["terminal"] as? Bool, false)
                }
            }
        }
        try receipt.complete(Self.focused)
        receipt.fail(CancellationError(), code: "cancelled")
        XCTAssertEqual(receipt.receipt["state"] as? String, "confirmed") // terminal state settles once
    }

    func testReuseWithDifferentIntentRejectsWithoutChangingOriginalReceipt() throws {
        let lease = TaskLease(), id = UUID().uuidString
        let receipt = try token(lease, id: id, payload: payload)
        try receipt.complete(Self.focused)
        XCTAssertThrowsError(try lease.actionReceipts.begin(id: id, payload: ["action": ["type": "key", "key": "return"]])) {
            XCTAssertEqual(($0 as? ActionReceiptStore.ReceiptError)?.code, "receipt_conflict")
        }
        XCTAssertEqual(receipt.receipt["state"] as? String, "confirmed")
    }

    func testEndedActionContextCannotDeliverALateEffect() throws {
        let lease = TaskLease(), receipt = try token(lease, id: UUID().uuidString, payload: payload)
        try receipt.complete(Self.focused)
        var effects = 0
        XCTAssertThrowsError(try TaskOwnership.$current.withValue(lease) {
            try TaskOwnership.$actionReceipt.withValue(receipt) { try TaskOwnership.commit { effects += 1 } }
        })
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(receipt.receipt["state"] as? String, "confirmed")
    }

    func testCanonicalPayloadOrderAndIDCaseDoNotChangeIntent() throws {
        let lease = TaskLease(), id = UUID().uuidString
        let receipt = try token(lease, id: id, payload: ["b": 2, "a": 1])
        try receipt.complete(Self.focused)
        guard case .existing(let replay) = try lease.actionReceipts.begin(id: id.lowercased(), payload: ["a": 1, "b": 2]) else { return XCTFail("Duplicate admitted") }
        XCTAssertEqual(replay["action_id"] as? String, id.lowercased())
        XCTAssertEqual(replay["state"] as? String, "confirmed")
    }

    func testRejectedAndUnknownGUIOutcomesRemainDistinct() throws {
        let lease = TaskLease()
        let rejected = try token(lease, id: UUID().uuidString, payload: payload)
        rejected.fail(ActionReceiptStore.ReceiptError(code: "stale_target", message: "Moved"), code: "stale_target")
        XCTAssertEqual(rejected.receipt["state"] as? String, "rejected")
        XCTAssertEqual(rejected.receipt["error_code"] as? String, "stale_target")
        let uncertain = try token(lease, id: UUID().uuidString, payload: payload)
        try TaskOwnership.$current.withValue(lease) {
            try TaskOwnership.$actionReceipt.withValue(uncertain) { try TaskOwnership.commit {} }
        }
        uncertain.fail(ActionReceiptStore.ReceiptError(code: "fixture", message: "Lost result"), code: "action_rejected")
        XCTAssertEqual(uncertain.receipt["state"] as? String, "unconfirmed")
        XCTAssertEqual(uncertain.receipt["error_code"] as? String, "action_rejected")
        let delivered = try token(lease, id: UUID().uuidString, payload: payload)
        try delivered.complete(Self.focused.merging(["outcome": "delivered_unconfirmed", "verified": false, "verification_scope": "delivery_only"]) { _, new in new })
        XCTAssertEqual(delivered.receipt["state"] as? String, "unconfirmed")
    }

    func testRevocationAndForeignGenerationCannotDispatch() throws {
        let old = TaskLease(), newer = TaskLease(), id = UUID().uuidString
        let receipt = try token(old, id: id, payload: payload)
        var effects = 0
        XCTAssertThrowsError(try TaskOwnership.$current.withValue(newer) {
            try TaskOwnership.$actionReceipt.withValue(receipt) { try TaskOwnership.commit { effects += 1 } }
        })
        old.revoke()
        XCTAssertThrowsError(try TaskOwnership.$current.withValue(old) {
            try TaskOwnership.$actionReceipt.withValue(receipt) { try TaskOwnership.commit { effects += 1 } }
        })
        receipt.fail(CancellationError(), code: "cancelled")
        XCTAssertEqual(receipt.receipt["state"] as? String, "rejected")
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(newer.actionReceipts.lookup(id)["state"] as? String, "unknown")
        old.retire()
        XCTAssertEqual(old.actionReceipts.lookup(id)["state"] as? String, "unknown")
    }

    func testPauseResumeRetainsReceiptAndDeliversOnce() async throws {
        let lease = TaskLease(), id = UUID().uuidString, started = expectation(description: "Paused")
        let receipt = try token(lease, id: id, payload: payload)
        lease.pause()
        let worker = Task {
            try await TaskOwnership.$current.withValue(lease) {
                try await TaskOwnership.$actionReceipt.withValue(receipt) {
                    started.fulfill()
                    try await TaskOwnership.checkpoint()
                    try TaskOwnership.commit { try receipt.complete(Self.focused) }
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(receipt.receipt["state"] as? String, "pending")
        lease.resume()
        try await worker.value
        XCTAssertEqual(receipt.receipt["state"] as? String, "confirmed")
    }

    func testLostAppendAcknowledgementCanBeReplayedWithoutAnotherWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("note")
        let action: [String: Any] = ["type": "write_file", "path": path.path, "content": "X", "mode": "append"]
        let lease = TaskLease(), id = UUID().uuidString, tool = TaskToolExecutor()
        let receipt = try token(lease, id: id, payload: action)
        let result = try await TaskOwnership.$current.withValue(lease) {
            try await TaskOwnership.$actionReceipt.withValue(receipt) { try await tool.perform(action: action) }
        }
        try receipt.complete(result)
        guard case .existing(let replay) = try lease.actionReceipts.begin(id: id, payload: action) else { return XCTFail("Write admitted again") }
        XCTAssertEqual((replay["result"] as? [String: Any])?["bytes_written"] as? Int, 1)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "X")
        // A new caller intent must remain possible even with identical data.
        let next = try token(lease, id: UUID().uuidString, payload: action)
        try next.complete(try await TaskOwnership.$current.withValue(lease) {
            try await TaskOwnership.$actionReceipt.withValue(next) { try await tool.perform(action: action) }
        })
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "XX")
    }

    func testBridgeReplaysCanonicalReceiptWithoutDisplayOrObservationAccess() async throws {
        let lease = TaskLease(), bridge = try bridge(lease), id = UUID().uuidString.lowercased()
        let action: [String: Any] = ["type": "press", "element_id": "old:send"]
        let identity: [String: Any] = ["display_id": 999_999, "observation_revision": "old", "instruction_revision": 0,
                                       "action": try ActionContract.validate(action)]
        let receipt = try token(lease, id: id, payload: identity)
        try receipt.complete(Self.unconfirmed)
        var params = identity
        params["action_id"] = id
        params["action"] = ["type": "click", "element_id": "old:send", "x": 0, "y": 0] // canonical press
        let reply = await bridge.handleOwned(["task_generation_id": lease.id, "instruction_revision": 0, "request_id": "replay", "method": "act", "params": params], lease: lease)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual((reply["action_receipt"] as? [String: Any])?["state"] as? String, "unconfirmed")
        let lookup = await bridge.handleOwned(["task_generation_id": lease.id, "instruction_revision": 0, "request_id": "lookup", "method": "action_receipt", "params": ["action_id": id]], lease: lease)
        XCTAssertEqual((lookup["result"] as? [String: Any])?["state"] as? String, "unconfirmed")
        let foreign = await bridge.handleOwned(["task_generation_id": TaskLease().id, "instruction_revision": 0, "method": "action_receipt", "params": ["action_id": id]], lease: lease)
        XCTAssertEqual(foreign["error_code"] as? String, "cancelled")
    }

    func testCommandReceiptReturnsOutcomeChecksWithoutLaunchingAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("command-count")
        let action: [String: Any] = ["type": "run_command", "argv": ["/bin/zsh", "-c", "printf X >> \"$1\"", "fixture", path.path],
                                     "checks": [["type": "file_contents", "path": path.path, "content": "X"]]]
        let lease = TaskLease(), id = UUID().uuidString
        let receipt = try token(lease, id: id, payload: action)
        try receipt.complete(try await TaskOwnership.$current.withValue(lease) {
            try await TaskOwnership.$actionReceipt.withValue(receipt) { try await TaskToolExecutor().perform(action: action) }
        })
        guard case .existing(let replay) = try lease.actionReceipts.begin(id: id, payload: action) else { return XCTFail("Command admitted again") }
        let result = replay["result"] as? [String: Any]
        XCTAssertEqual(result?["exit_code"] as? Int, 0)
        XCTAssertEqual(result?["verified"] as? Bool, true)
        XCTAssertEqual((result?["checks"] as? [[String: Any]])?.first?["verified"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "X")
    }

    func testMissingIDIsRejectedBeforeNativeDispatchAndDiagnosticsStayCompatible() async throws {
        let lease = TaskLease(), bridge = try bridge(lease)
        let reply = await bridge.handleOwned(["task_generation_id": lease.id, "instruction_revision": 0, "method": "act", "params": ["action": ["type": "key", "pid": 42, "key": "return"]]], lease: lease)
        XCTAssertEqual(reply["error_code"] as? String, "invalid_action")
        XCTAssertThrowsError(try ActionReceiptStore.validateID("not-an-id"))
        let data = Data("{\"planning\":1,\"verification\":0,\"retries\":0,\"modelSwitches\":0,\"cacheHits\":0,\"reconnects\":0,\"receiptRecoveries\":1,\"receiptQueries\":2}".utf8)
        let metrics = try JSONDecoder().decode(AgentRequestMetrics.self, from: data)
        XCTAssertEqual(metrics.receiptRecoveries, 1)
        XCTAssertEqual(metrics.receiptQueries, 2)
        XCTAssertNil(metrics.receiptUnresolved)
    }
}
