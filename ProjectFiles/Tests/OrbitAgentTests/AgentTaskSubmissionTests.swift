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

        let repeatedFirst = TaskComposerReference(kind: .file, value: first.value)
        let repeatedSecond = TaskComposerReference(kind: .file, value: first.value)
        let repeated = TaskComposerDraft(segments: [.reference(repeatedFirst), .reference(repeatedSecond)])
        XCTAssertEqual(repeated.displayLabels()[repeatedFirst.id], "budget.xlsx")
        XCTAssertEqual(repeated.displayLabels()[repeatedSecond.id], "budget.xlsx")

        let deepFirst = TaskComposerReference(kind: .file, value: "/Users/one/Finance/2026/budget.xlsx")
        let deepSecond = TaskComposerReference(kind: .file, value: "/Users/two/Finance/2026/budget.xlsx")
        let deep = TaskComposerDraft(segments: [.reference(deepFirst), .reference(deepSecond)])
        XCTAssertNotEqual(deep.displayLabel(for: deepFirst), deep.displayLabel(for: deepSecond))
    }

    func testInvalidRestoredRangesRemainRejectedWithoutOverflow() throws {
        let malformed = [
            AgentTaskInputReference(kind: .file, utf8Start: Int.max, utf8Length: 1, value: "/tmp/a"),
            AgentTaskInputReference(kind: .file, utf8Start: -1, utf8Length: 1, value: "/tmp/a"),
            AgentTaskInputReference(kind: .file, utf8Start: 0, utf8Length: Int.max, value: "/tmp/a")
        ]

        for reference in malformed {
            let original = AgentTaskSubmission(request: "keep this request", exactInputReferences: [reference])
            let restored = TaskComposerDraft(submission: original)
            XCTAssertEqual(restored.expandedText, original.request)
            XCTAssertEqual(restored.submission(), original)
            XCTAssertEqual(original.trimmedForSubmission(), original)
            XCTAssertThrowsError(try restored.submission().validateExactInputReferences())

            var edited = restored
            edited.segments = [.text("reviewed request")]
            XCTAssertEqual(edited.submission().request, "reviewed request")
            XCTAssertTrue(edited.submission().exactInputReferences.isEmpty)
        }
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
    func testAutomaticRoleRestoresOnlyARealInferenceAndUsesCurrentAttachment() throws {
        let inferred = TaskComposerReference(kind: .file, value: "/tmp/inferred.xlsx",
            presentedRole: .source, roleOrigin: .inferred)
        let chosenOnly = TaskComposerReference(kind: .file, value: "/tmp/chosen.xlsx")
        let draft = TaskComposerDraft(segments: [.reference(inferred), .text(" "), .reference(chosenOnly)])
        let composer = TaskRequestComposer(draft: .constant(draft), fontSize: 14, focusRequested: false,
            onFocusChanged: { _ in }, accessibilityLabel: "Test request")
        let coordinator = TaskRequestComposer.Coordinator(parent: composer)
        let textView = TaskComposerTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = textView
        coordinator.render(draft, in: textView)

        XCTAssertTrue(coordinator.applyRoleCorrection(.destination, to: inferred, in: textView))
        let inferredAfterChoice = try XCTUnwrap(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).references.first)
        XCTAssertEqual(inferredAfterChoice.userRole, .destination)
        XCTAssertEqual(inferredAfterChoice.inferredRole, .source)
        XCTAssertTrue(coordinator.applyRoleCorrection(nil, to: inferredAfterChoice, in: textView))
        let resetInference = try XCTUnwrap(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).references.first)
        XCTAssertNil(resetInference.userRole)
        XCTAssertEqual(resetInference.presentedRole, .source)
        XCTAssertEqual(resetInference.roleOrigin, .inferred)

        XCTAssertTrue(coordinator.applyRoleCorrection(.source, to: chosenOnly, in: textView))
        let currentChosen = try XCTUnwrap(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).references.last)
        XCTAssertTrue(coordinator.applyRoleCorrection(nil, to: currentChosen, in: textView))
        let resetChosen = try XCTUnwrap(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).references.last)
        XCTAssertNil(resetChosen.userRole)
        XCTAssertNil(resetChosen.presentedRole)
        XCTAssertEqual(resetChosen.roleOrigin, .unresolved)

        // A stale reference snapshot must not hide a real update to the live attachment.
        XCTAssertTrue(coordinator.applyRoleCorrection(.destination, to: chosenOnly, in: textView))
        let updated = try XCTUnwrap(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).references.last)
        XCTAssertEqual(updated.userRole, .destination)
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testStandaloneReferencePasteReplacesSelectedTextAndChips() throws {
        let original = TaskComposerReference(kind: .file, value: "/tmp/old.xlsx")
        let draft = TaskComposerDraft(segments: [.text("before "), .reference(original), .text(" after")])
        let composer = TaskRequestComposer(draft: .constant(draft), fontSize: 14, focusRequested: false,
            onFocusChanged: { _ in }, accessibilityLabel: "Test request")
        let coordinator = TaskRequestComposer.Coordinator(parent: composer)
        let textView = TaskComposerTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        textView.isRichText = true
        textView.isEditable = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = textView
        coordinator.render(draft, in: textView)

        let selection = NSRange(location: "before ".utf16.count,
            length: 1 + " after".utf16.count)
        textView.setSelectedRange(selection)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("https://example.test/new%20report?q=1", forType: .string)
        coordinator.paste(into: textView, from: pasteboard)

        let result = TaskRequestComposer.Coordinator.draft(from: textView.attributedString())
        XCTAssertEqual(result.expandedText, "before https://example.test/new%20report?q=1")
        XCTAssertEqual(result.references.map(\.value), ["https://example.test/new%20report?q=1"])
        XCTAssertEqual(result.submission().exactInputReferences.first?.utf8Start, "before ".utf8.count)

        let pastedURL = result.references[0].value
        textView.setSelectedRange(NSRange(location: "before ".utf16.count, length: pastedURL.utf16.count))
        pasteboard.setString("/tmp/new report.pdf", forType: .string)
        coordinator.paste(into: textView, from: pasteboard)
        let pathResult = TaskRequestComposer.Coordinator.draft(from: textView.attributedString())
        XCTAssertEqual(pathResult.expandedText, "before /tmp/new report.pdf")
        XCTAssertEqual(pathResult.references.map(\.kind), [.file])
        XCTAssertEqual(pathResult.references.map(\.value), ["/tmp/new report.pdf"])
        pasteboard.releaseGlobally()
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testChipClipboardRoundTripIsolatedPasteboardAndUndoRedo() throws {
        let source = TaskComposerReference(kind: .file, value: "/tmp/Finance/budget.xlsx", userRole: .source)
        let comparison = TaskComposerReference(kind: .file, value: "/tmp/Planning/budget.xlsx", userRole: .referenceExample)
        let draft = TaskComposerDraft(segments: [.text("Summarize "), .reference(source), .text(" then compare "),
            .reference(comparison), .text(" carefully")])
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

        let initialLength = textView.attributedString().length
        let pasteboard = NSPasteboard.withUniqueName()
        textView.setSelectedRange(NSRange(location: 0, length: initialLength))
        coordinator.copySelection(from: textView, cut: false, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string),
            "Summarize /tmp/Finance/budget.xlsx then compare /tmp/Planning/budget.xlsx carefully")

        textView.setSelectedRange(NSRange(location: initialLength, length: 0))
        coordinator.paste(into: textView, from: pasteboard)
        var result = TaskRequestComposer.Coordinator.draft(from: textView.attributedString())
        XCTAssertEqual(result.references.count, 4)
        XCTAssertEqual(result.references.map(\.userRole), [.source, .referenceExample, .source, .referenceExample])
        XCTAssertEqual(result.expandedText,
            "Summarize /tmp/Finance/budget.xlsx then compare /tmp/Planning/budget.xlsx carefully" +
            "Summarize /tmp/Finance/budget.xlsx then compare /tmp/Planning/budget.xlsx carefully")
        let labels = result.displayLabels()
        XCTAssertEqual(labels[result.references[0].id], "Finance/budget.xlsx")
        XCTAssertEqual(labels[result.references[1].id], "Planning/budget.xlsx")
        XCTAssertEqual(labels[result.references[2].id], "Finance/budget.xlsx")
        XCTAssertEqual(labels[result.references[3].id], "Planning/budget.xlsx")
        textView.undoManager?.undo()
        result = TaskRequestComposer.Coordinator.draft(from: textView.attributedString())
        XCTAssertEqual(result.references.count, 2)
        textView.undoManager?.redo()
        result = TaskRequestComposer.Coordinator.draft(from: textView.attributedString())
        XCTAssertEqual(result.references.count, 4)

        let copiedSecond = try XCTUnwrap(result.references.last)
        var secondRange: NSRange?
        textView.attributedString().enumerateAttribute(.attachment,
            in: NSRange(location: 0, length: textView.attributedString().length)) { value, range, _ in
                guard let attachment = value as? TaskComposerTextAttachment,
                      attachment.reference.id == copiedSecond.id else { return }
                secondRange = range
            }
        textView.setSelectedRange(try XCTUnwrap(secondRange))
        coordinator.copySelection(from: textView, cut: true, to: pasteboard)
        XCTAssertEqual(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).references.count, 3)
        textView.undoManager?.undo()
        XCTAssertEqual(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).references.count, 4)

        pasteboard.releaseGlobally()
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testEditableSpaceTypesBesideChipAndHitTestingRejectsNearbyWhitespace() throws {
        let reference = TaskComposerReference(kind: .text, value: "budget.xlsx")
        let draft = TaskComposerDraft(segments: [.reference(reference), .text("report")])
        let composer = TaskRequestComposer(draft: .constant(draft), fontSize: 14, focusRequested: false,
            onFocusChanged: { _ in }, accessibilityLabel: "Test request")
        let coordinator = TaskRequestComposer.Coordinator(parent: composer)
        let textView = TaskComposerTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        textView.isRichText = true
        textView.isEditable = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = textView
        coordinator.render(draft, in: textView)
        _ = window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))

        textView.keyDown(with: space)
        XCTAssertEqual(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).expandedText,
            "budget.xlsx report")

        coordinator.render(draft, in: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        textView.keyDown(with: space)
        XCTAssertEqual(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).expandedText,
            " report")

        let optionReturn = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.option], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        coordinator.render(draft, in: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        XCTAssertEqual(textView.chipInspectionTarget(for: optionReturn)?.0.id, reference.id)
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        textView.setMarkedText("候補", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: 0, length: 1))
        XCTAssertNil(textView.chipInspectionTarget(for: optionReturn))
        textView.unmarkText()
        coordinator.render(draft, in: textView)

        let returnKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        textView.keyDown(with: returnKey)
        XCTAssertEqual(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()).expandedText,
            "\nreport")
        coordinator.render(draft, in: textView)

        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let glyphRange = try XCTUnwrap(textView.layoutManager).glyphRange(forCharacterRange: NSRange(location: 0, length: 1),
            actualCharacterRange: nil)
        let glyphRect = try XCTUnwrap(textView.layoutManager).boundingRect(forGlyphRange: glyphRange,
            in: try XCTUnwrap(textView.textContainer)).offsetBy(dx: textView.textContainerOrigin.x,
                dy: textView.textContainerOrigin.y)
        let inside = textView.convert(NSPoint(x: glyphRect.midX, y: glyphRect.midY), to: nil)
        let outside = textView.convert(NSPoint(x: glyphRect.maxX + 8, y: glyphRect.midY), to: nil)
        XCTAssertNotNil(textView.attachment(at: inside))
        XCTAssertNil(textView.attachment(at: outside))
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testLabelIndexAndChipMeasurementsAreReused() throws {
        let references = (0..<128).map { index in
            TaskComposerReference(kind: .file,
                value: "/tmp/Reports/Project\(index)/Archive/2026/report.md")
        }
        let draft = TaskComposerDraft(segments: references.map { .reference($0) })
        let composer = TaskRequestComposer(draft: .constant(draft), fontSize: 14, focusRequested: false,
            onFocusChanged: { _ in }, accessibilityLabel: "Test request")
        let coordinator = TaskRequestComposer.Coordinator(parent: composer)
        let textView = TaskComposerTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        coordinator.render(draft, in: textView)
        XCTAssertEqual(coordinator.labelIndexBuildCount, 1)
        coordinator.refreshLabels(in: textView, draft: draft)
        XCTAssertEqual(coordinator.labelIndexBuildCount, 1)

        let roleOnly = TaskComposerDraft(segments: references.enumerated().map { index, reference in
            .reference(TaskComposerReference(id: reference.id, kind: reference.kind, value: reference.value,
                userRole: index == 0 ? .source : nil, presentedRole: index == 0 ? .source : nil,
                roleOrigin: index == 0 ? .chosen : .unresolved))
        })
        _ = coordinator.labelIndex(for: roleOnly)
        XCTAssertEqual(coordinator.labelIndexBuildCount, 1)
        let proseOnly = TaskComposerDraft(segments: [.text("edited prose")] + references.map { .reference($0) })
        _ = coordinator.labelIndex(for: proseOnly)
        XCTAssertEqual(coordinator.labelIndexBuildCount, 1)
        let changedReference = TaskComposerReference(id: references[0].id, kind: .file,
            value: "/tmp/Reports/Changed/Archive/2026/report.md")
        let changedDraft = TaskComposerDraft(segments: [.reference(changedReference)] + references.dropFirst().map { .reference($0) })
        _ = coordinator.labelIndex(for: changedDraft)
        XCTAssertEqual(coordinator.labelIndexBuildCount, 2)

        let attachment = TaskComposerTextAttachment(reference: references[0], label: "report.md")
        let cell = try XCTUnwrap(attachment.attachmentCell as? TaskComposerChipCell)
        _ = cell.cellSize()
        _ = cell.cellSize()
        XCTAssertEqual(cell.sizeMeasurementCount, 1)
        cell.update(reference: references[0], label: "A longer report.md")
        _ = cell.cellSize()
        XCTAssertEqual(cell.sizeMeasurementCount, 2)
        cell.update(reference: references[0], label: "A longer report.md", fontSize: 14)
        _ = cell.cellSize()
        XCTAssertEqual(cell.sizeMeasurementCount, 3)
        cell.update(reference: references[0], label: "A longer report.md", fontSize: 14)
        _ = cell.cellSize()
        XCTAssertEqual(cell.sizeMeasurementCount, 3)

        let renderedAttachment = try XCTUnwrap(textView.attributedString().attribute(.attachment, at: 0,
            effectiveRange: nil) as? TaskComposerTextAttachment)
        let renderedCell = try XCTUnwrap(renderedAttachment.attachmentCell as? TaskComposerChipCell)
        _ = renderedCell.cellSize()
        let priorMeasurements = renderedCell.sizeMeasurementCount
        coordinator.applyFont(16, to: textView)
        _ = renderedCell.cellSize()
        XCTAssertEqual(renderedCell.sizeMeasurementCount, priorMeasurements + 1)
        let changedFontMeasurements = renderedCell.sizeMeasurementCount
        coordinator.applyFont(16, to: textView)
        _ = renderedCell.cellSize()
        XCTAssertEqual(renderedCell.sizeMeasurementCount, changedFontMeasurements)

        _ = coordinator.labelIndex(for: draft)
        let stableBuildCount = coordinator.labelIndexBuildCount
        let benchmarkStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 { _ = coordinator.labelIndex(for: draft) }
        let benchmarkElapsed = DispatchTime.now().uptimeNanoseconds - benchmarkStart
        XCTAssertEqual(coordinator.labelIndexBuildCount, stableBuildCount)
        print("Composer label benchmark: 128-chip fixture, 5 cached passes, \(Double(benchmarkElapsed) / 1_000_000) ms, index builds \(stableBuildCount)")
    }

    @MainActor
    func testReadOnlyComposerRetainsChipInspectionAndRejectsStaleRoleCallbacks() throws {
        let reference = TaskComposerReference(kind: .file, value: "/tmp/report.xlsx", occurrenceID: "0:17:file")
        let draft = TaskComposerDraft(segments: [.text("Open "), .reference(reference)])
        var roleCorrectionCount = 0
        let composer = TaskRequestComposer(draft: .constant(draft), fontSize: 14, focusRequested: false,
            onFocusChanged: { _ in }, accessibilityLabel: "Current task", isReadOnly: true,
            onRoleCorrection: { _, _ in roleCorrectionCount += 1; return true })
        let coordinator = TaskRequestComposer.Coordinator(parent: composer)
        let textView = TaskComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        textView.isRichText = true
        textView.isEditable = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = textView
        coordinator.render(draft, in: textView)
        textView.setSelectedRange(NSRange(location: textView.attributedString().length - 1, length: 0))

        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertEqual(textView.chipInspectionTarget(for: space)?.0.id, reference.id)
        XCTAssertEqual(textView.chipInspectionTarget(for: returnKey)?.0.id, reference.id)
        XCTAssertTrue(coordinator.applyRoleCorrection(.source, to: reference, in: textView))
        XCTAssertEqual(roleCorrectionCount, 1)

        textView.textStorage?.deleteCharacters(in: NSRange(location: textView.attributedString().length - 1, length: 1))
        XCTAssertFalse(coordinator.applyRoleCorrection(.destination, to: reference, in: textView))
        XCTAssertEqual(roleCorrectionCount, 1)
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testComposerRendersWrappedChipsInNarrowDarkAppearanceWithAccessibilityText() throws {
        let source = TaskComposerReference(kind: .file, value: "/tmp/Finance/Quarterly Budget Review.xlsx",
            userRole: .source)
        let destination = TaskComposerReference(kind: .folder, value: "/tmp/Reports/October Results",
            userRole: .destination)
        let draft = TaskComposerDraft(segments: [.text("Summarize "), .reference(source),
            .text(" and save the result in "), .reference(destination)])
        let composer = TaskRequestComposer(draft: .constant(draft), fontSize: 14, focusRequested: false,
            onFocusChanged: { _ in }, accessibilityLabel: "Task request")
        let coordinator = TaskRequestComposer.Coordinator(parent: composer)
        let textView = TaskComposerTextView(frame: NSRect(x: 0, y: 0, width: 175, height: 120))
        textView.isRichText = true
        textView.isEditable = true
        textView.setAccessibilityLabel("Task request")
        textView.setAccessibilityHelp("Type spaces normally. Press Option-Return beside or on an input chip to inspect it.")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 175, height: 120),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        textView.appearance = window.appearance
        window.contentView = textView
        coordinator.render(draft, in: textView)

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in lineCount += 1 }
        XCTAssertGreaterThan(lineCount, 1)
        XCTAssertEqual(window.appearance?.name, NSAppearance.Name.darkAqua)
        XCTAssertEqual(textView.accessibilityLabel(), "Task request")
        XCTAssertEqual(textView.accessibilityHelp(),
            "Type spaces normally. Press Option-Return beside or on an input chip to inspect it.")
        XCTAssertEqual(TaskRequestComposer.Coordinator.draft(from: textView.attributedString()), draft)
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
