import CryptoKit
import Foundation
import XCTest
@testable import OrbitAgent

final class ConfiguredJSONCodecTests: XCTestCase {
    private func fixtureFile(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-codecs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent(name)
    }

    private func ledgerEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func testRepeatedLedgerWritesKeepExistingBytesDateUnitsAndMetricKeys() throws {
        let file = try fixtureFile("ledger.json"), store = AgentTaskLedgerStore(fileURL: file)
        let taskID = UUID(), historyID = UUID()
        let metrics = AgentRequestMetrics(planning: 2, verification: 1, retries: 0, modelSwitches: 3,
                                          cacheHits: 4, reconnects: 0, promptCalls: nil, providerRetries: nil,
                                          actionDeliveries: 1, actionRejections: 0, unconfirmedActions: 0, repairs: 1)
        for index in 0..<12 {
            let snapshot = AgentTaskLedgerSnapshot(queue: [QueuedAgentTask(id: taskID, request: "fixture / café \(index)",
                queuedAt: Date(timeIntervalSince1970: 1234.125 + Double(index)))], history: [AgentTaskHistoryEntry(
                id: historyID, request: "fixture", responseTitle: "result", response: "observed",
                outcome: .completed, startedAt: Date(timeIntervalSince1970: 500.25),
                finishedAt: Date(timeIntervalSince1970: 501.5), wasQueued: true, requestMetrics: metrics)])
            try store.save(queue: snapshot.queue, history: snapshot.history)
            let bytes = try Data(contentsOf: file)
            XCTAssertEqual(bytes, try ledgerEncoder().encode(snapshot))
            XCTAssertEqual(try store.load(), snapshot)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let queue = try XCTUnwrap(json["queue"] as? [[String: Any]])
            XCTAssertEqual(queue[0]["queuedAt"] as? Double, 1_234_125 + Double(index) * 1_000)
            let history = try XCTUnwrap(json["history"] as? [[String: Any]])
            let encodedMetrics = try XCTUnwrap(history[0]["requestMetrics"] as? [String: Any])
            XCTAssertEqual(encodedMetrics["modelSwitches"] as? Int, 3)
            XCTAssertNil(encodedMetrics["model_switches"])
        }
    }

    func testLedgerDecoderRecoversAfterMalformedAndIncorrectDateInputs() throws {
        let file = try fixtureFile("ledger.json"), store = AgentTaskLedgerStore(fileURL: file)
        let task = QueuedAgentTask(request: "kept", queuedAt: Date(timeIntervalSince1970: 250.5))
        try store.save(queue: [task], history: [])
        let valid = try Data(contentsOf: file)
        for bytes in [Data("{malformed".utf8),
                      Data("{\"queue\":[{\"id\":\"\(task.id.uuidString)\",\"request\":\"fixture\",\"queuedAt\":\"wrong type\"}],\"history\":[]}".utf8)] {
            try bytes.write(to: file, options: .atomic)
            XCTAssertThrowsError(try store.load())
            try valid.write(to: file, options: .atomic)
            XCTAssertEqual(try store.load().queue, [task])
        }
    }

    func testLedgerEncodingFailureDoesNotOverwriteAndDoesNotPoisonNextSave() throws {
        let file = try fixtureFile("ledger.json"), store = AgentTaskLedgerStore(fileURL: file)
        let task = QueuedAgentTask(request: "original", queuedAt: Date(timeIntervalSince1970: 200))
        try store.save(queue: [task], history: [])
        let valid = try Data(contentsOf: file)
        let invalid = QueuedAgentTask(request: "not serializable", queuedAt: Date(timeIntervalSince1970: .nan))
        XCTAssertThrowsError(try store.save(queue: [invalid], history: []))
        XCTAssertEqual(try Data(contentsOf: file), valid)
        let next = QueuedAgentTask(request: "next", queuedAt: Date(timeIntervalSince1970: 201.25))
        try store.save(queue: [next], history: [])
        XCTAssertEqual(try store.load().queue, [next])
    }

    func testConcurrentStoreCopiesKeepCodingSerializedAndFilesComplete() throws {
        let file = try fixtureFile("ledger.json"), store = AgentTaskLedgerStore(fileURL: file)
        let tasks = (0..<48).map { QueuedAgentTask(request: "fixture \($0)", queuedAt: Date(timeIntervalSince1970: Double($0))) }
        try store.save(queue: [tasks[0]], history: [])
        let errorLock = NSLock()
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: tasks.count) { index in
            let copy = store
            do {
                try copy.save(queue: [tasks[index]], history: [])
                let snapshot = try copy.load()
                XCTAssertEqual(snapshot.queue.count, 1)
                XCTAssertTrue(tasks.contains(snapshot.queue[0]))
                XCTAssertTrue(snapshot.history.isEmpty)
            } catch {
                errorLock.lock(); errors.append(error); errorLock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(tasks.contains(try XCTUnwrap(store.load().queue.first)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCompatibilityKeyFingerprintsStayByteCompatible() throws {
        func fingerprint(_ metadata: [String]) throws -> String {
            SHA256.hash(data: try JSONEncoder().encode(metadata)).map { String(format: "%02x", $0) }.joined()
        }
        let environment = try fingerprint(["fixture"])
        for version in ["1", "2", "café / quoted \"version\""] {
            let key = ControlCompatibilityProfiles.Key(appID: "fixture.app", bundlePath: "/fixture/café.app",
                version: version, build: "10", executableRevision: "binary-1", role: "AXTextField", subrole: "",
                action: .set_value, capabilities: ["value": true, "press": false], hid: false, mainDisplay: true,
                environment: environment)
            XCTAssertEqual(key.subject, try fingerprint(["fixture.app", "/fixture/café.app", "AXTextField", "", "set_value"]))
            XCTAssertEqual(key.revision, try fingerprint([version, "10", "binary-1", "press:false,value:true", "false", "true", environment]))
        }
    }

    func testRepeatedProfileSavesKeepCanonicalArchiveBytesAndReloadBehavior() throws {
        struct Method: Encodable { let evidence: String; let observedAt: Double }
        struct Profile: Encodable { let revision: String; let methods: [String: Method]; let lastUsed: Double }
        struct Archive: Encodable { let version: Int; let environment: String; let profiles: [String: Profile] }
        let file = try fixtureFile("profiles.json"), environment = ControlCompatibilityProfiles.fingerprint(["fixture"])
        var date = Date(timeIntervalSince1970: 1_000_000)
        let profiles = ControlCompatibilityProfiles(fileURL: file, environment: environment, now: { date })
        let key = ControlCompatibilityProfiles.Key(appID: "fixture.app", bundlePath: "/fixture.app", version: "1", build: "1",
            executableRevision: "binary", role: "AXTextField", subrole: "", action: .set_value,
            capabilities: ["value": true], hid: false, mainDisplay: false, environment: environment)
        _ = profiles.preferred(for: key, permitted: [])
        for evidence in [ControlCompatibilityProfiles.Evidence.verified, .unsupported, .supported, .unconfirmed, .verified] {
            date += 0.5
            profiles.record(evidence, method: .process_event, for: key)
            let fresh = JSONEncoder(); fresh.outputFormatting = [.sortedKeys]
            let expected = Archive(version: 1, environment: environment, profiles: [key.subject: Profile(
                revision: key.revision, methods: ["process_event": Method(evidence: evidence.rawValue, observedAt: date.timeIntervalSince1970)],
                lastUsed: date.timeIntervalSince1970)])
            XCTAssertEqual(try Data(contentsOf: file), try fresh.encode(expected))
            let reloaded = ControlCompatibilityProfiles(fileURL: file, environment: environment, now: { date })
            XCTAssertEqual(reloaded.evidence(for: key, method: .process_event), evidence)
        }
    }

    func testConcurrentProfileWritesPreserveAllVerifiedMetadata() throws {
        let file = try fixtureFile("profiles.json"), environment = ControlCompatibilityProfiles.fingerprint(["fixture"])
        let profiles = ControlCompatibilityProfiles(fileURL: file, environment: environment)
        let keys = (0..<32).map { index in
            ControlCompatibilityProfiles.Key(appID: "fixture\(index).app", bundlePath: "/fixture\(index).app",
                version: "1", build: "1", executableRevision: "binary", role: "AXTextField", subrole: "",
                action: .set_value, capabilities: ["value": true], hid: false, mainDisplay: false, environment: environment)
        }
        DispatchQueue.concurrentPerform(iterations: keys.count) { index in
            _ = profiles.preferred(for: keys[index], permitted: [])
            profiles.record(.verified, method: .process_event, for: keys[index])
        }
        let reloaded = ControlCompatibilityProfiles(fileURL: file, environment: environment)
        XCTAssertEqual(reloaded.count, keys.count)
        for key in keys { XCTAssertEqual(reloaded.evidence(for: key, method: .process_event), .verified) }
    }
}
