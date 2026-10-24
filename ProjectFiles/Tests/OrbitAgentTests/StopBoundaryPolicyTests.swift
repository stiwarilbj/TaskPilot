import Foundation
import XCTest
@testable import OrbitAgent

final class StopBoundaryPolicyTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let id: String
            let request: String
            let reference: String?
            let expected: [String]
        }
        let version: Int
        let cases: [Case]
    }

    func testSharedDetectionFixturesAndExactUTF8Sources() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stop-before-boundaries.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(fixture.version, StopBoundaryPolicy.version)
        for item in fixture.cases {
            var references: [AgentTaskInputReference] = []
            if let value = item.reference,
               let range = item.request.range(of: value) {
                let start = item.request[..<range.lowerBound].utf8.count
                references = [AgentTaskInputReference(kind: .text, utf8Start: start,
                    utf8Length: value.utf8.count, value: value)]
            }
            let result = StopBoundaryPolicy.detect(in: item.request, exactInputReferences: references)
            XCTAssertEqual(result.map(\.action), item.expected, item.id)
            let bytes = Array(item.request.utf8)
            for boundary in result {
                let source = String(decoding: bytes[boundary.utf8Range], as: UTF8.self)
                XCTAssertEqual(source, boundary.source, item.id)
            }
        }
    }

    func testFinalControlIsRejectedAndUnidentifiedTargetIsHeld() throws {
        let boundaries = StopBoundaryPolicy.detect(in: "Draft the email, but don't send it.")
        XCTAssertThrowsError(try StopBoundaryPolicy.validate(action: ["type": "click", "element_id": "send"],
            boundaries: boundaries, targetRole: "AXButton", targetLabels: ["Send"], targetIsReliable: true)) { error in
            XCTAssertEqual((error as? StopBoundaryViolation)?.code, "stop_boundary_rejected")
        }
        XCTAssertThrowsError(try StopBoundaryPolicy.validate(action: ["type": "click", "x": 500, "y": 500],
            boundaries: boundaries)) { error in
            XCTAssertEqual((error as? StopBoundaryViolation)?.code, "stop_boundary_uncertain")
        }
        XCTAssertNoThrow(try StopBoundaryPolicy.validate(action: ["type": "click", "element_id": "body"],
            boundaries: boundaries, targetRole: "AXTextArea", targetLabels: ["Message body"], targetIsReliable: true))
        XCTAssertThrowsError(try StopBoundaryPolicy.validate(action: ["type": "run_command", "command": "./send.sh"],
            boundaries: boundaries))
    }

    func testApplicationAndWindowNamesDoNotTurnUnrelatedControlsIntoSend() throws {
        let boundaries = StopBoundaryPolicy.detect(in: "Draft the email, but don't send it")
        XCTAssertNoThrow(try StopBoundaryPolicy.validate(action: ["type": "click", "element_id": "save"],
            boundaries: boundaries, targetRole: "AXButton", targetLabels: ["Save", "Email draft", "Mail"],
            targetIsReliable: true, applicationName: "Mail"))
        XCTAssertThrowsError(try StopBoundaryPolicy.validate(action: ["type": "click", "element_id": "continue"],
            boundaries: boundaries, targetRole: "AXButton", targetLabels: ["Continue", "Mail"],
            targetIsReliable: true, applicationName: "Mail")) { error in
            XCTAssertEqual((error as? StopBoundaryViolation)?.code, "stop_boundary_uncertain")
        }
        XCTAssertThrowsError(try StopBoundaryPolicy.validate(action: ["type": "click", "element_id": "continue"],
            boundaries: boundaries, targetRole: "AXButton", targetLabels: ["Continue", "Send message"],
            targetIsReliable: true, applicationName: "Mail")) { error in
            XCTAssertEqual((error as? StopBoundaryViolation)?.code, "stop_boundary_rejected")
        }
    }

    func testPlaceYourOrderControlMatchesPurchaseBoundary() throws {
        let boundaries = StopBoundaryPolicy.detect(in: "Prepare the cart but don't place your order")
        XCTAssertThrowsError(try StopBoundaryPolicy.validate(action: ["type": "click", "element_id": "order"],
            boundaries: boundaries, targetRole: "AXButton", targetLabels: ["Place your order"],
            targetIsReliable: true)) { error in
            XCTAssertEqual((error as? StopBoundaryViolation)?.code, "stop_boundary_rejected")
        }
    }

    func testCorrectionUpdatesNativeBoundaryAtItsInstructionRevision() throws {
        let lease = TaskLease(taskRequest: "Draft the email, but don't send it.")
        XCTAssertEqual(lease.activeStopBoundaries.map(\.action), ["send"])
        let correctionID = UUID()
        let correction = TaskInstructionCorrection(id: correctionID, revision: 1,
            submission: AgentTaskSubmission(request: "You may send it now."))
        try lease.beginInstructionCorrection(id: correctionID.uuidString, revision: 1)
        try lease.applyInstructionCorrection(id: correctionID.uuidString, revision: 1, correction: correction)
        XCTAssertEqual(lease.currentInstructionRevision, 1)
        XCTAssertTrue(try lease.stopBoundaries(for: 1).isEmpty)
        XCTAssertThrowsError(try lease.stopBoundaries(for: 0))
    }

    func testShortcutsAndDefaultButtonActivationAreHeldOrRejected() throws {
        let boundaries = StopBoundaryPolicy.detect(in: "Fill out the form, but don't submit it.")
        XCTAssertThrowsError(try StopBoundaryPolicy.validate(action: ["type": "key", "key": "space"],
            boundaries: boundaries, targetRole: "AXDefaultButton", targetLabels: ["Submit"], targetIsReliable: true)) { error in
            XCTAssertEqual((error as? StopBoundaryViolation)?.code, "stop_boundary_rejected")
        }
        XCTAssertThrowsError(try StopBoundaryPolicy.validate(action: ["type": "key", "key": "p", "modifiers": ["command"]],
            boundaries: boundaries, targetRole: "AXTextArea", targetLabels: ["Message"], targetIsReliable: true)) { error in
            XCTAssertEqual((error as? StopBoundaryViolation)?.code, "stop_boundary_uncertain")
        }
        XCTAssertThrowsError(try StopBoundaryPolicy.validate(action: ["type": "key", "key": "return"],
            boundaries: boundaries, targetRole: "AXTextArea", targetLabels: ["Message"], targetIsReliable: true)) { error in
            XCTAssertEqual((error as? StopBoundaryViolation)?.code, "stop_boundary_uncertain")
        }
        XCTAssertThrowsError(try StopBoundaryPolicy.validate(action: ["type": "key", "key": "return"],
            boundaries: boundaries, targetRole: "AXTextArea", targetLabels: ["Terminal"], targetIsReliable: true,
            applicationName: "Terminal")) { error in
            XCTAssertEqual((error as? StopBoundaryViolation)?.code, "stop_boundary_uncertain")
        }
    }

    func testTaskCommitGateRejectsBeforeReceiptDispatch() throws {
        let lease = TaskLease(taskRequest: "Draft the email but don't send it.")
        let id = UUID().uuidString.lowercased()
        guard case .new(let token) = try lease.actionReceipts.begin(id: id, payload: [
            "action": ["type": "click", "element_id": "send"], "instruction_revision": 0
        ]) else { return XCTFail("Expected a new receipt") }
        var delivered = 0
        try TaskOwnership.$current.withValue(lease) {
            try TaskOwnership.$actionReceipt.withValue(token) {
                try TaskOwnership.$instructionRevision.withValue(0) {
                    try TaskOwnership.$stopBoundaryPreflight.withValue({ _, _ in
                        throw StopBoundaryViolation.rejected("Send")
                    }) {
                        XCTAssertThrowsError(try TaskOwnership.commit { delivered += 1 })
                    }
                }
            }
        }
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(token.receipt["state"] as? String, "pending")
    }

    func testAlreadyDispatchedActionFinishesWhileCorrectionWaits() throws {
        let lease = TaskLease(taskRequest: "Draft the email but don't send it.")
        let correctionID = UUID()
        let actionID = UUID().uuidString.lowercased()
        guard case .new(let token) = try lease.actionReceipts.begin(id: actionID, payload: [
            "action": ["type": "click", "element_id": "save"], "instruction_revision": 0
        ]) else { return XCTFail("Expected a new receipt") }
        var preflightCount = 0
        var deliveryCount = 0
        try TaskOwnership.$current.withValue(lease) {
            try TaskOwnership.$actionReceipt.withValue(token) {
                try TaskOwnership.$instructionRevision.withValue(0) {
                    try TaskOwnership.$stopBoundaryPreflight.withValue({ _, _ in preflightCount += 1 }) {
                        try TaskOwnership.commit { deliveryCount += 1 }
                        try lease.beginInstructionCorrection(id: correctionID.uuidString, revision: 1)
                        try TaskOwnership.commit { deliveryCount += 1 }
                    }
                }
            }
        }
        XCTAssertEqual(preflightCount, 1)
        XCTAssertEqual(deliveryCount, 2)
        XCTAssertEqual(token.receipt["state"] as? String, "dispatched")
    }
}
