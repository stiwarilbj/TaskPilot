import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import OrbitAgent

final class AgentTargetChoiceTests: XCTestCase {
    private func message(_ changes: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = [
            "kind": "target_choice_required",
            "task_generation_id": "generation-a",
            "instruction_revision": 0,
            "working_document_revision": 0,
            "version": AgentTargetChoiceProtocol.version,
            "request_id": "11111111-1111-4111-8111-111111111111",
            "binding_revision": 1,
            "reference": "Reports",
            "requirement_id": "r1",
            "scope": "destination",
            "candidates": [
                ["id": "input_1234567890abcdef_1", "kind": "folder", "label": "Reports", "detail": "/Users/test/Downloads"],
                ["id": "input_1234567890abcdef_2", "kind": "folder", "label": "Reports", "detail": "/Users/test/Project Archive"]
            ],
            "inspect_again_allowed": true
        ]
        value.merge(changes) { _, new in new }
        return value
    }

    func testParsesBoundedGroundedCandidateRequest() throws {
        let request = try XCTUnwrap(AgentTargetChoiceRequest.parse(message(), generationID: "generation-a",
            instructionRevision: 0, workingDocumentRevision: 0, targetBindingRevision: 0))
        XCTAssertEqual(request.scope, "destination")
        XCTAssertEqual(request.reference, "Reports")
        XCTAssertEqual(request.candidates.count, 2)
        XCTAssertNotEqual(request.candidates[0].detail, request.candidates[1].detail)
    }

    func testRejectsStaleMalformedAndIndistinguishableCandidates() {
        XCTAssertNil(AgentTargetChoiceRequest.parse(message(), generationID: "generation-b",
            instructionRevision: 0, workingDocumentRevision: 0, targetBindingRevision: 0))
        XCTAssertNil(AgentTargetChoiceRequest.parse(message(["instruction_revision": 1]), generationID: "generation-a",
            instructionRevision: 0, workingDocumentRevision: 0, targetBindingRevision: 0))
        XCTAssertNil(AgentTargetChoiceRequest.parse(message(["version": true]), generationID: "generation-a",
            instructionRevision: 0, workingDocumentRevision: 0, targetBindingRevision: 0))
        XCTAssertNil(AgentTargetChoiceRequest.parse(message(["scope": "unknown"]), generationID: "generation-a",
            instructionRevision: 0, workingDocumentRevision: 0, targetBindingRevision: 0))
        XCTAssertNil(AgentTargetChoiceRequest.parse(message(["candidates": [
            ["id": "input_1234567890abcdef_1", "kind": "folder", "label": "Reports", "detail": "/same"],
            ["id": "input_1234567890abcdef_2", "kind": "folder", "label": "Reports", "detail": "/same"]
        ]]), generationID: "generation-a", instructionRevision: 0, workingDocumentRevision: 0,
            targetBindingRevision: 0))
        XCTAssertNil(AgentTargetChoiceRequest.parse(message(["scope": "destination", "candidates": [
            ["id": "11111111-1111-4111-8111-111111111111", "kind": "document", "label": "Reports", "detail": "Numbers"] ,
            ["id": "22222222-2222-4222-8222-222222222222", "kind": "document", "label": "Archive", "detail": "Numbers"]
        ]]), generationID: "generation-a", instructionRevision: 0, workingDocumentRevision: 0,
            targetBindingRevision: 0))
    }

    func testTargetBindingIsSerializedAndRecheckedAfterSelection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("report.txt")
        try Data("report".utf8).write(to: input)
        var metadata = stat()
        XCTAssertEqual(Darwin.lstat(input.path, &metadata), 0)
        let identity: [String: Any] = [
            "device": Int64(metadata.st_dev), "inode": Int64(metadata.st_ino),
            "mode": Int64(metadata.st_mode & S_IFMT), "size": Int64(metadata.st_size),
            "mtime_ns": Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_mtimespec.tv_nsec)
        ]
        let candidateID = "input_1234567890abcdef_1"
        let alternateCandidateID = "input_abcdef1234567890_2"
        let choiceID = UUID().uuidString.lowercased()
        let binding: [String: Any] = ["kind": "file", "path": input.path, "identity": identity]
        let record: [String: Any] = [
            "reference": "report.txt", "requirement_id": "r1", "scope": "source",
            "candidate_id": candidateID, "kind": "file", "binding": binding,
            "binding_revision": 1, "label": "report.txt", "detail": folder.path
        ]
        let lease = TaskLease()
        lease.pause()
        try lease.beginTargetChoice(id: choiceID, instructionRevision: 0, workingDocumentRevision: 0,
            revision: 1, candidateIDs: [candidateID, alternateCandidateID], reference: "report.txt", requirementID: "r1", scope: "source")
        XCTAssertFalse(lease.claimCompletion(instructionRevision: 0), "An unresolved choice must hold completion")
        let installed = try lease.applyTargetChoice(id: choiceID, candidateID: candidateID,
            instructionRevision: 0, workingDocumentRevision: 0, revision: 1, bindingRecord: record) { _ in nil }
        XCTAssertNil(installed)
        XCTAssertEqual(lease.currentTargetBindingRevision, 1)
        XCTAssertFalse(lease.state == .running, "Selecting a target must not resume a paused task")

        XCTAssertNoThrow(try lease.validateTargetBindings(revision: 1, supplied: [record],
            action: ["type": "read_file", "path": input.path], requirementIDs: ["r1"],
            intendedTarget: "Read report.txt as the selected source"))
        XCTAssertThrowsError(try lease.validateTargetBindings(revision: 1, supplied: [record],
            action: ["type": "read_file", "path": folder.appendingPathComponent("other.txt").path],
            requirementIDs: ["r1"], intendedTarget: "Read report.txt as the selected source"))
        XCTAssertThrowsError(try lease.validateTargetBindings(revision: 1, supplied: [record],
            action: ["type": "read_file", "path": "report.txt"],
            requirementIDs: ["r1"], intendedTarget: "Read report.txt as the selected source"),
            "Relative operands must not bypass a selected absolute target binding")
        try FileManager.default.removeItem(at: input)
        XCTAssertThrowsError(try lease.validateTargetBindings(revision: 1, supplied: [record],
            action: ["type": "read_file", "path": input.path], requirementIDs: ["r1"],
            intendedTarget: "Read report.txt as the selected source"))
        lease.retire()
    }

    func testDocumentBindingRejectsConflictingFilesystemOperands() throws {
        let documentID = UUID().uuidString.lowercased()
        let alternativeID = UUID().uuidString.lowercased()
        let choiceID = UUID().uuidString.lowercased()
        let lease = TaskLease()
        try lease.beginTargetChoice(id: choiceID, instructionRevision: 0, workingDocumentRevision: 0,
            revision: 1, candidateIDs: [documentID, alternativeID], reference: "Budget",
            requirementID: "r1", scope: "document")
        let record: [String: Any] = [
            "reference": "Budget", "requirement_id": "r1", "scope": "document",
            "candidate_id": documentID, "kind": "document", "binding": [
                "kind": "document", "selection_id": documentID
            ], "binding_revision": 1, "label": "Budget", "detail": "Numbers"
        ]
        _ = try lease.applyTargetChoice(id: choiceID, candidateID: documentID,
            instructionRevision: 0, workingDocumentRevision: 0, revision: 1,
            bindingRecord: record) { revision in ["state": "active", "revision": Int(revision)] }
        XCTAssertThrowsError(try lease.validateTargetBindings(revision: 1, supplied: [record],
            action: ["type": "read_file", "path": "/tmp/unrelated.xlsx"],
            requirementIDs: ["r1"], intendedTarget: "Edit Budget in Numbers"))
        lease.retire()
    }

    func testWorkingDocumentChangeSupersedesPendingChoiceAndFencesReplacement() throws {
        let lease = TaskLease()
        let choiceID = UUID().uuidString.lowercased()
        try lease.beginTargetChoice(id: choiceID, instructionRevision: 0, workingDocumentRevision: 0,
            revision: 1, candidateIDs: ["first", "second"], reference: "Reports",
            requirementID: "r1", scope: "destination")
        let updateID = UUID().uuidString.lowercased()
        try lease.beginWorkingDocumentUpdate(id: updateID, revision: 1)
        XCTAssertFalse(lease.hasPendingTargetChoice)
        XCTAssertTrue(lease.hasPendingWorkingDocumentUpdate)
        XCTAssertThrowsError(try lease.beginTargetChoice(id: UUID().uuidString.lowercased(),
            instructionRevision: 0, workingDocumentRevision: 0, revision: 1,
            candidateIDs: ["first", "second"], reference: "Reports",
            requirementID: "r1", scope: "destination"))
        lease.cancelWorkingDocumentUpdate(id: updateID)
        lease.retire()
    }

    @MainActor
    func testAttentionCardRendersLongCandidateDetailsAtNarrowWidth() throws {
        let request = try XCTUnwrap(AgentTargetChoiceRequest.parse(message(), generationID: "generation-a",
            instructionRevision: 0, workingDocumentRevision: 0, targetBindingRevision: 0))
        let view = TargetChoiceAttentionCardView(request: request, canChoose: true, canInspectAgain: true,
            surface: Color.white, border: Color.gray, accent: Color.blue,
            choose: { _ in }, inspectAgain: {})
            .frame(width: 245, alignment: .leading)
            .padding(12)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 269, height: 360)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
    }
}
