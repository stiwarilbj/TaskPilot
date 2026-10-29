import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

/// Runs the real Python dispatcher through the real native runtime transport.
/// All effects are confined to an integer in memory; no AX input or capture.
final class TaskReplayLabTests: XCTestCase {
    private struct Catalog: Decodable {
        struct Trace: Decodable {
            struct Event: Decodable { let tick: UInt64; let event: String }
            let id: String
            let fault: String
            let seeds: [UInt64]
            let events: [Event]
        }
        let version: Int
        let traces: [Trace]
    }
    private struct State {
        var modelReady = false
        var planning = 0
        var preflightReady = false
        var preflightReturned = false
        var observations = 0
        var attempts = 0
        var deliveries = 0
        var receipts = 0
        var verifications = 0
        var writeCalls = 0
        var terminal: [String] = []
        var statuses: [String] = []
        var receiptStates: [String] = []
        var rejected = 0
        var errors: [String] = []
        var handlers = 0
        var settledHandlers = 0
        var requests = Set<String>()
        var settledRequests = Set<String>()
        var duplicateCallbacks = 0
    }
    private struct Replay: Equatable {
        let order: [String]
        let deliveries: Int
        let attempts: Int
        let terminal: [String]
        let receipts: Int
        let verifications: Int
    }
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testDelayedNativeCallbacksCannotCrossTaskOwnership() async throws {
        for seed: UInt64 in [1, 3] {
            let scheduler = SeededLifecycleScheduler(seed: seed)
            let old = TaskLease(), current = TaskLease()
            let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
            try bridge.bind(old)
            old.revoke(); old.retire()
            try bridge.bind(current)
            defer { current.revoke(); current.retire() }
            let id = UUID().uuidString.lowercased()
            let claim = try current.actionReceipts.begin(id: id, payload: ["action": ["type": "press", "element_id": "synthetic:e1"]])
            guard case .new(let receipt) = claim else { return XCTFail("New receipt expected") }
            try receipt.dispatched()
            try receipt.complete(["action_type": "press", "verified": false,
                                  "outcome": "delivered_unconfirmed", "verification_scope": "delivery_only"])
            let callbacks = LockedTestValue<[String]>([])
            for event in ["stale_owner", "foreign_generation", "current_receipt"] {
                scheduler.schedule(at: 1, name: event) {
                    let request: [String: Any] = ["kind": "bridge_request", "request_id": "synthetic",
                        "task_generation_id": event == "current_receipt" ? current.id : old.id,
                        "instruction_revision": 0, "working_document_revision": 0,
                        "method": event == "current_receipt" ? "action_receipt" : "act",
                        "params": ["action_id": id, "action": ["type": "press", "element_id": "synthetic:e1"]]]
                    let response = await bridge.handleOwned(request, lease: event == "stale_owner" ? old : current)
                    XCTAssertEqual(response["ok"] as? Bool, event == "current_receipt", "seed=\(seed) event=\(event)")
                    if event == "current_receipt" {
                        XCTAssertEqual((response["result"] as? [String: Any])?["state"] as? String, "unconfirmed")
                    } else { XCTAssertEqual(response["error_code"] as? String, "cancelled") }
                    callbacks.update { $0.append(event) }
                }
            }
            await scheduler.runAll()
            XCTAssertEqual(callbacks.read(), scheduler.trace)
            XCTAssertEqual(current.actionReceipts.lookup(id)["state"] as? String, "unconfirmed")
            XCTAssertEqual(current.actionReceipts.duplicateCount, 0)
            XCTAssertEqual(current.state, .running)
        }
    }

    @MainActor
    func testSyntheticTaskTracesReplayAcrossTheActualPythonSwiftBoundary() async throws {
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: project.appendingPathComponent("Tests/Fixtures/task-replay-traces.json")))
        XCTAssertEqual(catalog.version, 1)
        let filter = ProcessInfo.processInfo.environment["TASKPILOT_REPLAY_TRACE"]
        let selected = catalog.traces.filter { filter == nil || $0.id == filter }
        XCTAssertFalse(selected.isEmpty, "Unknown replay trace")
        var stopOutcomes = Set<Int>()
        for trace in selected {
            let seeds = ProcessInfo.processInfo.environment["TASKPILOT_REPLAY_SEED"].flatMap(UInt64.init).map { [$0] } ?? trace.seeds
            for seed in seeds {
                let first = try await replay(trace, seed: seed)
                let repeated = try await replay(trace, seed: seed)
                XCTAssertEqual(first, repeated, "Nonreproducible trace=\(trace.id) seed=\(seed)")
                if trace.id == "stop_at_delivery" { stopOutcomes.insert(first.deliveries) }
            }
        }
        if filter == nil && ProcessInfo.processInfo.environment["TASKPILOT_REPLAY_SEED"] == nil {
            XCTAssertEqual(stopOutcomes, [0, 1], "Fixtures must exercise both sides of the dispatch boundary")
        }
    }

    @MainActor
    private func replay(_ trace: Catalog.Trace, seed: UInt64) async throws -> Replay {
        let state = LockedTestValue(State())
        let modelGate = DeterministicAsyncLatch(), deliveryGate = DeterministicAsyncLatch()
        let stoppingGate = DeterministicAsyncLatch()
        let lease = TaskLease()
        let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
        let scheduler = SeededLifecycleScheduler(seed: seed)
        let runtime = AgentRuntimeProcess(bridge: bridge, bridgeHandler: { request in
            let requestID = request["request_id"] as! String
            state.update {
                $0.handlers += 1
                if !$0.requests.insert(requestID).inserted { $0.duplicateCallbacks += 1 }
            }
            defer {
                state.update {
                    $0.settledHandlers += 1
                    if !$0.settledRequests.insert(requestID).inserted { $0.duplicateCallbacks += 1 }
                }
            }
            func reply(_ fields: [String: Any]) -> [String: Any] {
                fields.merging(["kind": "bridge_response", "request_id": request["request_id"]!,
                    "task_generation_id": lease.id]) { old, _ in old }
            }
            let params = request["params"] as? [String: Any] ?? [:]
            switch request["method"] as? String {
            case "lab_checkpoint":
                if params["stage"] as? String == "model_response" {
                    let first = !state.read().modelReady
                    state.update { $0.modelReady = true; $0.planning += 1 }
                    if first { await modelGate.wait() }
                    else if trace.id == "stop_at_delivery" { await stoppingGate.wait() }
                } else { state.update { $0.verifications += 1 } }
                return reply(["ok": true, "result": [:]])
            case "observe":
                state.update { $0.observations += 1 }
                let revision = "synthetic-\(state.read().observations)"
                return reply(["ok": true, "result": ["task_generation_id": lease.id,
                    "observation_revision": revision,
                    "applications": [["pid": 4242, "name": "Synthetic App", "active": true,
                                      "windows": [["id": "window", "title": "Counter"]]]],
                    "elements": [["id": "\(revision):e1", "pid": 4242, "role": "AXButton",
                                  "title": "Counter", "enabled": true, "window_id": "window",
                                  "value": state.read().deliveries,
                                  "frame": ["x": 2, "y": 2, "width": 4, "height": 4]]]]])
            case "act":
                state.update { $0.attempts += 1; $0.preflightReady = true }
                let attempt = state.read().attempts
                if attempt == 1 { await deliveryGate.wait() }
                defer { state.update { $0.preflightReturned = true } }
                do {
                    guard let rawAction = params["action"] as? [String: Any], let id = params["action_id"] as? String else {
                        throw NSError(domain: "replay_invalid_action", code: 1)
                    }
                    let action = try ActionContract.validate(rawAction)
                    guard action["element_id"] as? String == "synthetic-\(state.read().observations):e1" else {
                        throw NSError(domain: "replay_stale_target", code: 1)
                    }
                    if trace.fault == "stale_target" && attempt == 1 {
                        state.update { $0.rejected += 1 }
                        return reply(["ok": false].merging(ActionContract.nativeFailure(
                            NSError(domain: "synthetic", code: 1), code: "stale_target", outcome: "rejected")) { _, new in new })
                    }
                    let claim = try lease.commit { try lease.actionReceipts.begin(id: id, payload: ["action": action]) }
                    guard case .new(let token) = claim else { throw NSError(domain: "replay_duplicate", code: 1) }
                    do {
                        try TaskOwnership.$actionReceipt.withValue(token) {
                            try TaskOwnership.commit { state.update { $0.deliveries += 1 } }
                        }
                        // Delivery is deliberately NOT task completion proof.
                        let result: [String: Any] = ["action_type": "press", "verified": false,
                            "outcome": "delivered_unconfirmed", "verification_scope": "delivery_only"]
                        try token.complete(result)
                        let receipt = token.receipt
                        state.update { $0.receiptStates.append(receipt["state"] as! String) }
                        if trace.fault == "malformed_result" {
                            return reply(["ok": true, "result": ["outcome": "verified", "verified": true]])
                        }
                        return reply(["ok": true, "result": result, "action_receipt": ["action_id": id,
                            "state": receipt["state"]!, "terminal": receipt["terminal"]!]])
                    } catch {
                        token.fail(error, code: "cancelled")
                        throw error
                    }
                } catch {
                    if lease.state == .running { state.update { $0.errors.append("native_delivery_failure") } }
                    return reply(["ok": false, "error": "Synthetic delivery rejected", "error_code": "cancelled"])
                }
            case "action_receipt":
                state.update { $0.receipts += 1 }
                // Exercise actual native generation/revision/receipt validation.
                return await bridge.handle(request)
            case "completion_gate":
                return await bridge.handle(request)
            default:
                state.update { $0.errors.append("unexpected_bridge_method") }
                return reply(["ok": false, "error": "Unexpected synthetic method"])
            }
        }, pipeWriteOperation: { fd, pointer, count in
            state.update { $0.writeCalls += 1 }
            return Darwin.write(fd, pointer, min(count, 7))
        })
        runtime.onEvent = { event in
            switch event {
            case .status(let value): state.update { $0.statuses.append(value) }
            case .completed: state.update { $0.terminal.append("completed") }
            case .stopped: state.update { $0.terminal.append("stopped") }
            case .failed(let message): state.update { $0.terminal.append("failed"); $0.errors.append(message) }
            default: break
            }
        }
        let executable = try worker(trace.id)
        defer { modelGate.signal(); deliveryGate.signal(); stoppingGate.signal(); runtime.stop() }
        try runtime.start(task: "Press the synthetic counter once",
            display: DisplayDescriptor(id: 1, name: "synthetic", x: 0, y: 0, width: 10, height: 10, isMain: false),
            runtimeURL: executable, openClawURL: executable, geminiAPIKey: "", lease: lease)
        let context = "trace=\(trace.id) seed=\(seed)"
        for event in trace.events {
            scheduler.schedule(at: event.tick, name: event.event) {
                switch event.event {
                case "model_response":
                    let ready = await waitForSeededLifecycleCondition(timeout: .seconds(10)) { state.read().modelReady || !state.read().terminal.isEmpty }
                    XCTAssertTrue(ready && state.read().modelReady, "Model boundary unavailable; \(context): \(state.read().errors)")
                    modelGate.signal()
                    let preflight = await waitForSeededLifecycleCondition(timeout: .seconds(10)) { state.read().preflightReady || !state.read().terminal.isEmpty }
                    XCTAssertTrue(preflight && state.read().preflightReady, "Preflight unavailable; \(context): \(state.read().errors)")
                case "native_delivery":
                    deliveryGate.signal()
                    let returned = await waitForSeededLifecycleCondition(timeout: .seconds(10)) { state.read().preflightReturned || !state.read().terminal.isEmpty }
                    XCTAssertTrue(returned, "Delivery did not settle; \(context)")
                case "stop":
                    runtime.stop() // Revokes authority before releasing suspended preflight.
                    deliveryGate.signal()
                    stoppingGate.signal()
                default: XCTFail("Unknown fixed replay event")
                }
            }
        }
        await scheduler.runAll()
        let terminal = await waitForSeededLifecycleCondition(timeout: .seconds(10)) { !state.read().terminal.isEmpty }
        XCTAssertTrue(terminal, "No terminal callback; \(context): \(state.read().errors)")
        let drained = await waitForSeededLifecycleCondition(timeout: .seconds(5)) { lease.state == .retired }
        XCTAssertTrue(drained, "Owned work failed to drain; \(context)")
        let result = state.read()
        XCTAssertEqual(result.terminal.count, 1, context)
        XCTAssertEqual(result.handlers, result.settledHandlers, "Unsettled bridge callbacks; \(context)")
        XCTAssertEqual(result.requests, result.settledRequests, "A request never settled; \(context)")
        XCTAssertEqual(result.duplicateCallbacks, 0, "A request settled more than once; \(context)")
        XCTAssertLessThanOrEqual(result.deliveries, 1, "Duplicate mutation; \(context)")
        XCTAssertGreaterThan(result.writeCalls, 32, "Real partial writes not exercised; \(context)")
        XCTAssertTrue(result.receiptStates.allSatisfy { $0 == "unconfirmed" }, context)
        if trace.id == "stop_at_delivery" {
            XCTAssertEqual(result.deliveries, scheduler.trace[1] == "stop" ? 0 : 1, context)
            XCTAssertEqual(result.terminal, ["stopped"], context)
        } else if ["process_exit", "disconnected", "malformed_result"].contains(trace.fault) {
            XCTAssertEqual(result.deliveries, 1, context)
            XCTAssertEqual(result.terminal, ["failed"], context)
            XCTAssertEqual(result.verifications, 0, context)
            XCTAssertEqual(result.planning, 1, context)
            XCTAssertEqual(result.attempts, 1, context)
            if trace.fault != "process_exit" {
                XCTAssertTrue(result.statuses.contains("replay:unresolved_mutation"), "Unknown mutation released its guard; \(context)")
                XCTAssertTrue(result.statuses.contains("replay:phase:reconciling"), context)
            }
        } else {
            XCTAssertEqual(result.errors, [], context)
            XCTAssertEqual(result.terminal, ["completed"], context)
            XCTAssertEqual(result.deliveries, 1, context)
            XCTAssertEqual(result.attempts, trace.fault == "stale_target" ? 2 : 1, context)
            XCTAssertEqual(result.verifications, 1, context)
            XCTAssertEqual(result.planning, trace.fault == "stale_target" ? 3 : 2, "Extra planning or repair calls; \(context)")
            XCTAssertEqual(result.receipts, trace.fault == "lost_reply" ? 1 : 0, context)
            if trace.fault == "lost_reply" { XCTAssertTrue(result.statuses.contains("replay:receipt_reconciliation"), context) }
            XCTAssertTrue(result.statuses.contains("replay:phase:reconciling"), context)
        }
        return Replay(order: scheduler.trace, deliveries: result.deliveries, attempts: result.attempts,
                      terminal: result.terminal, receipts: result.receipts, verifications: result.verifications)
    }

    private func worker(_ trace: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-replay-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("runtime")
        let worker = project.appendingPathComponent("Tests/ReplayLab/runtime_worker.py")
        let python = ProcessInfo.processInfo.environment["TASKPILOT_REPLAY_PYTHON"] ?? "/opt/homebrew/bin/python3.11"
        guard FileManager.default.isExecutableFile(atPath: python), !python.contains("\n") else {
            throw NSError(domain: "replay_python_3_11_required", code: 1)
        }
        // Fixed fixture arguments; no user task data or shell interpolation.
        try "#!\(python)\nimport runpy, sys\nsys.path.insert(0, \(String(reflecting: worker.deletingLastPathComponent().path)))\nsys.argv = [\(String(reflecting: worker.path)), \(String(reflecting: trace)), \(String(reflecting: directory.path))]\nrunpy.run_path(sys.argv[0], run_name='__main__')\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}
