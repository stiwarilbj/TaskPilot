import Foundation
import XCTest
@testable import OrbitAgent

final class BackendFaultReportsTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 100.0
        func now() -> Double { lock.withLock { value } }
        func advance(_ amount: Double) { lock.withLock { value += amount } }
    }
    func testSharedVocabularyAndStrictWireSchema() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/backend-faults.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(BackendFaultReports.Cause.allCases.map(\.rawValue)), Set(fixture["causes"] as! [String]))
        XCTAssertEqual(Set(BackendFaultReports.Stage.allCases.map(\.rawValue)), Set(fixture["stages"] as! [String]))
        let valid = fixture["valid"] as! [String: Any]
        XCTAssertNotNil(BackendFaultReports.Event.decode(valid))
        for changes in fixture["invalid_changes"] as! [[String: Any]] {
            XCTAssertNil(BackendFaultReports.Event.decode(valid.merging(changes) { _, new in new }), "\(changes)")
        }
    }
    func testFirstCauseIsStableAndUnrelatedFaultsStaySeparate() throws {
        let store = BackendFaultReports()
        let gateway = store.begin(.gatewayUnavailable, at:.healthCheck)
        XCTAssertTrue(store.note(gateway, .connection))
        XCTAssertFalse(store.note(gateway, .connection, cause:.providerQuota))
        let quota = store.begin(.providerQuota, at:.modelRequest)
        let command = store.begin(.commandTimeout, at:.nativeAction)
        for _ in 0..<100 { store.note(gateway, .waiting) }
        let first = try XCTUnwrap(store.reports().first)
        XCTAssertEqual(first.cause, .gatewayUnavailable); XCTAssertEqual(first.firstStage, .healthCheck)
        XCTAssertEqual(first.consequences.values.reduce(0, +), 15)
        XCTAssertEqual(store.reports().count, 3)
        XCTAssertFalse(store.claim(quota, route:.reconnect))
        XCTAssertFalse(store.claim(command, route:.gatewayRestart))
        XCTAssertTrue(store.claim(command, route:.reconcile))
    }
    func testConcurrentDuplicateRecoveryIsCoalescedButBudgetedAttemptsRemainDistinct() throws {
        let store = BackendFaultReports(), link = store.begin(.transport, at:.connection)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in _ = store.claim(link, route:.reconnect) }
        XCTAssertEqual(store.reports().first?.suppressedRecoveries, 63)
        XCTAssertTrue(store.claim(link, route:.reconnect, attempt:2))
        XCTAssertFalse(store.claim(link, route:.reconnect, attempt:17))
        XCTAssertEqual(store.reports().count, 1)
    }
    func testBoundedRetentionExpiryAndClockRegression() {
        let clock = Clock(), store = BackendFaultReports(capacity:2, now:{ clock.now() })
        let link = store.begin(.transport, at:.connection)
        clock.advance(119); XCTAssertTrue(store.note(link, .waiting))
        clock.advance(1); XCTAssertFalse(store.note(link, .waiting))
        XCTAssertFalse(store.claim(link, route:.reconnect))
        let second = store.begin(.transport, at:.connection)
        clock.advance(-1); XCTAssertFalse(store.note(second, .waiting))
        for _ in 0..<100 { _ = store.begin(.transport, at:.connection) }
        XCTAssertEqual(store.reports().count, 2)
    }
    func testRemoteEventsAreOrderedIdempotentAndScopedToOneInvocation() throws {
        let store = BackendFaultReports(), first = BackendFaultReports.Scope(store), second = BackendFaultReports.Scope(store)
        var wire: [String:Any] = ["version":1, "fault_id":UUID().uuidString.lowercased(), "sequence":1,
                                 "cause":"transport", "stage":"connection"]
        let event = try XCTUnwrap(BackendFaultReports.Event.decode(wire))
        XCTAssertTrue(first.accept(event)); XCTAssertFalse(first.accept(event))
        XCTAssertTrue(second.accept(event))
        wire["sequence"] = 3
        XCTAssertFalse(first.accept(try XCTUnwrap(BackendFaultReports.Event.decode(wire))))
        wire["sequence"] = 2; wire["cause"] = "provider_quota"
        XCTAssertFalse(first.accept(try XCTUnwrap(BackendFaultReports.Event.decode(wire))))
        wire["cause"] = "transport"; wire["stage"] = "waiting"
        XCTAssertTrue(first.accept(try XCTUnwrap(BackendFaultReports.Event.decode(wire))))
        XCTAssertEqual(store.reports().map(\.cause), [.transport, .transport])
        XCTAssertEqual(store.reports().map { $0.consequences[.waiting] ?? 0 }, [1, 0])
    }
    func testHealthProjectionContainsNoFreeFormDataAndExpires() throws {
        let clock = Clock(), telemetry = BackendTelemetry(now:{ clock.now() })
        let link = telemetry.faults.begin(.gatewayUnavailable, at:.healthCheck)
        let wire = try XCTUnwrap(telemetry.faults.healthEvent(link))
        XCTAssertEqual(Set(wire.keys), ["version", "fault_id", "sequence", "cause", "stage"])
        XCTAssertNotNil(BackendFaultReports.Event.decode(wire))
        XCTAssertTrue(telemetry.samples().isEmpty)
        clock.advance(120); XCTAssertNil(telemetry.faults.healthEvent(link))
    }
    func testLateHostRootJoinsExplicitConnectionWithoutLosingRecoveryClaims() throws {
        let store = BackendFaultReports(), scope = BackendFaultReports.Scope(store)
        let child = store.begin(.transport, at:.connection)
        XCTAssertTrue(store.claim(child, route:.reconnect)); store.note(child, .waiting)
        let quota = store.begin(.providerQuota, at:.modelRequest)
        let parent = store.begin(.gatewayUnavailable, at:.healthCheck)
        XCTAssertFalse(store.attach(quota, to:parent))
        XCTAssertTrue(store.attach(child, to:parent)); XCTAssertTrue(store.attach(child, to:parent))
        XCTAssertFalse(store.claim(child, route:.reconnect))
        XCTAssertTrue(store.claim(parent, route:.gatewayRestart))
        XCTAssertEqual(store.reports().count, 2)
        XCTAssertEqual(store.reports().last?.consequences[.waiting], 1)
        let c = UUID().uuidString.lowercased(), p = UUID().uuidString.lowercased()
        func event(_ id: String, _ cause: String, _ stage: String) throws -> BackendFaultReports.Event {
            try XCTUnwrap(BackendFaultReports.Event.decode(["version":1,"sequence":1,"fault_id":id,"cause":cause,"stage":stage]))
        }
        let relation: [String:Any] = ["version":1,"child_id":c,"parent_id":p]
        XCTAssertFalse(scope.accept(try XCTUnwrap(BackendFaultReports.Relation.decode(relation))))
        XCTAssertTrue(scope.accept(try event(c, "transport", "connection")))
        XCTAssertTrue(scope.accept(try event(p, "gateway_unavailable", "health_check")))
        XCTAssertTrue(scope.accept(try XCTUnwrap(BackendFaultReports.Relation.decode(relation))))
        XCTAssertEqual(store.reports().count, 3)
        XCTAssertNil(BackendFaultReports.Relation.decode(relation.merging(["detail":"secret"]) { _, new in new }))
        XCTAssertNil(BackendFaultReports.Relation.decode(["version":1,"child_id":c,"parent_id":c]))
    }
}
