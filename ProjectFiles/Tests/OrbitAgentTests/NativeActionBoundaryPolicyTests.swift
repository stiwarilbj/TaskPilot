import Foundation
import XCTest
@testable import OrbitAgent

final class NativeActionBoundaryPolicyTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Expected: Decodable {
            let disposition: String
            let reason: String
        }
        struct Case: Decodable {
            let id: String
            let probes: [NativeActionBoundaryPolicy.Probe]
            let expected: Expected
        }
        let version: Int
        let stage_order: [String]
        let cases: [Case]
    }

    func testSharedCrossLanguageFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Contracts/Fixtures/native-action-boundary-policy.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.version, NativeActionBoundaryPolicy.version)
        XCTAssertEqual(fixture.stage_order, NativeActionBoundaryPolicy.stageOrder)
        for item in fixture.cases {
            let decision = NativeActionBoundaryPolicy.decision(for: item.probes)
            XCTAssertEqual(decision.disposition.rawValue, item.expected.disposition, item.id)
            XCTAssertEqual(decision.reason.rawValue, item.expected.reason, item.id)
        }
    }

    func testMalformedProbeFieldsFailClosedAtTheFixtureBoundary() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(NativeActionBoundaryPolicy.Probe.self,
            from: Data(#"{"stage":"stop_before","disposition":"allow","reason":"none","extra":1}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(NativeActionBoundaryPolicy.Probe.self,
            from: Data(#"{"stage":"stop_before","disposition":"allow"}"#.utf8)))
    }

    func testNativeChecksRunInFixedOrderAndStopAtFirstFailure() {
        var calls: [String] = []
        let context = NativeActionBoundaryPolicy.Context(action: ["type": "write_file"],
            constraints: .init(generationID: "task", instructionRevision: 2,
                workingDocumentRevision: 1, targetBindingRevision: 4, stopBoundaries: [],
                targetBindings: [], allowWorkingSelectionSaveExport: false, alreadyDispatched: false),
            resolvedTarget: nil)
        let checks: [NativeActionBoundaryPolicy.Check] = [
            .init(.destinationIdentity) { _ in calls.append("destination") },
            .init(.selectionScope) { _ in
                calls.append("selection")
                throw AccessibilityActionError.workingSelectionTargetMismatch
            },
            .init(.stopBefore) { _ in calls.append("stop") }
        ]
        let result = NativeActionBoundaryPolicy.evaluate(checks, context: context)
        XCTAssertEqual(calls, ["stop", "selection"])
        XCTAssertEqual(result.decision, .init(disposition: .refreshEvidence, reason: .selectionScopeChanged))
        XCTAssertTrue(result.failure is AccessibilityActionError)
    }

    func testResolvedAmbiguityRequestsFreshEvidence() {
        let context = NativeActionBoundaryPolicy.Context(action: ["type": "click"],
            constraints: .init(generationID: "task", instructionRevision: 0,
                workingDocumentRevision: nil, targetBindingRevision: nil, stopBoundaries: [],
                targetBindings: [], allowWorkingSelectionSaveExport: false, alreadyDispatched: false),
            resolvedTarget: nil)
        let result = NativeActionBoundaryPolicy.evaluate([
            .init(.resolvedTarget) { context in
                context.resolvedTarget = .init(kind: .coordinate, processID: 42, role: nil,
                    identity: nil, reliable: false, ambiguous: true)
            }
        ], context: context)
        XCTAssertEqual(result.decision, .init(disposition: .refreshEvidence, reason: .ambiguousTarget))
        XCTAssertTrue(result.failure is AccessibilityActionError)
    }

    func testExistingStopBoundaryErrorIsPreservedBeforeReceiptDispatch() throws {
        let lease = TaskLease(taskRequest: "Draft the email but don't send it.")
        let id = UUID().uuidString.lowercased()
        guard case .new(let token) = try lease.actionReceipts.begin(id: id, payload: [
            "action": ["type": "click", "element_id": "send"], "instruction_revision": 0
        ]) else { return XCTFail("Expected a new receipt") }
        var delivered = false
        try TaskOwnership.$current.withValue(lease) {
            try TaskOwnership.$actionReceipt.withValue(token) {
                try TaskOwnership.$instructionRevision.withValue(0) {
                    try TaskOwnership.$stopBoundaryPreflight.withValue({ _, _ in
                        throw StopBoundaryViolation.rejected("Send")
                    }) {
                        XCTAssertThrowsError(try TaskOwnership.commit { delivered = true }) { error in
                            XCTAssertEqual((error as? StopBoundaryViolation)?.code, "stop_boundary_rejected")
                        }
                    }
                }
            }
        }
        XCTAssertFalse(delivered)
        XCTAssertEqual(token.receipt["state"] as? String, "pending")
    }

    func testFileAndAccessibilityRoutesUseTheSameSelectionGate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.txt")
        let lease = TaskLease(taskRequest: "Edit only the selected passage")
        for type in ["write_file", "click"] {
            let action: [String: Any] = type == "write_file"
                ? ["type": type, "path": destination.path, "content": "result"]
                : ["type": type, "element_id": "selected-control"]
            guard case .new(let token) = try lease.actionReceipts.begin(id: UUID().uuidString.lowercased(),
                payload: ["action": action, "instruction_revision": 0]) else {
                return XCTFail("Expected a new receipt")
            }
            var delivered = false
            try TaskOwnership.$current.withValue(lease) {
                try TaskOwnership.$actionReceipt.withValue(token) {
                    try TaskOwnership.$selectionScopePreflight.withValue({ _ in
                        throw AccessibilityActionError.workingSelectionTargetMismatch
                    }) {
                        XCTAssertThrowsError(try {
                            if type == "write_file" {
                                _ = try BoundFileOperation(destination).replace(with: Data("result".utf8),
                                    append: false, mustBeAbsent: true)
                            } else {
                                try AutomationTargetPolicy.deliver(preflight: {}, event: { delivered = true })
                            }
                        }()) { error in
                            guard let error = error as? AccessibilityActionError,
                                  case .workingSelectionTargetMismatch = error else {
                                return XCTFail("Expected the same selection rejection for \(type)")
                            }
                        }
                    }
                }
            }
            XCTAssertFalse(delivered)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(token.receipt["state"] as? String, "pending")
        }
    }

    func testBridgePreflightAndFinalDispatchUseTheSameOrderedPolicies() throws {
        let lease = TaskLease(taskRequest: "Draft the email but don't send it.")
        let id = UUID().uuidString.lowercased()
        guard case .new(let token) = try lease.actionReceipts.begin(id: id, payload: [
            "action": ["type": "click", "element_id": "save"], "instruction_revision": 0
        ]) else { return XCTFail("Expected a new receipt") }
        var calls: [String] = []
        let bind: ([String: Any]) throws -> Void = { _ in calls.append("document") }
        let selection: ([String: Any]) throws -> Void = { _ in calls.append("selection") }
        let targetChoice: ([String: Any]) throws -> Void = { _ in calls.append("choice") }
        let resolved: ([String: Any]) throws -> NativeActionBoundaryPolicy.ResolvedTarget? = { _ in
            calls.append("target")
            return .init(kind: .accessibility, processID: 42, role: "AXButton",
                         identity: "target", reliable: true, ambiguous: false)
        }
        let destination = NativeActionBoundaryPolicy.Check(.destinationIdentity) { _ in
            calls.append("destination")
        }
        let expectedPass = ["stop", "choice", "document", "selection", "target"]
        try TaskOwnership.$current.withValue(lease) {
            try TaskOwnership.$actionReceipt.withValue(token) {
                try TaskOwnership.$instructionRevision.withValue(0) {
                    try TaskOwnership.$stopBoundaryPreflight.withValue({ _, _ in calls.append("stop") }) {
                        try TaskOwnership.$targetChoicePreflight.withValue(targetChoice) {
                            try TaskOwnership.$documentBindingPreflight.withValue(bind) {
                                try TaskOwnership.$selectionScopePreflight.withValue(selection) {
                                    try TaskOwnership.$resolvedTargetPreflight.withValue(resolved) {
                                        try TaskOwnership.preflightAction()
                                        XCTAssertEqual(token.receipt["state"] as? String, "pending")
                                        XCTAssertEqual(calls, expectedPass)
                                        try TaskOwnership.commit(policyChecks: [destination]) {}
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(calls, expectedPass + ["stop", "choice", "document", "selection", "destination", "target"])
        XCTAssertEqual(token.receipt["state"] as? String, "dispatched")
    }
}
