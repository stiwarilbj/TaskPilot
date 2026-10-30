import CryptoKit
import Foundation
import XCTest
@testable import OrbitAgent

final class AgentTaskChangeLensTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testDiffShowsLineNumbersAndCollapsesUnchangedContext() throws {
        let before = "title\nkeep one\nold introduction\nkeep two\nkeep three\nkeep four\nkeep five\nold ending"
        let after = "title\nkeep one\nnew introduction\nkeep two\nkeep three\nkeep four\nkeep five\nnew ending"
        guard case .hunks(let hunks) = AgentTaskChangeLensDiff.build(before: before, after: after) else {
            return XCTFail("Expected a bounded text diff")
        }
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].before.filter(\.changed).map(\.text), ["old introduction"])
        XCTAssertEqual(hunks[0].after.filter(\.changed).map(\.text), ["new introduction"])
        XCTAssertEqual(hunks[0].before.first?.number, 1)
        XCTAssertTrue(hunks[0].before.contains(where: { !$0.changed && $0.text == "keep one" }))
        XCTAssertEqual(hunks[1].after.filter(\.changed).map(\.text), ["new ending"])
    }

    func testDiffMarksNewFileAndBoundsLargeLineCounts() throws {
        guard case .hunks(let created) = AgentTaskChangeLensDiff.build(before: nil, after: "one\ntwo") else {
            return XCTFail("Expected a new-file comparison")
        }
        XCTAssertEqual(created.first?.before, [])
        XCTAssertEqual(created.first?.after.map(\.text), ["one", "two"])
        let huge = Array(repeating: "x", count: 1_001).joined(separator: "\n")
        XCTAssertEqual(AgentTaskChangeLensDiff.build(before: huge, after: huge), .unavailable("This text has too many lines for a bounded comparison."))
    }

    func testScopeCheckerFlagsOutOfRegionAndReportsUnclearBoundaries() throws {
        let before = "# Introduction\nold intro\n# Body\nold body\n"
        let within = "# Introduction\nnew intro\n# Body\nold body\n"
        guard case .hunks(let withinHunks) = AgentTaskChangeLensDiff.build(before: before, after: within),
              case .hunks(let outsideHunks) = AgentTaskChangeLensDiff.build(before: before,
                after: "# Introduction\nnew intro\n# Body\nnew body\n") else { return XCTFail("Expected comparisons") }
        XCTAssertEqual(AgentTaskChangeLensScope.assess(request: "Change only the introduction.", before: before, hunks: withinHunks), .checked)
        XCTAssertEqual(AgentTaskChangeLensScope.assess(request: "Change only the introduction.", before: before, hunks: outsideHunks), .potentialMismatch)
        XCTAssertEqual(AgentTaskChangeLensScope.assess(request: "Only change \"old intro\".", before: before, hunks: withinHunks), .checked)
        XCTAssertEqual(AgentTaskChangeLensScope.assess(request: "Only change the introduction.", before: "# Introduction\na\n# Introduction\nb", hunks: withinHunks), .imprecise)
        XCTAssertEqual(AgentTaskChangeLensScope.assess(request: "Improve the document.", before: before, hunks: withinHunks), .unrestricted)
    }

    func testSnapshotRequiresConfirmedNativeWriteAndMatchingContents() throws {
        let actionID = UUID().uuidString.lowercased()
        let path = "/tmp/change-lens.txt"
        let before = Data("before\n".utf8), after = Data("after\n".utf8)
        let beforeHash = sha256(before), afterHash = sha256(after)
        let generationID = UUID().uuidString
        let request: [String: Any] = ["request_id": "request-1", "instruction_revision": 0,
            "params": ["action_id": actionID,
                "action": ["type": "write_file", "path": path, "content": "after\n"],
                "target_requirement_ids": ["r1"]]]
        let result: [String: Any] = ["action_type": "write_file", "path": path,
            "file_identity": digest, "file_version": String(repeating: "b", count: 64),
            "parent_identity": String(repeating: "c", count: 64), "file_sha256": afterHash,
            "verification_scope": "file_write", "verified": true, "outcome": "verified"]
        let response: [String: Any] = ["ok": true, "kind": "bridge_response", "request_id": "request-1",
            "task_generation_id": generationID, "instruction_revision": 0, "result": result,
            "action_receipt": ["action_id": actionID, "state": "confirmed", "terminal": true]]
        var candidate: [String: Any] = ["action_id": actionID, "path": path,
            "file_identity": digest, "file_version": String(repeating: "b", count: 64),
            "parent_identity": String(repeating: "c", count: 64), "before_version": digest,
            "before_sha256": beforeHash, "before_data": before, "after_data": after,
            "requirement_ids": ["r1"], "created": false]

        let accepted = try XCTUnwrap(AgentTaskChangeLensSnapshot.validatedCandidate(candidate,
            response: response, request: request, generationID: generationID,
            instructionRevision: 0, knownActionIDs: [actionID]))
        XCTAssertEqual(accepted.beforeText, "before\n")
        XCTAssertEqual(accepted.afterText, "after\n")

        var unconfirmed = response
        unconfirmed["action_receipt"] = ["action_id": actionID, "state": "unconfirmed", "terminal": true]
        XCTAssertNil(AgentTaskChangeLensSnapshot.validatedCandidate(candidate, response: unconfirmed,
            request: request, generationID: accepted.generationID, instructionRevision: 0,
            knownActionIDs: [actionID]))
        var staleGeneration = response
        staleGeneration["task_generation_id"] = UUID().uuidString
        XCTAssertNil(AgentTaskChangeLensSnapshot.validatedCandidate(candidate, response: staleGeneration,
            request: request, generationID: accepted.generationID, instructionRevision: 0,
            knownActionIDs: [actionID]))
        var staleRequest = response
        staleRequest["request_id"] = "another-request"
        XCTAssertNil(AgentTaskChangeLensSnapshot.validatedCandidate(candidate, response: staleRequest,
            request: request, generationID: accepted.generationID, instructionRevision: 0,
            knownActionIDs: [actionID]))
        var staleRevision = response
        staleRevision["instruction_revision"] = 1
        XCTAssertNil(AgentTaskChangeLensSnapshot.validatedCandidate(candidate, response: staleRevision,
            request: request, generationID: accepted.generationID, instructionRevision: 0,
            knownActionIDs: [actionID]))
        candidate["after_data"] = Data("different\n".utf8)
        XCTAssertNil(AgentTaskChangeLensSnapshot.validatedCandidate(candidate, response: response,
            request: request, generationID: accepted.generationID, instructionRevision: 0,
            knownActionIDs: [actionID]))
    }

    func testNewFileSnapshotAndBrokenLineageAreExplicit() throws {
        let first = AgentTaskChangeLensSnapshot(generationID: "task", instructionRevision: 0,
            actionID: "a", path: "/tmp/a.txt", fileIdentity: digest, fileVersion: String(repeating: "b", count: 64),
            parentIdentity: String(repeating: "c", count: 64), beforeVersion: nil, beforeText: nil,
            afterText: "created", requirementIDs: ["r1"], created: true, chainReset: false)
        let chained = AgentTaskChangeLensSnapshot(generationID: "task", instructionRevision: 1,
            actionID: "b", path: "/tmp/a.txt", fileIdentity: String(repeating: "d", count: 64), fileVersion: String(repeating: "e", count: 64),
            parentIdentity: String(repeating: "c", count: 64), beforeVersion: first.fileVersion, beforeText: "created",
            afterText: "edited", requirementIDs: ["r2"], created: false, chainReset: false)
        XCTAssertEqual(first.extendingLineage(with: chained).beforeText, nil)
        XCTAssertEqual(first.extendingLineage(with: chained).afterText, "edited")
        let intervening = AgentTaskChangeLensSnapshot(generationID: "task", instructionRevision: 2,
            actionID: "c", path: "/tmp/a.txt", fileIdentity: String(repeating: "f", count: 64), fileVersion: String(repeating: "a", count: 64),
            parentIdentity: String(repeating: "c", count: 64), beforeVersion: String(repeating: "f", count: 64),
            beforeText: "external edit", afterText: "our edit", requirementIDs: ["r3"], created: false, chainReset: false)
        let reset = first.extendingLineage(with: intervening)
        XCTAssertTrue(reset.chainReset)
        XCTAssertEqual(reset.beforeText, "external edit")
    }

    func testCorrectionPassageMustBeUniqueOrPreciselyAnchored() throws {
        let base = AgentTaskChangeLensSnapshot(generationID: "task", instructionRevision: 0,
            actionID: "a", path: "/tmp/a.txt", fileIdentity: digest, fileVersion: String(repeating: "b", count: 64),
            parentIdentity: String(repeating: "c", count: 64), beforeVersion: digest, beforeText: "",
            afterText: "first\nshared passage\nsecond\nother\nshared passage\nlast", requirementIDs: [],
            created: false, chainReset: false)
        XCTAssertFalse(base.uniquelyIdentifies(passage: "shared passage", beforeAnchor: "", afterAnchor: ""))
        XCTAssertTrue(base.uniquelyIdentifies(passage: "shared passage", beforeAnchor: "first", afterAnchor: "second"))
        XCTAssertFalse(base.uniquelyIdentifies(passage: "shared passage", beforeAnchor: "wrong", afterAnchor: "second"))
        XCTAssertTrue(base.uniquelyIdentifies(passage: "other", beforeAnchor: "second", afterAnchor: "shared passage"))
    }

    func testCorrectionPassageMatchingKeepsExactLinesAndAnchorBoundaries() {
        let cases: [(source: String, passage: String, before: String, after: String, expected: Bool)] = [
            ("first\nmiddle\nlast", "first", "", "middle", true),
            ("first\nmiddle\nlast", "first", "missing", "middle", false),
            ("first\nmiddle\nlast", "last", "middle", "", true),
            ("first\nmiddle\nlast", "last", "middle", "missing", false),
            ("first\nmiddle\nlast", "first\nmiddle\nlast", "", "", true),
            ("first\nmiddle\nlast", "middle", "first", "wrong", false),
            ("first\nalmost middle\nlast", "middle", "first", "last", false),
            ("first\nmiddle \nlast", "middle", "first", "last", false),
            ("first\nMiddle\nlast", "middle", "first", "last", false),
            ("first\nmiddle\nlast", "", "", "", false),
            ("first\nmiddle\nlast", "middle\0", "", "", false),
            ("", "first\nsecond", "", "", false),
            ("first\r\nmiddle\r\nlast", "middle", "first\r", "last", false),
            ("first\r\nmiddle\r\nlast", "middle\r", "first\r", "last", true),
            ("😀\ncafe\u{301}\n終", "café", "😀", "終", true),
            ("first\n\nlast", "\n", "", "", false),
        ]
        for (index, item) in cases.enumerated() {
            XCTAssertEqual(passageSnapshot(item.source).uniquelyIdentifies(passage: item.passage,
                beforeAnchor: item.before, afterAnchor: item.after), item.expected, "Case \(index)")
        }
    }

    func testOverlappingCorrectionPassagesStillRequireOneAnchoredOccurrence() {
        let snapshot = passageSnapshot("a\na\na")
        XCTAssertFalse(snapshot.uniquelyIdentifies(passage: "a\na", beforeAnchor: "", afterAnchor: ""))
        XCTAssertTrue(snapshot.uniquelyIdentifies(passage: "a\na", beforeAnchor: "a", afterAnchor: ""))
        XCTAssertTrue(snapshot.uniquelyIdentifies(passage: "a\na", beforeAnchor: "", afterAnchor: "a"))
        XCTAssertFalse(snapshot.uniquelyIdentifies(passage: "a\na", beforeAnchor: "a", afterAnchor: "a"))
    }

    func testLongRepeatedParagraphsAreUniqueOnlyWithDistinguishingAnchors() {
        let paragraph = ["before", "shared first", "shared second", "after"]
        var lines = Array(repeating: paragraph, count: 1_000).flatMap { $0 }
        lines[2_000] = "chosen before"
        lines[2_003] = "chosen after"
        let snapshot = passageSnapshot(lines.joined(separator: "\n"))
        let passage = "shared first\nshared second"
        XCTAssertFalse(snapshot.uniquelyIdentifies(passage: passage, beforeAnchor: "", afterAnchor: ""))
        XCTAssertFalse(snapshot.uniquelyIdentifies(passage: passage, beforeAnchor: "before", afterAnchor: "after"))
        XCTAssertTrue(snapshot.uniquelyIdentifies(passage: passage, beforeAnchor: "chosen before", afterAnchor: "chosen after"))
        XCTAssertFalse(snapshot.uniquelyIdentifies(passage: passage, beforeAnchor: "chosen before", afterAnchor: "after"))
        XCTAssertFalse(snapshot.uniquelyIdentifies(passage: passage, beforeAnchor: "missing", afterAnchor: "after"))
    }

    func testLineEndingNormalizationAndEmptyTextAreHandled() throws {
        guard case .hunks(let hunks) = AgentTaskChangeLensDiff.build(
            before: "one\r\nold\r\nthree\r\n", after: "one\nnew\nthree\n") else {
            return XCTFail("Expected a bounded CRLF comparison")
        }
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].before.filter(\.changed).map(\.text), ["old"])
        XCTAssertEqual(hunks[0].after.filter(\.changed).map(\.text), ["new"])
        XCTAssertEqual(AgentTaskChangeLensDiff.build(before: "", after: ""), .hunks([]))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func passageSnapshot(_ text: String) -> AgentTaskChangeLensSnapshot {
        .init(generationID: "task", instructionRevision: 0, actionID: "a", path: "/tmp/a.txt",
              fileIdentity: digest, fileVersion: digest, parentIdentity: digest,
              beforeVersion: digest, beforeText: "", afterText: text, requirementIDs: [],
              created: false, chainReset: false)
    }
}
