import XCTest
@testable import OrbitAgent

final class AgentTaskSubmissionTests: XCTestCase {
    func testComposerExpandsRepeatedUnicodeReferencesToExactUTF8Ranges() throws {
        let file = TaskComposerReference(kind: .file, value: "/tmp/预算.xlsx")
        let url = TaskComposerReference(kind: .url, value: "https://example.test/a%20b?q=%24HOME")
        let draft = TaskComposerDraft(segments: [
            .text("Summarize "), .reference(file), .text(" beside "), .reference(file),
            .text(" and cite "), .reference(url)
        ])
        let submission = draft.submission()
        XCTAssertEqual(submission.request, "Summarize /tmp/预算.xlsx beside /tmp/预算.xlsx and cite https://example.test/a%20b?q=%24HOME")
        XCTAssertEqual(submission.exactInputReferences.map(\.value), [file.value, file.value, url.value])
        let bytes = Array(submission.request.utf8)
        for reference in submission.exactInputReferences {
            let range = reference.utf8Start..<(reference.utf8Start + reference.utf8Length)
            XCTAssertEqual(String(bytes: bytes[range], encoding: .utf8), reference.value)
        }
        let rebuilt = TaskComposerDraft(submission: submission)
        XCTAssertEqual(rebuilt.expandedText, draft.expandedText)
        XCTAssertEqual(rebuilt.submission().exactInputReferences, submission.exactInputReferences)
    }

    func testSubmissionTrimsOnlyProseOutsideProtectedReferences() throws {
        let exact = "/tmp/report with trailing space "
        let draft = TaskComposerDraft(segments: [
            .text(" \n  Save "), .reference(TaskComposerReference(kind: .file, value: exact)),
            .text(" \n ")
        ])
        let submitted = draft.submission().trimmedForSubmission()
        XCTAssertEqual(submitted.request, "Save " + exact)
        XCTAssertEqual(submitted.exactInputReferences.count, 1)
        let reference = try XCTUnwrap(submitted.exactInputReferences.first)
        XCTAssertEqual(reference.utf8Start, "Save ".utf8.count)
        XCTAssertEqual(reference.utf8Length, exact.utf8.count)
        let bytes = Array(submitted.request.utf8)
        XCTAssertEqual(String(bytes: bytes[reference.utf8Start..<(reference.utf8Start + reference.utf8Length)], encoding: .utf8), exact)
    }

    func testQueueAndHistoryRecordsKeepReferencesAndLegacyRecordsDecode() throws {
        let reference = AgentTaskInputReference(kind: .folder, utf8Start: 4,
            utf8Length: "/tmp/Reports".utf8.count, value: "/tmp/Reports")
        let queued = QueuedAgentTask(request: "Use /tmp/Reports", exactInputReferences: [reference])
        let encoded = try JSONEncoder().encode(queued)
        XCTAssertEqual(try JSONDecoder().decode(QueuedAgentTask.self, from: encoded), queued)

        let legacy = Data("""
        {"id":"76E2D377-5B1D-43A8-96BD-0DC7FDF9DC02","request":"plain request","queuedAt":0}
        """.utf8)
        let decoded = try JSONDecoder().decode(QueuedAgentTask.self, from: legacy)
        XCTAssertEqual(decoded.request, "plain request")
        XCTAssertNil(decoded.exactInputReferences)
    }

    func testReferenceParserAcceptsOnlyStandaloneLocalPathsAndHTTPDestinations() throws {
        let pastedURL = "https://example.test/a%20b?q=x%2Fy#part"
        let web = try XCTUnwrap(TaskComposerReferenceParser.standalonePaste(pastedURL))
        XCTAssertEqual(web.kind, .url)
        XCTAssertEqual(web.value, pastedURL)
        XCTAssertNil(TaskComposerReferenceParser.standalonePaste("Open " + pastedURL))
        XCTAssertNil(TaskComposerReferenceParser.standalonePaste("javascript:alert(1)"))

        let path = "/tmp/Reports with spaces"
        let directory = try XCTUnwrap(TaskComposerReferenceParser.standalonePaste(path, directoryLookup: { _ in true }))
        XCTAssertEqual(directory.kind, .folder)
        XCTAssertEqual(directory.value, path)
        let fileURL = try XCTUnwrap(URL(string: "file:///tmp/budget%20sheet.xlsx"))
        let file = try XCTUnwrap(TaskComposerReferenceParser.dropped(fileURL, directoryLookup: { _ in false }))
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.value, "/tmp/budget sheet.xlsx")
        XCTAssertNil(TaskComposerReferenceParser.dropped(URL(string: "ftp://example.test/file")!))
    }

    func testPasteParserSupportsFinderURLItemsButKeepsMixedProseAsText() throws {
        let first = URL(fileURLWithPath: "/tmp/Finance/budget.xlsx")
        let second = URL(fileURLWithPath: "/tmp/Planning/budget.xlsx")
        let pasted = try XCTUnwrap(TaskComposerReferenceParser.pasted(
            text: "budget.xlsx\nbudget.xlsx", urls: [first, second], directoryLookup: { _ in false }
        ))
        XCTAssertEqual(pasted.map(\.value), [first.path, second.path])
        XCTAssertEqual(pasted.map(\.kind), [.file, .file])

        XCTAssertEqual(TaskComposerReferenceParser.pasted(text: first.path, urls: [])?.first?.value, first.path)
        XCTAssertEqual(TaskComposerReferenceParser.pasted(text: "https://example.test/a%20b?q=x", urls: [])?.first?.kind, .url)
        XCTAssertNil(TaskComposerReferenceParser.pasted(text: "Compare this with budget.xlsx", urls: [first]))
        XCTAssertNil(TaskComposerReferenceParser.pasted(text: "budget.xlsx", urls: [first, second]))
    }

    func testDuplicateBasenamesUseDistinguishingParentFolders() {
        let first = TaskComposerReference(kind: .file, value: "/tmp/Finance/budget.xlsx")
        let second = TaskComposerReference(kind: .file, value: "/tmp/Planning/budget.xlsx")
        let draft = TaskComposerDraft(segments: [.reference(first), .text(" and "), .reference(second)])
        XCTAssertEqual(draft.displayLabel(for: first), "Finance/budget.xlsx")
        XCTAssertEqual(draft.displayLabel(for: second), "Planning/budget.xlsx")
    }
}
