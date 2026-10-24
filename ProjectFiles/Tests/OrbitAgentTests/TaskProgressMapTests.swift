import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import OrbitAgent

final class TaskProgressMapTests: XCTestCase {
    private func requirement(_ id: String, _ source: String, in request: String,
                             state: AgentTaskProgressRequirementState = .pending,
                             active: Bool = false,
                             evidence: [AgentTaskProgressEvidence] = []) -> AgentTaskProgressRequirement {
        let haystack = Array(request.utf8)
        let needle = Array(source.utf8)
        var ranges: [Range<Int>] = []
        if !needle.isEmpty, needle.count <= haystack.count {
            for start in 0...(haystack.count - needle.count) where
                haystack[start..<(start + needle.count)].elementsEqual(needle) {
                ranges.append(start..<(start + needle.count))
            }
        }
        return AgentTaskProgressRequirement(id: id, sourceRanges: ranges, state: state,
                                            active: active, evidence: evidence)
    }

    private func map(_ request: String, _ requirements: [AgentTaskProgressRequirement],
                     lifecycle: AgentTaskProgressLifecycle = .running) -> TaskProgressMap {
        var result = TaskProgressMap(request: request, generationID: "generation")
        result.revision = 1
        result.lifecycle = lifecycle
        result.activeRequirementIDs = requirements.filter(\.active).map(\.id)
        result.requirements = requirements
        return result
    }

    func testIndependentClausesKeepOriginalWordingAndProofState() throws {
        let request = "Create the report, save it in Downloads, and leave it open."
        let clauses = TaskProgressSourceMapper.clauses(for: map(request, [
            requirement("r1", "Create the report", in: request, state: .proven),
            requirement("r2", "save it in Downloads", in: request, active: true),
            requirement("r3", "leave it open", in: request)
        ]))
        XCTAssertEqual(clauses.count, 3)
        XCTAssertEqual(clauses.map { String(request[$0.range]) },
                       ["Create the report", "save it in Downloads", "leave it open"])
        XCTAssertEqual(clauses.map(\.state), [.confirmed, .active, .pending])
    }

    func testOverlappingAndRepeatedSourcesUseConservativeGroups() throws {
        let overlapRequest = "Save the report, then review the report."
        let overlapping = TaskProgressSourceMapper.clauses(for: map(overlapRequest, [
            requirement("r1", "Save the report", in: overlapRequest, state: .proven),
            requirement("r2", "the report", in: overlapRequest, state: .pending)
        ]))
        XCTAssertEqual(overlapping.count, 2)
        XCTAssertEqual(String(overlapRequest[overlapping[0].range]), "Save the report")
        XCTAssertEqual(overlapping[0].state, .pending)

        let repeatedRequest = "save as draft, then save as draft."
        let repeated = TaskProgressSourceMapper.clauses(for: map(repeatedRequest, [
            requirement("r1", "save as draft", in: repeatedRequest, state: .proven),
            requirement("r2", "save as draft", in: repeatedRequest, state: .pending)
        ]))
        XCTAssertEqual(repeated.count, 2)
        XCTAssertTrue(repeated.allSatisfy { $0.state == .pending })
        XCTAssertTrue(repeated.allSatisfy { $0.requirementIDs == ["r1", "r2"] })
        XCTAssertEqual(Set(repeated.map(\.id)).count, repeated.count)
    }

    func testUnicodePunctuationAndUnmappedTextRemainIntact() throws {
        let request = "Create “résumé”—then save it. Extra instruction stays here."
        let clauses = TaskProgressSourceMapper.clauses(for: map(request, [
            requirement("r1", "Create “résumé”", in: request, state: .proven),
            requirement("r2", "save it", in: request)
        ]))
        XCTAssertEqual(clauses.map { String(request[$0.range]) }, ["Create “résumé”", "save it"])
        XCTAssertEqual(request, "Create “résumé”—then save it. Extra instruction stays here.")
        let decomposed = "re\u{301}sume\u{301}"
        XCTAssertTrue(TaskProgressSourceMapper.clauses(for: map("résumé", [
            requirement("r1", decomposed, in: "résumé", state: .proven)
        ])).isEmpty)
    }

    func testSnapshotRequiresExactGenerationAndStrictSafeEvidenceFields() throws {
        let base: [String: Any] = [
            "kind": "task_progress", "task_generation_id": "generation", "revision": 2,
            "version": 3, "lifecycle": "running", "whole_request_coverage": "pending",
            "active_requirement_ids": ["r1"],
            "requirements": [["id": "r1", "source_ranges": [[0, 15]], "state": "pending", "active": true, "evidence": []]],
            "result_objects": [], "batch": NSNull()
        ]
        let parsed = try XCTUnwrap(AgentTaskProgressSnapshot.parse(base, generationID: "generation"))
        XCTAssertEqual(parsed.revision, 2)
        XCTAssertEqual(parsed.requirements.first?.active, true)
        XCTAssertNil(AgentTaskProgressSnapshot.parse(base, generationID: "other"))

        var staleAssociation = base
        staleAssociation["active_requirement_ids"] = ["r9"]
        XCTAssertNil(AgentTaskProgressSnapshot.parse(staleAssociation, generationID: "generation"))
        var zeroRevision = base
        zeroRevision["revision"] = 0
        XCTAssertNil(AgentTaskProgressSnapshot.parse(zeroRevision, generationID: "generation"))

        var secret = base
        secret["requirements"] = [["id": "r1", "source_ranges": [[0, 15]], "state": "proven", "active": false,
                                    "evidence": [["label": "Verified", "detail": "value", "entered_text": "secret"]]]]
        secret["active_requirement_ids"] = []
        XCTAssertNil(AgentTaskProgressSnapshot.parse(secret, generationID: "generation"))
    }

    func testBatchSnapshotRequiresTaskOwnedInputsAndCurrentRequirementAssociations() throws {
        let base: [String: Any] = [
            "kind": "task_progress", "task_generation_id": "generation", "revision": 5,
            "version": 3, "lifecycle": "running", "whole_request_coverage": "pending",
            "active_requirement_ids": ["r1"],
            "requirements": [
                ["id": "r1", "source_ranges": [[0, 1]], "state": "pending", "active": true, "evidence": []],
                ["id": "r2", "source_ranges": [[2, 3]], "state": "pending", "active": false, "evidence": []]
            ],
            "result_objects": [],
            "batch": [
                "version": 1, "needs_declaration": false, "handled_count": 0,
                "items": [
                    ["id": "b1", "input_id": "input_0123456789abcdef_1", "reference": "/Inputs/January.pdf",
                     "kind": "file", "state": "working", "active": true,
                     "current_step": "Working on: Write the requested output.",
                     "outcomes": [["id": "r1", "label": "Write the requested output"]]],
                    ["id": "b2", "input_id": "input_0123456789abcdef_2", "reference": "/Inputs/February.pdf",
                     "kind": "file", "state": "waiting", "active": false,
                     "current_step": "Waiting for its requested outcomes.",
                     "outcomes": [["id": "r2", "label": "Write the requested output"]]]
                ]
            ]
        ]
        let parsed = try XCTUnwrap(AgentTaskProgressSnapshot.parse(base, generationID: "generation"))
        XCTAssertEqual(parsed.batch?.items.map(\.state), [.working, .waiting])
        XCTAssertEqual(parsed.batch?.handledCount, 0)

        var forgedHandledCount = base
        forgedHandledCount["batch"] = [
            "version": 1, "needs_declaration": false, "handled_count": 1,
            "items": (base["batch"] as! [String: Any])["items"]!
        ]
        XCTAssertNil(AgentTaskProgressSnapshot.parse(forgedHandledCount, generationID: "generation"))

        var staleRequirement = base
        var batch = staleRequirement["batch"] as! [String: Any]
        var items = batch["items"] as! [[String: Any]]
        items[0]["outcomes"] = [["id": "r9", "label": "Write the requested output"]]
        batch["items"] = items
        staleRequirement["batch"] = batch
        XCTAssertNil(AgentTaskProgressSnapshot.parse(staleRequirement, generationID: "generation"))
    }

    func testBatchStatesSuspendWorkingAcrossPauseAndMarkTerminalWorkUnfinished() {
        let item = AgentTaskBatchItem(id: "b1", inputID: "input_0123456789abcdef_1",
                                      reference: "/Inputs/January.pdf", kind: "file", state: .working,
                                      active: true, currentStep: "Working", outcomes: [])
        XCTAssertEqual(TaskBatchProgressPresentation.state(for: item, lifecycle: .paused), .waiting)
        XCTAssertEqual(TaskBatchProgressPresentation.state(for: item, lifecycle: .waitingForUser), .waiting)
        XCTAssertEqual(TaskBatchProgressPresentation.state(for: item, lifecycle: .failed), .unfinished)
        let verified = AgentTaskBatchItem(id: "b1", inputID: item.inputID, reference: item.reference,
                                          kind: item.kind, state: .verified, active: false,
                                          currentStep: "Verified", outcomes: [])
        XCTAssertEqual(TaskBatchProgressPresentation.state(for: verified, lifecycle: .stopped), .verified)
    }

    func testSameFilenameLabelsUseShortestDifferingParentSuffix() {
        let items = [
            AgentTaskBatchItem(id: "b1", inputID: "input_0123456789abcdef_1", reference: "/Users/one/January/report.pdf",
                               kind: "file", state: .waiting, active: false, currentStep: "Waiting", outcomes: []),
            AgentTaskBatchItem(id: "b2", inputID: "input_0123456789abcdef_2", reference: "/Users/two/February/report.pdf",
                               kind: "file", state: .waiting, active: false, currentStep: "Waiting", outcomes: [])
        ]
        XCTAssertEqual(TaskBatchProgressPresentation.labels(for: items), ["January/report.pdf", "February/report.pdf"])
    }

    func testOnlyConfirmedFileEvidenceCanOfferFinderReveal() throws {
        let base: [String: Any] = [
            "kind": "task_progress", "task_generation_id": "generation", "revision": 3,
            "version": 3, "lifecycle": "completed", "whole_request_coverage": "audited",
            "active_requirement_ids": [],
            "requirements": [["id": "r1", "source_ranges": [[0, 15]], "state": "proven", "active": false,
                              "evidence": [["label": "File contents matched", "detail": "/tmp/report.txt",
                                            "reveal_path": "/tmp/report.txt"]]]],
            "result_objects": [], "batch": NSNull()
        ]
        let parsed = try XCTUnwrap(AgentTaskProgressSnapshot.parse(base, generationID: "generation"))
        XCTAssertEqual(parsed.requirements[0].evidence[0].revealPath, "/tmp/report.txt")

        var missingProof = base
        missingProof["requirements"] = [["id": "r1", "source_ranges": [[0, 15]], "state": "proven", "active": false,
                                          "evidence": []]]
        XCTAssertNil(AgentTaskProgressSnapshot.parse(missingProof, generationID: "generation"))

        var invalid = base
        invalid["requirements"] = [["id": "r1", "source_ranges": [[0, 15]], "state": "pending", "active": false,
                                     "evidence": [["label": "File contents matched", "detail": "/tmp/report.txt",
                                                   "reveal_path": "/tmp/report.txt"]]]]
        XCTAssertNil(AgentTaskProgressSnapshot.parse(invalid, generationID: "generation"))
    }

    func testPausedAndWaitingLifecycleSuppressActiveHighlight() throws {
        let request = "Enter the code and save the report."
        let active = requirement("r1", "save the report", in: request, active: true)
        XCTAssertEqual(TaskProgressSourceMapper.clauses(for: map(request, [active], lifecycle: .paused)).first?.state, .pending)
        XCTAssertEqual(TaskProgressSourceMapper.clauses(for: map(request, [active], lifecycle: .waitingForUser)).first?.state, .pending)
    }

    func testTerminalLifecycleDoesNotConfirmPendingWorkAndInvalidatedProofNeedsRecheck() throws {
        let request = "Save the report and leave it open."
        let pending = requirement("r1", "Save the report", in: request)
        for lifecycle in [AgentTaskProgressLifecycle.completed, .failed, .stopped] {
            XCTAssertEqual(TaskProgressSourceMapper.clauses(for: map(request, [pending], lifecycle: lifecycle)).first?.state,
                           .pending)
        }
        let invalidated = requirement("r1", "Save the report", in: request, state: .invalidated)
        XCTAssertEqual(TaskProgressSourceMapper.clauses(for: map(request, [invalidated], lifecycle: .failed)).first?.state,
                       .needsRecheck)
    }

    func testWholeRequestCoverageCannotProveAnUnfinishedPhrase() throws {
        let request = "Create the report and save it."
        var taskMap = map(request, [requirement("r1", "save it", in: request)], lifecycle: .completed)
        taskMap.wholeRequestCoverage = "audited"
        XCTAssertEqual(TaskProgressSourceMapper.clauses(for: taskMap).first?.state, .pending)
    }

    func testByteRangesMustRespectUTF8BoundariesAndTaskLength() throws {
        let base: [String: Any] = [
            "kind": "task_progress", "task_generation_id": "generation", "revision": 4,
            "version": 3, "lifecycle": "running", "whole_request_coverage": "pending",
            "active_requirement_ids": [],
            "requirements": [["id": "r1", "source_ranges": [[0, 1]], "state": "pending", "active": false, "evidence": []]],
            "result_objects": [], "batch": NSNull()
        ]
        XCTAssertNotNil(AgentTaskProgressSnapshot.parse(base, generationID: "generation"))
        var malformed = base
        malformed["requirements"] = [["id": "r1", "source_ranges": [[1, 2]], "state": "pending", "active": false, "evidence": []]]
        let snapshot = try XCTUnwrap(AgentTaskProgressSnapshot.parse(malformed, generationID: "generation"))
        XCTAssertFalse(TaskProgressSourceMapper.sourceRangesAreValid(snapshot.requirements[0].sourceRanges, in: "é"))
    }

    @MainActor
    func testRendersCollapsedAndExpandedNarrowWindowFixtures() throws {
        let request = "Create the report, save it in Downloads, and leave it open."
        let requirements = [
            requirement("r1", "Create the report", in: request, state: .proven,
                        evidence: [AgentTaskProgressEvidence(label: "File contents matched",
                                                            detail: "/tmp/taskpilot-synthetic-report.txt",
                                                            revealPath: "/tmp/taskpilot-synthetic-report.txt")]),
            requirement("r2", "save it in Downloads", in: request, active: true),
            requirement("r3", "leave it open", in: request)
        ]
        let progress = map(request, requirements)
        let fixtures: [(String, Bool, [String])] = [
            ("collapsed", false, []),
            ("expanded", true, []),
            ("evidence", true, ["r1"])
        ]

        for (name, initiallyExpanded, selectedRequirementIDs) in fixtures {
            let view = TaskProgressMapView(map: progress,
                                           surface: Color(nsColor: .windowBackgroundColor),
                                           border: Color(nsColor: .separatorColor),
                                           accent: .blue,
                                           initiallyExpanded: initiallyExpanded,
                                           initiallySelectedRequirementIDs: selectedRequirementIDs)
                .frame(width: 320, height: 560, alignment: .topLeading)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 560)
            hostingView.layoutSubtreeIfNeeded()

            let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 2_000, "\(name) fixture should render visible SwiftUI content")
            try png.write(to: URL(fileURLWithPath: "/tmp/taskpilot-progress-map-\(name).png"))
        }
    }
}
