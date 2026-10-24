import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class ActionRecoveryJournalTests: XCTestCase {
    private static let taskID = UUID(uuidString: "B49CAB6E-4A04-4F65-81E4-77569B999BDA")!
    private static let actionID = "7b29977c-81bf-4ce0-af9a-8ac4d746a138"
    private static let result: [String: Any] = ["action_type": "focus", "outcome": "verified", "verified": true, "verification_scope": "focus"]
    private let payload: [String: Any] = ["type": "focus", "element_id": "private-control-label", "text": "never-store-entered-text"]

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TaskPilotJournal-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func authorization() -> AgentTaskAuthorization {
        AgentTaskAuthorization(id: Self.taskID, request: "Original authorized fixture request", wasQueued: false)
    }
    private func token(_ store: ActionReceiptStore, id: String = ActionRecoveryJournalTests.actionID) throws -> ActionReceiptStore.Token {
        guard case .new(let token) = try store.begin(id: id, payload: payload) else { throw ActionRecoveryJournal.unavailable }
        return token
    }

    /// Invoked as an isolated XCTest subprocess, never the application. _exit
    /// bypasses defer, retirement, terminal callbacks, and journal cleanup.
    func testCrashWorker() throws {
        guard let path = ProcessInfo.processInfo.environment["TASKPILOT_JOURNAL_CRASH_ROOT"],
              let phase = ProcessInfo.processInfo.environment["TASKPILOT_JOURNAL_CRASH_PHASE"] else { return }
        let root = URL(fileURLWithPath: path)
        let auth = authorization()
        let journal = try ActionRecoveryJournal(directory: root.appendingPathComponent("journal"), barrier: { boundary in
            if phase == "before_dispatch", boundary == .prepared { _exit(71) }
            if phase == "after_confirmation", boundary == .terminal { _exit(74) }
        })
        try journal.register(auth)
        try AgentTaskLedgerStore(fileURL: root.appendingPathComponent("ledger.json")).save(queue: [], history: [], activeTask: auth)
        let lease = TaskLease(recoveryJournal: journal, recoveryTask: auth.id)
        let token = try token(lease.actionReceipts)
        try TaskOwnership.$current.withValue(lease) {
            try TaskOwnership.$actionReceipt.withValue(token) {
                try TaskOwnership.commit {
                    if phase == "after_dispatch" { _exit(72) }
                    try Data("one effect".utf8).write(to: root.appendingPathComponent("effect"))
                }
            }
        }
        if phase == "before_confirmation" { _exit(73) }
        try token.complete(Self.result)
        XCTFail("The crash boundary was not reached")
    }

    func testAbruptCrashesNeverRestoreReplayOrCompletionAuthority() async throws {
        for (phase, status, effects) in [("before_dispatch", 71, false), ("after_dispatch", 72, false),
                                          ("before_confirmation", 73, true), ("after_confirmation", 74, true)] {
            let root = try root(), process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "OrbitAgentTests.ActionRecoveryJournalTests/testCrashWorker", Bundle(for: Self.self).bundleURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment["TASKPILOT_JOURNAL_CRASH_ROOT"] = root.path
            environment["TASKPILOT_JOURNAL_CRASH_PHASE"] = phase
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            let ended = expectation(description: "crash \(phase)")
            process.terminationHandler = { _ in ended.fulfill() }
            try process.run()
            await fulfillment(of: [ended], timeout: 10)
            if process.isRunning { process.terminate(); return XCTFail("Crash fixture hung") }
            XCTAssertEqual(process.terminationStatus, Int32(status), phase)
            XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path), effects, phase)

            let journal = try ActionRecoveryJournal(directory: root.appendingPathComponent("journal"))
            let summary = journal.summary(task: Self.taskID)
            XCTAssertEqual(summary.count, 1)
            XCTAssertEqual(summary.uncertain, ["after_dispatch", "before_confirmation"].contains(phase) ? 1 : 0)
            let restored = ActionReceiptStore(generation: UUID().uuidString, journal: journal, recoveryTask: Self.taskID)
            XCTAssertThrowsError(try token(restored), phase) // no executor token
            XCTAssertEqual(restored.lookup(Self.actionID)["state"] as? String, "unknown")
            XCTAssertNil(restored.lookup(Self.actionID)["result"]) // not proof, even after confirmation

            let store = AgentTaskLedgerStore(fileURL: root.appendingPathComponent("ledger.json"))
            var ledger = try store.load()
            XCTAssertNotNil(try ledger.recoverInterruptedTask(journal: journal))
            XCTAssertNil(ledger.activeTask)
            XCTAssertTrue(ledger.queue.isEmpty)
            XCTAssertEqual(ledger.history.map(\.outcome), [.stopped])
            XCTAssertEqual(ledger.history.first?.request, authorization().request)
            try store.save(queue: ledger.queue, history: ledger.history)
            var again = try store.load()
            XCTAssertNil(try again.recoverInterruptedTask(journal: journal))
            XCTAssertEqual(again.history.count, 1)
            try journal.close(task: Self.taskID)
            XCTAssertThrowsError(try token(restored, id: UUID().uuidString)) // cannot continue retired authorization
            if effects { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("effect")), "one effect") }
        }
    }

    func testOnlyOpaqueMetadataAndKeyedFingerprintsPersistWithPrivatePermissions() throws {
        let root = try root(), journal = try ActionRecoveryJournal(directory: root)
        try journal.register(authorization())
        let store = ActionReceiptStore(generation: "never-store-generation", journal: journal, recoveryTask: Self.taskID)
        let token = try token(store)
        try token.dispatched()
        try token.complete(Self.result.merging(["message": "never-store-native-response"]) { _, new in new })
        let bytes = try Data(contentsOf: root.appendingPathComponent("receipts.json"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let content = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["data"] as? String)))
        let text = String(decoding: content, as: UTF8.self)
        for forbidden in ["private-control-label", "never-store-entered-text", "never-store-generation", "never-store-native-response", authorization().request, "focus"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(forbidden), forbidden)
        }
        let key = SymmetricKey(data: try Data(contentsOf: root.appendingPathComponent("key")))
        XCTAssertTrue(HMAC<SHA256>.isValidAuthenticationCode(try XCTUnwrap(Data(base64Encoded: envelope["authentication"] as! String)), authenticating: content, using: key))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for name in ["key", "receipts.json", "owner.lock"] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testJournalRefusesConcurrentControllerAndMissingOrCorruptedFiles() throws {
        for damage in ["key", "receipts.json", "truncated", "altered", "oversized"] {
            let root = try root()
            do {
                let journal = try ActionRecoveryJournal(directory: root)
                XCTAssertThrowsError(try ActionRecoveryJournal(directory: root))
                try journal.register(authorization())
                let store = ActionReceiptStore(generation: "fixture", journal: journal, recoveryTask: Self.taskID)
                _ = try token(store)
            }
            if ["key", "receipts.json"].contains(damage) { try FileManager.default.removeItem(at: root.appendingPathComponent(damage)) }
            else if damage == "truncated" { try Data("{broken".utf8).write(to: root.appendingPathComponent("receipts.json")) }
            else if damage == "oversized" { try Data(repeating: 65, count: ActionRecoveryJournal.maximumBytes + 1).write(to: root.appendingPathComponent("receipts.json")) }
            else {
                var data = try Data(contentsOf: root.appendingPathComponent("receipts.json"))
                data[data.count / 2] ^= 1
                try data.write(to: root.appendingPathComponent("receipts.json"))
            }
            XCTAssertThrowsError(try ActionRecoveryJournal(directory: root))
        }
    }

    func testWriteFailuresPreventDeliveryAndNeverPublishConfirmation() throws {
        for boundary in [ActionRecoveryJournal.Boundary.prepared, .dispatched, .terminal] {
            let root = try root()
            let journal = try ActionRecoveryJournal(directory: root, barrier: { crossed in
                if crossed == boundary { throw CocoaError(.fileWriteOutOfSpace) }
            })
            try journal.register(authorization())
            let lease = TaskLease(recoveryJournal: journal, recoveryTask: Self.taskID)
            var effects = 0
            do {
                let receipt = try token(lease.actionReceipts)
                try TaskOwnership.$current.withValue(lease) {
                    try TaskOwnership.$actionReceipt.withValue(receipt) { try TaskOwnership.commit { effects += 1 } }
                }
                XCTAssertThrowsError(try receipt.complete(Self.result))
                receipt.fail(ActionRecoveryJournal.unavailable, code: "protocol_error")
                XCTAssertEqual(receipt.receipt["state"] as? String, "unconfirmed")
                XCTAssertNil(receipt.receipt["result"])
            } catch {
                XCTAssertTrue(boundary == .prepared || boundary == .dispatched)
            }
            XCTAssertEqual(effects, boundary == .terminal ? 1 : 0)
            XCTAssertThrowsError(try lease.actionReceipts.begin(id: UUID().uuidString, payload: payload))
        }
    }

    func testActualStorageFailureDoesNotReachNativeDelivery() throws {
        let root = try root(), journal = try ActionRecoveryJournal(directory: root)
        try journal.register(authorization())
        let lease = TaskLease(recoveryJournal: journal, recoveryTask: Self.taskID)
        let receipt = try token(lease.actionReceipts)
        try FileManager.default.removeItem(at: root.appendingPathComponent("receipts.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("receipts.json"), withIntermediateDirectories: false)
        var effects = 0
        XCTAssertThrowsError(try TaskOwnership.$current.withValue(lease) {
            try TaskOwnership.$actionReceipt.withValue(receipt) { try TaskOwnership.commit { effects += 1 } }
        })
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(receipt.receipt["state"] as? String, "pending")
    }

    func testMalformedNativeResultNeverCreatesTerminalProof() throws {
        let root = try root(), journal = try ActionRecoveryJournal(directory: root)
        try journal.register(authorization())
        let store = ActionReceiptStore(generation: "fixture", journal: journal, recoveryTask: Self.taskID)
        let receipt = try token(store)
        try receipt.dispatched()
        XCTAssertThrowsError(try receipt.complete(["verified": true]))
        XCTAssertEqual(journal.summary(task: Self.taskID).uncertain, 1)
        XCTAssertNil(receipt.receipt["result"])
        store.discard()
        XCTAssertEqual(journal.summary(task: Self.taskID).uncertain, 1)
    }

    func testRecoveryRequiresOriginalMatchingAuthorizationAndNeverRequeues() throws {
        let root = try root(), journal = try ActionRecoveryJournal(directory: root)
        let auth = authorization()
        try journal.register(auth)
        let queued = QueuedAgentTask(request: "queued future work")
        var snapshot = AgentTaskLedgerSnapshot(queue: [queued], activeTask: auth)
        snapshot.activeTask = AgentTaskAuthorization(id: auth.id, request: "forged authorization", wasQueued: false)
        XCTAssertThrowsError(try snapshot.recoverInterruptedTask(journal: journal))
        XCTAssertTrue(snapshot.history.isEmpty)
        snapshot.activeTask = auth
        XCTAssertNotNil(try snapshot.recoverInterruptedTask(journal: journal))
        XCTAssertEqual(snapshot.queue, [queued])
        XCTAssertEqual(snapshot.history.first?.outcome, .stopped)
        XCTAssertNil(try snapshot.recoverInterruptedTask(journal: journal))
    }

    func testSealingOrphansRetiresPreparedWorkWithoutConfirmingDispatchedEffects() throws {
        let root = try root(), journal = try ActionRecoveryJournal(directory: root)
        try journal.register(authorization())
        let store = ActionReceiptStore(generation: "fixture", journal: journal, recoveryTask: Self.taskID)
        _ = try token(store)
        try token(store, id: UUID().uuidString).dispatched()
        let orphan = AgentTaskAuthorization(request: "never launched", wasQueued: false)
        try journal.register(orphan)
        try journal.sealAfterRestart()
        XCTAssertEqual(journal.summary().uncertain, 1)
        XCTAssertEqual(journal.summary().prepared, 0)
        XCTAssertEqual(journal.summary().terminal, 1)
        XCTAssertFalse(journal.matches(orphan))
        XCTAssertThrowsError(try journal.prepare(task: orphan.id, action: UUID().uuidString, payload: Data()))
        XCTAssertThrowsError(try token(store, id: UUID().uuidString))
    }

    func testQueueAuthorizationRoundTripAndRecoveryPreserveDistinctRepeatedIntent() throws {
        let root = try root(), journal = try ActionRecoveryJournal(directory: root.appendingPathComponent("journal"))
        let store = AgentTaskLedgerStore(fileURL: root.appendingPathComponent("ledger.json"))
        let first = QueuedAgentTask(request: "same request", queuedAt: Date(timeIntervalSince1970: 100)),
            next = QueuedAgentTask(request: "same request", queuedAt: Date(timeIntervalSince1970: 101))
        let auth = AgentTaskAuthorization(request: first.request, startedAt: Date(timeIntervalSince1970: 102),
            wasQueued: true, queuedTaskID: first.id)
        try journal.register(auth)
        try store.save(queue: [first, next], history: [], activeTask: auth)
        var snapshot = try store.load()
        XCTAssertEqual(snapshot.activeTask, auth)
        XCTAssertNotNil(try snapshot.recoverInterruptedTask(journal: journal))
        XCTAssertEqual(snapshot.queue, [next])
        XCTAssertEqual(snapshot.history.first?.wasQueued, true)
        XCTAssertEqual(snapshot.history.first?.id, auth.id)
        XCTAssertEqual(snapshot.history.first?.outcome, .stopped)
    }

    func testRestoredBridgeActionRejectsBeforeDisplayOrExecutorAccess() async throws {
        let root = try root(), journal = try ActionRecoveryJournal(directory: root)
        try journal.register(authorization())
        let old = ActionReceiptStore(generation: UUID().uuidString, journal: journal, recoveryTask: Self.taskID)
        let action: [String: Any] = ["type": "focus", "element_id": "stale:field"]
        _ = try old.begin(id: Self.actionID, payload: ["action": action])
        let lease = TaskLease(recoveryJournal: journal, recoveryTask: Self.taskID)
        let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
        try bridge.bind(lease)
        let reply = await bridge.handleOwned(["task_generation_id": lease.id, "instruction_revision": 0, "working_document_revision": 0, "method": "act", "params": [
            "action_id": Self.actionID, "action": action, "display_id": 999_999, "observation_revision": "stale"]], lease: lease)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error_code"] as? String, "protocol_error")
        XCTAssertNil(reply["result"])
        XCTAssertEqual(journal.summary().prepared, 1)
        XCTAssertEqual(journal.summary().uncertain, 0)
    }

    func testLegacyLedgerStillLoadsWithoutAnActiveTask() throws {
        let root = try root(), file = root.appendingPathComponent("ledger.json")
        try Data("{\"queue\":[],\"history\":[]}".utf8).write(to: file)
        XCTAssertNil(try AgentTaskLedgerStore(fileURL: file).load().activeTask)
    }

    func testIncompleteAtomicWritesAreDiscardedWithoutPublishingTheirState() throws {
        let root = try root()
        do {
            let journal = try ActionRecoveryJournal(directory: root)
            try journal.register(authorization())
            _ = try token(ActionReceiptStore(generation: "fixture", journal: journal, recoveryTask: Self.taskID))
        }
        let abandoned = root.appendingPathComponent(".recovery-\(UUID()).tmp")
        try Data("an interrupted replacement must not become a receipt".utf8).write(to: abandoned)
        let unrelated = root.appendingPathComponent("unrelated.tmp")
        try Data("leave unrelated data alone".utf8).write(to: unrelated)
        let journal = try ActionRecoveryJournal(directory: root)
        XCTAssertEqual(journal.summary().prepared, 1)
        XCTAssertEqual(journal.summary().uncertain, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testFullJournalRetainsEveryUncertainReceiptAndRejectsMoreDelivery() throws {
        let root = try root()
        do {
            let journal = try ActionRecoveryJournal(directory: root)
            try journal.register(authorization())
        }
        let file = root.appendingPathComponent("receipts.json")
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["data"] as! String)!) as? [String: Any])
        snapshot["records"] = (0..<ActionRecoveryJournal.maximumRecords).map { _ in
            ["task": Self.taskID.uuidString, "action": UUID().uuidString,
             "fingerprint": String(repeating: "a", count: 64), "phase": "dispatched"]
        }
        let bytes = try JSONSerialization.data(withJSONObject: snapshot)
        let key = SymmetricKey(data: try Data(contentsOf: root.appendingPathComponent("key")))
        try JSONSerialization.data(withJSONObject: ["data": bytes.base64EncodedString(),
            "authentication": Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key)).base64EncodedString()]).write(to: file)
        let journal = try ActionRecoveryJournal(directory: root)
        let before = try Data(contentsOf: file)
        let store = ActionReceiptStore(generation: "fixture", journal: journal, recoveryTask: Self.taskID)
        XCTAssertThrowsError(try token(store))
        XCTAssertEqual(journal.summary().uncertain, ActionRecoveryJournal.maximumRecords)
        XCTAssertEqual(try Data(contentsOf: file), before)
        try journal.close(task: Self.taskID)
        XCTAssertEqual(journal.summary().uncertain, ActionRecoveryJournal.maximumRecords)
    }

    func testRetirementCompactsOnlySafeTerminalRecordsAndPreservesUncertainty() throws {
        let root = try root(), journal = try ActionRecoveryJournal(directory: root)
        try journal.register(authorization())
        let store = ActionReceiptStore(generation: "fixture", journal: journal, recoveryTask: Self.taskID)
        let uncertain = try token(store)
        try uncertain.dispatched()
        uncertain.fail(CancellationError(), code: "cancelled")
        for _ in 0..<132 {
            try token(store, id: UUID().uuidString).complete(Self.result)
        }
        store.discard()
        XCTAssertEqual(journal.summary().uncertain, 1)
        XCTAssertEqual(journal.summary().terminal, 128)
    }

    func testSymlinksAndHardlinksCannotRedirectJournalFiles() throws {
        for name in ["key", "owner.lock", "receipts.json"] {
            let root = try root(), other = try self.root().appendingPathComponent("untouched")
            try Data("untouched".utf8).write(to: other)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: other)
            XCTAssertThrowsError(try ActionRecoveryJournal(directory: root))
            XCTAssertEqual(try String(contentsOf: other), "untouched")
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
            try FileManager.default.linkItem(at: other, to: root.appendingPathComponent(name))
            XCTAssertThrowsError(try ActionRecoveryJournal(directory: root))
            XCTAssertEqual(try String(contentsOf: other), "untouched")
        }
    }
}
