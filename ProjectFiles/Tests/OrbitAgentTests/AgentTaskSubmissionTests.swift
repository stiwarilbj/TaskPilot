import XCTest
import AppKit
import SwiftUI
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

    func testUserRolesRemainPerOccurrenceThroughDraftQueueAndRoleCorrections() throws {
        let path = "/tmp/report.txt"
        let request = "Summarize \(path) then save the result to \(path)."
        let first = request.range(of: path)!
        let second = request.range(of: path, range: first.upperBound..<request.endIndex)!
        let firstStart = request[..<first.lowerBound].utf8.count
        let secondStart = request[..<second.lowerBound].utf8.count
        let references = [
            AgentTaskInputReference(kind: .file, utf8Start: firstStart, utf8Length: path.utf8.count,
                                    value: path, userRole: .source),
            AgentTaskInputReference(kind: .file, utf8Start: secondStart, utf8Length: path.utf8.count,
                                    value: path, userRole: .destination)
        ]
        let submission = AgentTaskSubmission(request: request, exactInputReferences: references)
        try submission.validateExactInputReferences()
        let restored = TaskComposerDraft(submission: submission)
        XCTAssertEqual(restored.references.map(\.userRole), [.source, .destination])
        XCTAssertEqual(restored.submission().exactInputReferences.map(\.userRole), [.source, .destination])

        let amendment = AgentTaskInputRoleAmendment(occurrenceID: references[1].id, kind: .file,
            utf8Start: references[1].utf8Start, utf8Length: references[1].utf8Length,
            value: path, role: nil)
        let correction = TaskInstructionCorrection(revision: 1,
            submission: AgentTaskSubmission(request: ""), roleAmendment: amendment)
        let decodedCorrection = try JSONDecoder().decode(TaskInstructionCorrection.self,
            from: JSONEncoder().encode(correction))
        XCTAssertEqual(decodedCorrection, correction)
        let amended = submission.includingCorrections([correction])
        XCTAssertEqual(amended.request, request)
        XCTAssertEqual(amended.exactInputReferences.map(\.userRole), [.source, nil])
        try amended.validateExactInputReferences()
        let roleCorrectionRecord = TaskInstructionCorrection(revision: 1,
            submission: AgentTaskSubmission(request: ""), applied: true, roleAmendment: amendment)
        let history = AgentTaskHistoryEntry(request: request, exactInputReferences: references,
            responseTitle: "Stopped", response: "Partial", outcome: .stopped,
            startedAt: Date(timeIntervalSince1970: 10), wasQueued: false, corrections: [roleCorrectionRecord])
        let decodedHistory = try JSONDecoder().decode(AgentTaskHistoryEntry.self,
            from: JSONEncoder().encode(history))
        XCTAssertEqual(decodedHistory.effectiveSubmission.request, request)
        XCTAssertEqual(decodedHistory.effectiveSubmission.exactInputReferences.map(\.userRole), [.source, nil])

        let queued = QueuedAgentTask(request: submission.request, exactInputReferences: submission.exactInputReferences)
        let decoded = try JSONDecoder().decode(QueuedAgentTask.self, from: JSONEncoder().encode(queued))
        XCTAssertEqual(decoded.exactInputReferences?.map(\.userRole), [.source, .destination])

        let queuedHistory = AgentTaskHistoryEntry(request: submission.request,
            exactInputReferences: submission.exactInputReferences, responseTitle: "Completed", response: "Done",
            outcome: .completed, startedAt: Date(timeIntervalSince1970: 10), wasQueued: true)
        let decodedQueuedHistory = try JSONDecoder().decode(AgentTaskHistoryEntry.self, from: JSONEncoder().encode(queuedHistory))
        XCTAssertEqual(decodedQueuedHistory.exactInputReferences?.map(\.userRole), [.source, .destination])
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

    func testInferredRoleDoesNotBecomeAnExplicitPickerOverride() {
        let inferred = TaskComposerReference(kind: .file, value: "/tmp/budget.xlsx",
            presentedRole: .source, roleOrigin: .inferred)
        XCTAssertEqual(inferred.presentedRole, .source)
        XCTAssertNil(inferred.userRole)
        XCTAssertNil(inferred.rolePickerSelection)

        let pending = TaskComposerReference(kind: .file, value: "/tmp/budget.xlsx",
            userRole: .source, presentedRole: .source, pendingRole: .destination,
            roleCorrectionPending: true)
        XCTAssertEqual(pending.rolePickerSelection, .destination)
        let acknowledged = TaskComposerReference(kind: .file, value: "/tmp/budget.xlsx",
            userRole: .destination, presentedRole: .destination, roleOrigin: .chosen)
        XCTAssertEqual(acknowledged.rolePickerSelection, .destination)
    }

    @MainActor
    func testComposerExtractionPreservesUnicodeAndExactReferenceRanges() throws {
        let before = "Summarize 🧾 cafe\u{301} 👩🏽‍💻  "
        let value = "/tmp/预算.xlsx"
        let after = "\nthen preserve 👨‍👩‍👧‍👦 and naïve text."
        let reference = TaskComposerReference(kind: .file, value: value)
        let attributed = NSMutableAttributedString(string: before)
        attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
            range: NSRange(location: 0, length: "Summarize".utf16.count))
        attributed.append(NSAttributedString(attachment: TaskComposerTextAttachment(reference: reference, label: "预算.xlsx")))
        attributed.append(NSAttributedString(string: after))

        let draft = TaskRequestComposer.Coordinator.draft(from: attributed)
        XCTAssertEqual(draft.segments, [.text(before), .reference(reference), .text(after)])
        let submission = draft.submission()
        XCTAssertEqual(submission.request, before + value + after)
        let input = try XCTUnwrap(submission.exactInputReferences.first)
        XCTAssertEqual(input.utf8Start, before.utf8.count)
        XCTAssertEqual(input.utf8Length, value.utf8.count)
        let bytes = Array(submission.request.utf8)
        XCTAssertEqual(String(bytes: bytes[input.utf8Start..<(input.utf8Start + input.utf8Length)], encoding: .utf8), value)
    }

    @MainActor
    func testFreshChipRoleChangeKeepsAttachmentIdentityAndSelection() throws {
        let draft = TaskComposerDraft(plainText: "Edit  carefully")
        let composer = TaskRequestComposer(draft: .constant(draft), fontSize: 14, focusRequested: false,
            onFocusChanged: { _ in }, accessibilityLabel: "Test request")
        let coordinator = TaskRequestComposer.Coordinator(parent: composer)
        let textView = TaskComposerTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        textView.isRichText = true
        textView.allowsUndo = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = textView
        _ = window.makeFirstResponder(textView)
        coordinator.render(draft, in: textView)
        textView.isEditable = true
        coordinator.insertDropped([URL(fileURLWithPath: "/tmp/new-chip.xlsx")],
            at: "Edit ".utf16.count, in: textView)
        let droppedDraft = TaskRequestComposer.Coordinator.draft(from: textView.attributedString())
        let reference = try XCTUnwrap(droppedDraft.references.first)
        XCTAssertNil(reference.occurrenceID)
        XCTAssertEqual(droppedDraft.segments, [.text("Edit "), .reference(reference), .text(" carefully")])
        let attachmentOffset = "Edit ".utf16.count
        let before = try XCTUnwrap(textView.attributedString().attribute(.attachment, at: attachmentOffset,
            effectiveRange: nil) as? TaskComposerTextAttachment)
        let selection = NSRange(location: 1, length: 2)
        textView.setSelectedRange(selection)

        XCTAssertTrue(coordinator.applyRoleCorrection(.source, to: reference, in: textView))

        let after = try XCTUnwrap(textView.attributedString().attribute(.attachment, at: attachmentOffset,
            effectiveRange: nil) as? TaskComposerTextAttachment)
        XCTAssertTrue(before === after)
        XCTAssertEqual(after.reference.userRole, .source)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertTrue(coordinator.lastRenderedDraft?.hasSameContent(as: droppedDraft) == true)
        XCTAssertEqual(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).submission()
            .exactInputReferences.first?.userRole, .source)

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertNil(after.reference.userRole)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(after.reference.userRole, .source)
        XCTAssertEqual(textView.selectedRange(), selection)

        let roleOnly = TaskComposerDraft(segments: [.text("Edit "),
            .reference(TaskComposerReference(id: reference.id, kind: reference.kind, value: reference.value,
                userRole: .destination, presentedRole: .source, roleOrigin: .chosen)), .text(" carefully")])
        XCTAssertTrue(droppedDraft.hasSameContent(as: roleOnly))
        coordinator.update(roleOnly, in: textView)
        let roleOnlyAttachment = try XCTUnwrap(textView.attributedString().attribute(.attachment, at: attachmentOffset,
            effectiveRange: nil) as? TaskComposerTextAttachment)
        XCTAssertTrue(after === roleOnlyAttachment)
        XCTAssertEqual(textView.selectedRange(), selection)

        coordinator.replace(reference.id, with: TaskComposerReference(id: reference.id,
            kind: .file, value: "/tmp/replacement.xlsx", userRole: .destination,
            presentedRole: .source, roleOrigin: .chosen), in: textView)
        let replaced = try XCTUnwrap(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).references.first)
        XCTAssertEqual(replaced.id, reference.id)
        XCTAssertEqual(replaced.userRole, .destination)
        XCTAssertEqual(replaced.value, "/tmp/replacement.xlsx")
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testReadOnlyComposerRejectsEditIMEAndDropRoutes() throws {
        let draft = TaskComposerDraft(plainText: "Read 🧾 only")
        let composer = TaskRequestComposer(draft: .constant(draft), fontSize: 14, focusRequested: false,
            onFocusChanged: { _ in }, accessibilityLabel: "Current task", isReadOnly: true)
        let coordinator = TaskRequestComposer.Coordinator(parent: composer)
        let textView = TaskComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        textView.isRichText = true
        textView.isEditable = false
        coordinator.render(draft, in: textView)
        let original = textView.attributedString().string
        let selection = NSRange(location: 0, length: 4)
        textView.setSelectedRange(selection)

        textView.insertText("Changed", replacementRange: selection)
        textView.setMarkedText("候補", selectedRange: NSRange(location: 0, length: 0), replacementRange: selection)
        textView.deleteBackward(nil)
        textView.deleteForward(nil)
        textView.pasteAsPlainText(nil)
        textView.pasteAsRichText(nil)
        textView.pasteAndMatchStyle(nil)
        textView.undo(nil)
        textView.redo(nil)
        coordinator.insertDropped([URL(fileURLWithPath: "/tmp/new-file")], at: 0, in: textView)

        XCTAssertEqual(textView.attributedString().string, original)
    }

    @MainActor
    func testUnchangedRoleOverrideDoesNotRequestARevision() {
        XCTAssertFalse(TaskPilotCoordinator.inputRoleOverrideChanges(from: .source, to: .source))
        XCTAssertFalse(TaskPilotCoordinator.inputRoleOverrideChanges(from: nil, to: nil))
        XCTAssertTrue(TaskPilotCoordinator.inputRoleOverrideChanges(from: nil, to: .source))
        XCTAssertTrue(TaskPilotCoordinator.inputRoleOverrideChanges(from: .source, to: nil))
    }

    @MainActor
    func testLongComposerExtractionPreservesWholeTextRun() throws {
        let prefix = String(repeating: "Project summary 🧾 cafe\u{301}. ", count: 1_576)
        let reference = TaskComposerReference(kind: .text, value: "exact phrase")
        let attributed = NSMutableAttributedString(string: prefix)
        attributed.append(NSAttributedString(attachment: TaskComposerTextAttachment(reference: reference, label: "exact phrase")))
        attributed.append(NSAttributedString(string: " done"))

        let start = DispatchTime.now().uptimeNanoseconds
        var extracted = TaskComposerDraft()
        for _ in 0..<50 { extracted = TaskRequestComposer.Coordinator.draft(from: attributed) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        XCTAssertEqual(extracted.expandedText, prefix + reference.value + " done")
        XCTAssertEqual(extracted.references.count, 1)
        print("Composer extraction benchmark: 41K-character fixture, 50 passes, \(Double(elapsed) / 1_000_000) ms")
    }
}
