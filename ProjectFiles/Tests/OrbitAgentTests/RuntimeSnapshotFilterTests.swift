import XCTest
@testable import OrbitAgent

final class RuntimeSnapshotFilterTests: XCTestCase {
    private func metrics(_ overrides: [String: Any] = [:]) throws -> AgentRequestMetrics {
        var fields: [String: Any] = ["planning": 1, "verification": 0, "retries": 0,
            "model_switches": 0, "cache_hits": 0, "reconnects": 0]
        fields.merge(overrides) { _, new in new }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AgentRequestMetrics.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testInterleavedRepeatedSnapshotsScheduleOnceWithoutDroppingTransitions() throws {
        var filter = RuntimeSnapshotFilter()
        let first = try metrics(), second = try metrics(["planning": 2])
        var scheduled = 0
        for _ in 0..<10_000 {
            if filter.shouldSchedule(.status("Working")) { scheduled += 1 }
            if filter.shouldSchedule(.diagnostics(first)) { scheduled += 1 }
        }
        XCTAssertEqual(scheduled, 2)
        XCTAssertTrue(filter.shouldSchedule(.status("Checking")))
        XCTAssertTrue(filter.shouldSchedule(.status("Working")))
        XCTAssertTrue(filter.shouldSchedule(.diagnostics(second)))
        XCTAssertTrue(filter.shouldSchedule(.diagnostics(first)))
        XCTAssertFalse(filter.shouldSchedule(.diagnostics(first)))
        XCTAssertTrue(filter.shouldSchedule(.status("Working ")))
    }

    func testEveryDiagnosticFieldParticipatesInSnapshotEquality() throws {
        let keys = ["planning", "verification", "retries", "model_switches", "cache_hits", "reconnects",
            "prompt_calls", "provider_retries", "action_deliveries", "action_rejections", "unconfirmed_actions", "repairs",
            "evidence_checks", "coverage_rejections", "requirements_proven", "dependency_checks", "dependency_rejections",
            "conflict_inspections", "evidence_conflicts", "recovery_cycles", "cycle_suppressions", "receipt_queries",
            "receipt_recoveries", "effect_checks", "verified_effects", "unconfirmed_effects", "receipt_unresolved",
            "local_notifications", "local_targeted_checks", "local_poll_wakeups", "command_inspections", "command_probes",
            "command_probe_cache_hits", "command_preflight_rejections"]
        for key in keys {
            var filter = RuntimeSnapshotFilter()
            let base = try metrics(), changed = try metrics([key: 2])
            XCTAssertTrue(filter.shouldSchedule(.diagnostics(base)), key)
            XCTAssertTrue(filter.shouldSchedule(.diagnostics(changed)), key)
            XCTAssertFalse(filter.shouldSchedule(.diagnostics(changed)), key)
            XCTAssertTrue(filter.shouldSchedule(.diagnostics(base)), key)
        }
        var filter = RuntimeSnapshotFilter()
        XCTAssertTrue(filter.shouldSchedule(.diagnostics(try metrics())))
        XCTAssertTrue(filter.shouldSchedule(.diagnostics(try metrics(["provider_retries": 0]))))
    }

    func testEventsAndTerminalDeliveriesAreNeverSnapshotSuppressed() throws {
        var filter = RuntimeSnapshotFilter()
        let events: [RuntimeEvent] = [
            .output(AgentTaskOutput(shouldShow: true, title: "Result", content: "Saved", decidedByAgent: false)),
            .modelHealth("fixture", "verified", "Ready"),
            .userInputRequired(AgentUserInputRequest(requestID: "input", taskGenerationID: "fixture",
                title: "Password", message: "Enter", kind: .password)),
            .completed("Finished"), .failed("Failure"), .stopped]
        for event in events {
            for _ in 0..<3 { XCTAssertTrue(filter.shouldSchedule(event)) }
        }
    }

    func testStatusInvalidationAndInputHandoffRetainIndependentMetrics() throws {
        var filter = RuntimeSnapshotFilter()
        let value = try metrics()
        XCTAssertTrue(filter.shouldSchedule(.status("Working")))
        XCTAssertTrue(filter.shouldSchedule(.diagnostics(value)))
        filter.invalidateStatus()
        XCTAssertTrue(filter.shouldSchedule(.status("Working")))
        XCTAssertFalse(filter.shouldSchedule(.diagnostics(value)))
        XCTAssertTrue(filter.shouldSchedule(.userInputRequired(AgentUserInputRequest(requestID: "input",
            taskGenerationID: "fixture", title: "Code", message: "Enter", kind: .verificationCode))))
        XCTAssertTrue(filter.shouldSchedule(.status("Working")))
        XCTAssertFalse(filter.shouldSchedule(.diagnostics(value)))
        var nextInvocation = RuntimeSnapshotFilter()
        XCTAssertTrue(nextInvocation.shouldSchedule(.status("Working")))
        XCTAssertTrue(nextInvocation.shouldSchedule(.diagnostics(value)))
    }

    func testTaskWaitSnapshotsCoalesceOnlyWithinTheSameOperationAndMeaning() throws {
        var filter = RuntimeSnapshotFilter()
        func wait(_ overrides: [String: Any] = [:]) throws -> AgentTaskWaitSnapshot {
            var message: [String: Any] = [
                "kind": "task_wait", "task_generation_id": "generation", "version": 1,
                "revision": 1, "operation_id": 1, "phase": "observing",
                "last_confirmed": "No confirmed result yet.", "waiting_for": "Checking the current screen",
                "attention": "none"
            ]
            message.merge(overrides) { _, new in new }
            return try XCTUnwrap(AgentTaskWaitSnapshot.parse(message, generationID: "generation"))
        }

        XCTAssertTrue(filter.shouldSchedule(.taskWait(try wait())))
        XCTAssertFalse(filter.shouldSchedule(.taskWait(try wait(["revision": 2]))))
        XCTAssertTrue(filter.shouldSchedule(.taskWait(try wait(["operation_id": 2, "revision": 3]))))
        XCTAssertTrue(filter.shouldSchedule(.taskWait(try wait(["operation_id": 2, "revision": 4,
                                                                 "waiting_for": "Waiting for the model’s response"]))))
    }
}
