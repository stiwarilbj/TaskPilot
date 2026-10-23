import XCTest

@testable import OrbitAgent

final class QueuedTaskEditSessionTests: XCTestCase {
    private enum PersistenceFailure: Error {
        case unavailable
    }

    func testEditCompilesExactChipRangesAndPreservesQueueIdentityAndPosition() {
        let first = QueuedAgentTask(request: "Earlier", queuedAt: Date(timeIntervalSince1970: 10))
        let queuedAt = Date(timeIntervalSince1970: 20)
        let file = "/tmp/Reports/café.xlsx"
        let url = "https://example.test/reports?q=weekly%20summary"
        let originalSubmission = AgentTaskSubmission(
            request: "Summarize \(file) at \(url)",
            exactInputReferences: [
                reference(.file, in: "Summarize \(file) at \(url)", value: file),
                reference(.url, in: "Summarize \(file) at \(url)", value: url)
            ]
        )
        let original = QueuedAgentTask(
            request: originalSubmission.request,
            exactInputReferences: originalSubmission.exactInputReferences,
            queuedAt: queuedAt
        )
        let last = QueuedAgentTask(request: "Later", queuedAt: Date(timeIntervalSince1970: 30))
        var session = QueuedTaskEditSession(task: original, surface: .queueHistory)
        let newFile = "/tmp/Output/annual résumé.pdf"
        session.draft = TaskComposerDraft(segments: [
            .text("Prepare a summary of "),
            .reference(TaskComposerReference(kind: .file, value: newFile)),
            .text(" and preserve the source " + file)
        ])

        let replacement = session.replacementQueue(from: [first, original, last])

        XCTAssertEqual(replacement?.map(\.id), [first.id, original.id, last.id])
        XCTAssertEqual(replacement?[1].queuedAt, queuedAt)
        XCTAssertEqual(replacement?[1].request, "Prepare a summary of \(newFile) and preserve the source \(file)")
        XCTAssertEqual(replacement?[1].exactInputReferences, [
            reference(.file, in: "Prepare a summary of \(newFile) and preserve the source \(file)", value: newFile)
        ])
    }

    func testEditFollowsRequestWhenQueueIsReordered() {
        let first = QueuedAgentTask(request: "First")
        let original = QueuedAgentTask(request: "Second")
        let last = QueuedAgentTask(request: "Third")
        var session = QueuedTaskEditSession(task: original, surface: .mainWindow)
        session.draft = TaskComposerDraft(plainText: "Edited second")
        let reordered = AgentTaskQueueOrdering.moving([first, original, last], id: original.id, offset: -1)

        let replacement = session.replacementQueue(from: reordered)

        XCTAssertEqual(replacement?.map(\.request), ["Edited second", "First", "Third"])
        XCTAssertEqual(replacement?.first?.id, original.id)

        let movedLater = AgentTaskQueueOrdering.moving([first, original, last], id: original.id, offset: 1)
        let laterReplacement = session.replacementQueue(from: movedLater)
        XCTAssertEqual(laterReplacement?.map(\.request), ["First", "Third", "Edited second"])
        XCTAssertEqual(laterReplacement?.last?.id, original.id)
    }

    func testEditedRequestCanReachFrontWithoutSkippingOrStartingIt() {
        let earlier = QueuedAgentTask(request: "Earlier")
        let edited = QueuedAgentTask(request: "Being edited")
        let later = QueuedAgentTask(request: "Later")
        let session = QueuedTaskEditSession(task: edited, surface: .mainWindow)

        XCTAssertFalse(session.blocksAutomaticHandoff(in: [earlier, edited, later]))
        XCTAssertTrue(session.blocksAutomaticHandoff(in: [edited, earlier, later]))
        XCTAssertFalse(session.blocksAutomaticHandoff(in: [earlier, later]))
    }

    func testEmptyDraftCannotBeSavedAndCancelKeepsOriginalImmutable() {
        let original = QueuedAgentTask(request: "Original request")
        var session = QueuedTaskEditSession(task: original, surface: .queueHistory)
        session.draft = TaskComposerDraft(plainText: " \n\t ")
        XCTAssertNil(session.replacementQueue(from: [original]))

        session.draft = TaskComposerDraft(plainText: "Unsaved draft")
        XCTAssertEqual(session.originalTask, original)
        XCTAssertEqual(original.request, "Original request")
    }

    func testMissingStartedOrChangedRequestCannotBeRecreatedByAnEdit() {
        let original = QueuedAgentTask(request: "Waiting request")
        let session = QueuedTaskEditSession(task: original, surface: .mainWindow)

        XCTAssertTrue(session.isEligible(in: [original]))
        XCTAssertFalse(session.isEligible(in: []))
        XCTAssertFalse(session.isEligible(in: [QueuedAgentTask(id: original.id, request: "Changed elsewhere")]))
        XCTAssertNil(session.replacementQueue(from: []))
        XCTAssertNil(session.replacementQueue(from: [QueuedAgentTask(id: original.id, request: "Changed elsewhere")]))
    }

    func testPersistenceFailureDoesNotPublishTheReplacementOrDiscardDraft() {
        let original = QueuedAgentTask(request: "Saved request")
        let savedQueue = [original]
        var session = QueuedTaskEditSession(task: original, surface: .queueHistory)
        session.draft = TaskComposerDraft(plainText: "Unsaved correction")
        var publishedQueue = savedQueue

        do {
            if let committed = try session.commitReplacement(from: savedQueue, persist: { _ in
                throw PersistenceFailure.unavailable
            }) {
                publishedQueue = committed
            }
            XCTFail("A failed persistence operation must not return a publishable queue.")
        } catch PersistenceFailure.unavailable {
            // The coordinator retains its prior published queue and session.
        } catch {
            XCTFail("Unexpected persistence error: \(error)")
        }

        XCTAssertEqual(publishedQueue, savedQueue)
        XCTAssertEqual(session.draft.expandedText, "Unsaved correction")
        XCTAssertEqual(session.originalTask, original)
    }

    func testSavedEditSurvivesLedgerRoundTripWithReferencesAndTimestamp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskPilotQueueEdit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentTaskLedgerStore(fileURL: root.appendingPathComponent(AgentTaskLedgerStore.fileName))
        let queuedAt = Date(timeIntervalSince1970: 1234.5)
        let original = QueuedAgentTask(request: "Open /tmp/old.txt", queuedAt: queuedAt)
        var session = QueuedTaskEditSession(task: original, surface: .queueHistory)
        let path = "/tmp/Final/summary.txt"
        session.draft = TaskComposerDraft(segments: [
            .text("Open "),
            .reference(TaskComposerReference(kind: .file, value: path))
        ])
        try store.save(queue: [original], history: [])
        var publishedQueue = [original]
        let updatedQueue = try XCTUnwrap(session.commitReplacement(from: publishedQueue) { replacement in
            XCTAssertEqual(publishedQueue, [original], "The replacement must persist before becoming visible.")
            try store.save(queue: replacement, history: [])
        })
        publishedQueue = updatedQueue
        let restored = try store.load().queue

        XCTAssertEqual(publishedQueue, updatedQueue)
        XCTAssertEqual(restored, updatedQueue)
        XCTAssertEqual(restored.first?.id, original.id)
        XCTAssertEqual(restored.first?.queuedAt, queuedAt)
        XCTAssertEqual(restored.first?.exactInputReferences?.first?.value, path)
    }

    private func reference(
        _ kind: AgentTaskInputKind,
        in request: String,
        value: String
    ) -> AgentTaskInputReference {
        let start = try! XCTUnwrap(request.range(of: value))
        let utf8Start = request[..<start.lowerBound].utf8.count
        return AgentTaskInputReference(
            kind: kind,
            utf8Start: utf8Start,
            utf8Length: value.utf8.count,
            value: value
        )
    }
}
