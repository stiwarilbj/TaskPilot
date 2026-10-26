import XCTest
@testable import OrbitAgent

final class TaskRemixTests: XCTestCase {
    private struct FixtureFile: Decodable {
        struct Case: Decodable {
            let id: String
            let request: String
            let values: [String]
        }
        let version: Int
        let cases: [Case]
    }

    func testSharedLiteralFixturesMatchSwiftRemixRecognition() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = testsDirectory.appendingPathComponent("Fixtures/remix-input-cases.json")
        let fixtures = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(fixtures.version, 1)

        for item in fixtures.cases {
            let draft = TaskComposerDraft(remixing: AgentTaskSubmission(request: item.request))
            XCTAssertEqual(draft.references.map(\.value), item.values, item.id)
            XCTAssertEqual(draft.expandedText, item.request, item.id)
        }
    }

    func testHistoryRemixRestoresExplicitReferencesAndRecognizesUnambiguousLiterals() throws {
        let url = "https://example.test/a%20b?q=%24HOME#part"
        let request = "Export \"final report.pdf\" to /tmp/Reports, then visit \(url)."
        let urlRange = try XCTUnwrap(request.range(of: url))
        let urlStart = request[..<urlRange.lowerBound].utf8.count
        let submission = AgentTaskSubmission(request: request, exactInputReferences: [
            AgentTaskInputReference(kind: .url, utf8Start: urlStart,
                                    utf8Length: url.utf8.count, value: url)
        ])

        let draft = TaskComposerDraft(remixing: submission)

        XCTAssertEqual(draft.expandedText, request)
        XCTAssertEqual(draft.references.map(\.value), ["final report.pdf", "/tmp/Reports", url])
        XCTAssertEqual(draft.references.map(\.kind), [.text, .text, .url])
        XCTAssertTrue(draft.proseText.contains("Export "))
        XCTAssertTrue(draft.proseText.contains(", then visit ."))
    }

    func testQuotedMultilineLiteralAndUnambiguousFilenameArePreserved() {
        let literal = "  First line\nRésumé 🙂  "
        let request = "Type “\(literal)” into Notes and save as final.v2.txt."
        let draft = TaskComposerDraft(remixing: AgentTaskSubmission(request: request))

        XCTAssertEqual(draft.expandedText, request)
        XCTAssertTrue(draft.references.contains { $0.value == literal && $0.kind == .text })
        XCTAssertTrue(draft.references.contains { $0.value == "final.v2.txt" && $0.kind == .text })
    }

    func testMalformedSavedRangesAreNotTurnedIntoChips() {
        let request = "Open /tmp/report.pdf"
        let bad = AgentTaskInputReference(version: 1, kind: .file, utf8Start: 5,
                                          utf8Length: 4, value: "wrong")
        let draft = TaskComposerDraft(remixing: AgentTaskSubmission(request: request,
                                                                     exactInputReferences: [bad]))
        XCTAssertEqual(draft.expandedText, request)
        XCTAssertFalse(draft.references.contains { $0.value == "wrong" })
    }

    func testRemixComparisonReportsReplacementAdditionAndRemoval() {
        let original = TaskComposerReference(kind: .file, value: "/tmp/old.pdf")
        let removed = TaskComposerReference(kind: .url, value: "https://old.example")
        let moved = TaskComposerReference(kind: .text, value: "final.pdf")
        let baseline = TaskComposerDraft(segments: [
            .text("Export "), .reference(original), .text(" to "), .reference(removed),
            .text(" as "), .reference(moved)
        ])
        let replaced = TaskComposerReference(id: original.id, kind: .file, value: "/tmp/new.pdf")
        let movedCopy = TaskComposerReference(kind: .text, value: "final.pdf")
        let added = TaskComposerReference(kind: .folder, value: "/tmp/Archive")
        let current = TaskComposerDraft(segments: [
            .text("Export "), .reference(movedCopy), .text(" to "), .reference(replaced),
            .text(" as "), .reference(added)
        ])

        let review = TaskRemixReview.make(baseline: baseline, current: current)

        XCTAssertFalse(review.wordingChanged)
        XCTAssertEqual(review.changes.map(\.kind), [.replaced, .removed, .added])
        XCTAssertEqual(review.changes[0].oldReference?.value, original.value)
        XCTAssertEqual(review.changes[0].newReference?.value, replaced.value)
    }

    func testRemixComparisonReportsAnOccurrenceSpecificRoleOnlyChange() {
        let original = TaskComposerReference(kind: .file, value: "/tmp/budget.xlsx", userRole: .source)
        let baseline = TaskComposerDraft(segments: [.text("Summarize "), .reference(original)])
        let changed = TaskComposerReference(id: original.id, kind: original.kind, value: original.value,
                                           userRole: .referenceExample)
        let current = TaskComposerDraft(segments: [.text("Summarize "), .reference(changed)])

        let review = TaskRemixReview.make(baseline: baseline, current: current)

        XCTAssertEqual(review.changes.map(\.kind), [.roleChanged])
        XCTAssertEqual(review.changes.first?.oldReference?.userRole, .source)
        XCTAssertEqual(review.changes.first?.newReference?.userRole, .referenceExample)
    }

    func testRemixComparisonFindsRoleChangeAfterClipboardCreatesNewOccurrenceID() {
        let original = TaskComposerReference(kind: .file, value: "/tmp/budget.xlsx", userRole: .source)
        let copied = TaskComposerReference(kind: .file, value: original.value, userRole: .destination)
        XCTAssertNotEqual(original.id, copied.id)

        let review = TaskRemixReview.make(
            baseline: TaskComposerDraft(segments: [.text("Use "), .reference(original)]),
            current: TaskComposerDraft(segments: [.text("Use "), .reference(copied)])
        )

        XCTAssertEqual(review.changes.map(\.kind), [.roleChanged])
        XCTAssertEqual(review.changes.first?.oldReference?.value, original.value)
        XCTAssertEqual(review.changes.first?.oldReference?.userRole, .source)
        XCTAssertEqual(review.changes.first?.newReference?.userRole, .destination)
    }

    func testRemixComparisonDoesNotGuessAmbiguousDuplicateRolePairings() {
        let baselineReferences = [
            TaskComposerReference(kind: .file, value: "/tmp/report.txt", userRole: .source),
            TaskComposerReference(kind: .file, value: "/tmp/report.txt", userRole: .destination)
        ]
        let currentReferences = [
            TaskComposerReference(kind: .file, value: "/tmp/report.txt", userRole: .referenceExample),
            TaskComposerReference(kind: .file, value: "/tmp/report.txt", userRole: nil)
        ]
        let review = TaskRemixReview.make(
            baseline: TaskComposerDraft(segments: baselineReferences.map(TaskComposerSegment.reference)),
            current: TaskComposerDraft(segments: currentReferences.map(TaskComposerSegment.reference))
        )

        XCTAssertEqual(review.changes.map(\.kind), [.removed, .removed, .added, .added])
    }

    func testRemixReviewCacheReusesSemanticComparisonAndTracksExplicitRoles() {
        var cache = TaskRemixReviewCache()
        let sessionID = UUID()
        let id = UUID()
        let baselineReference = TaskComposerReference(id: id, kind: .file,
            value: "/tmp/report.txt", userRole: .source)
        let baseline = TaskComposerDraft(segments: [.text("Edit "), .reference(baselineReference)])
        let currentReference = TaskComposerReference(id: id, kind: .file,
            value: "/tmp/report.txt", userRole: .destination, presentedRole: .source,
            roleOrigin: .chosen, inferredRole: .source)
        let current = TaskComposerDraft(segments: [.text("Edit "), .reference(currentReference)])

        let first = cache.review(sessionID: sessionID, baseline: baseline, current: current)
        let second = cache.review(sessionID: sessionID, baseline: baseline, current: current)
        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.buildCount, 1)

        let presentationOnlyUpdate = TaskComposerDraft(segments: [.text("Edit "), .reference(
            TaskComposerReference(id: id, kind: .file, value: "/tmp/report.txt",
                userRole: .destination, presentedRole: .referenceExample,
                roleOrigin: .chosen, inferredRole: .referenceExample))])
        _ = cache.review(sessionID: sessionID, baseline: baseline, current: presentationOnlyUpdate)
        XCTAssertEqual(cache.buildCount, 1)

        let changedRole = TaskComposerDraft(segments: [.text("Edit "), .reference(
            TaskComposerReference(id: id, kind: .file, value: "/tmp/report.txt", userRole: nil))])
        let updated = cache.review(sessionID: sessionID, baseline: baseline, current: changedRole)
        XCTAssertEqual(updated.changes.map(\.kind), [.roleChanged])
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testRemixCacheReuses128MovedChipComparisonAcrossStatusRefreshes() {
        let originalReferences = (0..<128).map { index in
            TaskComposerReference(kind: .file, value: "/tmp/Reports/report-\(index).txt")
        }
        let baseline = TaskComposerDraft(segments: originalReferences.map(TaskComposerSegment.reference))
        let moved = TaskComposerDraft(segments: originalReferences.reversed().map(TaskComposerSegment.reference))
        var cache = TaskRemixReviewCache()
        let sessionID = UUID()
        let start = DispatchTime.now().uptimeNanoseconds
        let review = cache.review(sessionID: sessionID, baseline: baseline, current: moved)
        let calculationTime = DispatchTime.now().uptimeNanoseconds - start
        for _ in 0..<50 {
            _ = cache.review(sessionID: sessionID, baseline: baseline, current: moved)
        }
        XCTAssertTrue(review.changes.isEmpty)
        XCTAssertEqual(cache.buildCount, 1)
        print("Remix cache benchmark: 128 moved chips, one fresh comparison in \(Double(calculationTime) / 1_000_000) ms; 50 cached refreshes")
    }

    func testReferenceReorderingAloneDoesNotShowChangedInputs() {
        let first = TaskComposerReference(kind: .file, value: "/tmp/a.pdf")
        let second = TaskComposerReference(kind: .folder, value: "/tmp/Reports")
        let baseline = TaskComposerDraft(segments: [.reference(first), .text(" "), .reference(second)])
        let movedFirst = TaskComposerReference(kind: .file, value: first.value)
        let movedSecond = TaskComposerReference(kind: .folder, value: second.value)
        let reordered = TaskComposerDraft(segments: [.reference(movedSecond), .text(" "), .reference(movedFirst)])

        XCTAssertEqual(TaskRemixReview.make(baseline: baseline, current: reordered),
                       TaskRemixReview(changes: [], wordingChanged: false))
    }

    func testExactInputValidationSupportsTextAndRejectsMismatchedRanges() throws {
        let value = "Résumé — exact value"
        let request = "Type \(value)"
        let start = "Type ".utf8.count
        try AgentTaskSubmission(request: request, exactInputReferences: [
            AgentTaskInputReference(kind: .text, utf8Start: start,
                                    utf8Length: value.utf8.count, value: value)
        ]).validateExactInputReferences()

        XCTAssertThrowsError(try AgentTaskSubmission(request: request, exactInputReferences: [
            AgentTaskInputReference(kind: .text, utf8Start: start,
                                    utf8Length: value.utf8.count, value: "other")
        ]).validateExactInputReferences())
    }

    func testTextReferenceRangesPersistThroughQueueAndHistoryRecords() throws {
        let value = "Budget for café 🙂"
        let draft = TaskComposerDraft(segments: [
            .text("Use "), .reference(TaskComposerReference(kind: .text, value: value)),
            .text(" in the report")
        ])
        let submission = draft.submission()
        try submission.validateExactInputReferences()
        XCTAssertEqual(submission.exactInputReferences.first?.version,
                       AgentTaskInputReferenceProtocol.version)

        let queued = QueuedAgentTask(request: submission.request,
                                     exactInputReferences: submission.exactInputReferences)
        let decodedQueue = try JSONDecoder().decode(QueuedAgentTask.self, from: JSONEncoder().encode(queued))
        XCTAssertEqual(decodedQueue, queued)

        let history = AgentTaskHistoryEntry(request: submission.request,
            exactInputReferences: submission.exactInputReferences,
            responseTitle: "Completed", response: "Done", outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 10), wasQueued: true)
        let decodedHistory = try JSONDecoder().decode(AgentTaskHistoryEntry.self,
            from: JSONEncoder().encode(history))
        XCTAssertEqual(decodedHistory, history)
    }
}
