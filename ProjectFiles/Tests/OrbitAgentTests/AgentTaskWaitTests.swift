import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import OrbitAgent

final class AgentTaskWaitTests: XCTestCase {
    private func message(_ changes: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = [
            "kind": "task_wait",
            "task_generation_id": "generation-a",
            "version": 1,
            "revision": 1,
            "operation_id": 1,
            "phase": "model_response",
            "last_confirmed": "No confirmed result yet.",
            "waiting_for": "The model’s response",
            "attention": "none"
        ]
        result.merge(changes) { _, new in new }
        return result
    }

    func testParsesCurrentBoundedTaskSnapshot() throws {
        let snapshot = try XCTUnwrap(AgentTaskWaitSnapshot.parse(message(), generationID: "generation-a"))
        XCTAssertEqual(snapshot.phase, .modelResponse)
        XCTAssertEqual(snapshot.waitingFor, "The model’s response")
        XCTAssertEqual(snapshot.attention.description, "Nothing needed.")
        XCTAssertEqual(snapshot.disclosureIdentity, "generation-a:1")
    }

    func testRejectsStaleMalformedAndUnboundedSnapshots() {
        XCTAssertNil(AgentTaskWaitSnapshot.parse(message(), generationID: "generation-b"))
        XCTAssertNil(AgentTaskWaitSnapshot.parse(message(["revision": true]), generationID: "generation-a"))
        XCTAssertNil(AgentTaskWaitSnapshot.parse(message(["operation_id": 0]), generationID: "generation-a"))
        XCTAssertNil(AgentTaskWaitSnapshot.parse(message(["phase": "unknown"]), generationID: "generation-a"))
        XCTAssertNil(AgentTaskWaitSnapshot.parse(message(["attention": "password=private"]), generationID: "generation-a"))
        XCTAssertNil(AgentTaskWaitSnapshot.parse(message(["waiting_for": "\n"]), generationID: "generation-a"))
        XCTAssertNil(AgentTaskWaitSnapshot.parse(message(["waiting_for": String(repeating: "x", count: 241)]), generationID: "generation-a"))
        XCTAssertNil(AgentTaskWaitSnapshot.parse(message(["unexpected": "field"]), generationID: "generation-a"))
    }

    func testLocalPauseAndSecureInputUpdateAttentionWithoutChangingOperationIdentity() throws {
        let original = try XCTUnwrap(AgentTaskWaitSnapshot.parse(message(), generationID: "generation-a"))
        let paused = original.withLocalState(phase: .paused, waitingFor: "TaskPilot is paused",
                                             attention: .resume, identity: "local-paused-1")
        XCTAssertEqual(paused.operationID, original.operationID)
        XCTAssertEqual(paused.attention.description, "Resume TaskPilot to continue.")
        XCTAssertNotEqual(paused.disclosureIdentity, original.disclosureIdentity)

        let secure = original.withLocalState(phase: .secureInput, waitingFor: "Secure input in TaskPilot",
                                             attention: .secureInput, identity: "local-input-1")
        XCTAssertEqual(secure.attention.description, "Enter the requested secure information below.")
    }

    func testDisclosureIdentityChangesOnlyForNewOperationOrLocalState() throws {
        let original = try XCTUnwrap(AgentTaskWaitSnapshot.parse(message(), generationID: "generation-a"))
        let sameOperation = try XCTUnwrap(AgentTaskWaitSnapshot.parse(message([
            "revision": 2, "phase": "reconciling", "waiting_for": "The page to finish loading"
        ]), generationID: "generation-a"))
        let nextOperation = try XCTUnwrap(AgentTaskWaitSnapshot.parse(message(["operation_id": 2]), generationID: "generation-a"))
        XCTAssertEqual(original.disclosureIdentity, sameOperation.disclosureIdentity)
        XCTAssertNotEqual(original.disclosureIdentity, nextOperation.disclosureIdentity)
    }

    @MainActor
    func testDisclosureRendersExpandedDetailsAtNarrowWidthsAndWithReducedMotion() throws {
        let snapshot = AgentTaskWaitSnapshot(generationID: "generation-a", revision: 1, operationID: 2,
            phase: .reconciling, lastConfirmed: "File contents matched: budget summary.pdf",
            waitingFor: "The Export dialog to appear", attention: .none)
        for (name, width, reduceMotion) in [("wide", CGFloat(360), false), ("narrow", CGFloat(230), true)] {
            let view = TaskWaitDisclosureView(status: "Waiting for the page to finish loading…",
                snapshot: snapshot, symbol: AnyView(Image(systemName: "hourglass")),
                expandedIdentity: .constant(snapshot.disclosureIdentity), reduceMotionOverride: reduceMotion)
                .frame(width: width, alignment: .leading)
                .padding(12)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: width + 24, height: 240)
            hostingView.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1_000, "\(name) wait detail fixture should render its wrapped rows")
            try png.write(to: URL(fileURLWithPath: "/tmp/taskpilot-wait-disclosure-\(name).png"))
        }
    }
}
