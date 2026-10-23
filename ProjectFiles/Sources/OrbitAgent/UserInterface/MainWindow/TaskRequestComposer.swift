import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct TaskComposerReference: Equatable, Identifiable {
    let id: UUID
    let kind: AgentTaskInputKind
    let value: String

    init(id: UUID = UUID(), kind: AgentTaskInputKind, value: String) {
        self.id = id
        self.kind = kind
        self.value = value
    }
}

enum TaskComposerReferenceParser {
    static func pasted(text: String?, urls: [URL], directoryLookup: ((URL) -> Bool?)? = nil) -> [TaskComposerReference]? {
        if let text, let reference = standalonePaste(text, directoryLookup: directoryLookup) {
            return [reference]
        }
        guard !urls.isEmpty else { return nil }
        if let text {
            let labels = text.split(whereSeparator: \.isNewline).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            guard labels.count == urls.count,
                  zip(labels, urls).allSatisfy({ label, url in
                      label == url.absoluteString || label == url.path || label == url.lastPathComponent
                  }) else { return nil }
        }
        let references = urls.compactMap { dropped($0, directoryLookup: directoryLookup) }
        return references.isEmpty ? nil : references
    }

    static func standalonePaste(_ source: String,
                                directoryLookup: ((URL) -> Bool?)? = nil) -> TaskComposerReference? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { return nil }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil {
            return TaskComposerReference(kind: .url, value: value)
        }
        if let fileURL = URL(string: value), fileURL.isFileURL {
            return localReference(fileURL, directoryLookup: directoryLookup)
        }
        guard value.hasPrefix("/") else { return nil }
        return localReference(URL(fileURLWithPath: value), directoryLookup: directoryLookup)
    }

    static func dropped(_ url: URL, directoryLookup: ((URL) -> Bool?)? = nil) -> TaskComposerReference? {
        if url.isFileURL { return localReference(url, directoryLookup: directoryLookup) }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return TaskComposerReference(kind: .url, value: url.absoluteString)
    }

    static func restored(kind: AgentTaskInputKind, value: String) -> TaskComposerReference? {
        switch kind {
        case .file, .folder:
            guard value.hasPrefix("/") else { return nil }
        case .url:
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host != nil else { return nil }
        }
        return TaskComposerReference(kind: kind, value: value)
    }

    private static func localReference(_ url: URL, directoryLookup: ((URL) -> Bool?)?) -> TaskComposerReference? {
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        let directory = directoryLookup?(url) ?? ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath)
        return TaskComposerReference(kind: directory ? .folder : .file, value: path)
    }
}

enum TaskComposerSegment: Equatable {
    case text(String)
    case reference(TaskComposerReference)
}

struct TaskComposerDraft: Equatable {
    var segments: [TaskComposerSegment]

    init(segments: [TaskComposerSegment] = []) {
        self.segments = Self.coalesced(segments)
    }

    init(plainText: String) {
        self.init(segments: plainText.isEmpty ? [] : [.text(plainText)])
    }

    init(submission: AgentTaskSubmission) {
        let bytes = Array(submission.request.utf8)
        let references = submission.exactInputReferences.sorted { $0.utf8Start < $1.utf8Start }
        var result: [TaskComposerSegment] = []
        var cursor = 0
        for reference in references {
            let end = reference.utf8Start + reference.utf8Length
            guard reference.utf8Start >= cursor, reference.utf8Length > 0, end <= bytes.count,
                  let value = String(bytes: bytes[reference.utf8Start..<end], encoding: .utf8),
                  value == reference.value else {
                self.init(plainText: submission.request)
                return
            }
            if cursor < reference.utf8Start {
                result.append(.text(String(decoding: bytes[cursor..<reference.utf8Start], as: UTF8.self)))
            }
            result.append(.reference(TaskComposerReference(kind: reference.kind, value: reference.value)))
            cursor = end
        }
        if cursor < bytes.count { result.append(.text(String(decoding: bytes[cursor...], as: UTF8.self))) }
        self.init(segments: result)
    }

    var expandedText: String {
        segments.map { segment in
            switch segment {
            case .text(let text): text
            case .reference(let reference): reference.value
            }
        }.joined()
    }

    var isEmpty: Bool { expandedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func submission() -> AgentTaskSubmission {
        var text = ""
        var references: [AgentTaskInputReference] = []
        for segment in segments {
            switch segment {
            case .text(let value): text += value
            case .reference(let reference):
                let start = text.utf8.count
                text += reference.value
                references.append(AgentTaskInputReference(kind: reference.kind, utf8Start: start,
                    utf8Length: reference.value.utf8.count, value: reference.value))
            }
        }
        return AgentTaskSubmission(request: text, exactInputReferences: references)
    }

    func displayLabel(for reference: TaskComposerReference) -> String {
        guard reference.kind != .url else {
            guard let components = URLComponents(string: reference.value) else { return "Web address" }
            let host = components.host ?? "Web address"
            let path = components.percentEncodedPath
            return path.isEmpty || path == "/" ? host : host + path
        }
        let components = URL(fileURLWithPath: reference.value).standardizedFileURL.pathComponents.filter { $0 != "/" }
        let name = components.last ?? reference.value
        let peers = segments.compactMap { segment -> TaskComposerReference? in
            guard case .reference(let candidate) = segment, candidate.kind != .url else { return nil }
            return candidate
        }
        guard peers.contains(where: { $0.id != reference.id && URL(fileURLWithPath: $0.value).lastPathComponent == name }) else {
            return name
        }
        for depth in 2...max(2, components.count) {
            let suffix = components.suffix(depth).joined(separator: "/")
            let collisions = peers.filter {
                URL(fileURLWithPath: $0.value).standardizedFileURL.pathComponents.filter { $0 != "/" }
                    .suffix(depth).joined(separator: "/") == suffix
            }
            if collisions.count == 1 { return suffix }
        }
        return components.suffix(3).joined(separator: "/")
    }

    private static func coalesced(_ segments: [TaskComposerSegment]) -> [TaskComposerSegment] {
        var result: [TaskComposerSegment] = []
        for segment in segments {
            if case .text(let value) = segment, value.isEmpty { continue }
            if case .text(let value) = segment, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + value)
            } else {
                result.append(segment)
            }
        }
        return result
    }
}

struct TaskRequestComposer: NSViewRepresentable {
    @Binding var draft: TaskComposerDraft
    let fontSize: CGFloat
    let focusRequested: Bool
    let onFocusChanged: (Bool) -> Void
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 7, bottom: 5, right: 7)

        let textView = TaskComposerTextView(frame: .zero)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 2)
        textView.delegate = context.coordinator
        textView.composerCoordinator = context.coordinator
        textView.registerForDraggedTypes([.fileURL, .URL])
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp("File and web address chips are editable references. Press Return or Space beside a chip to inspect it. Delete removes one reference.")
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.render(draft, in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? TaskComposerTextView else { return }
        let contentWidth = max(1, scrollView.contentSize.width)
        textView.setFrameSize(NSSize(width: contentWidth, height: max(scrollView.contentSize.height, textView.frame.height)))
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.applyFont(fontSize, to: textView)
        if context.coordinator.lastRenderedDraft != draft {
            context.coordinator.render(draft, in: textView)
        }
        if focusRequested, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        } else if !focusRequested, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TaskRequestComposer
        weak var textView: TaskComposerTextView?
        var lastRenderedDraft: TaskComposerDraft?
        private var popover: NSPopover?
        private var activePopoverReferenceID: UUID?

        init(parent: TaskRequestComposer) { self.parent = parent }

        func applyFont(_ size: CGFloat, to view: NSTextView) {
            view.font = .systemFont(ofSize: size)
            view.typingAttributes[.font] = NSFont.systemFont(ofSize: size)
        }

        func render(_ draft: TaskComposerDraft, in textView: TaskComposerTextView) {
            if let activePopoverReferenceID,
               !draft.segments.contains(where: { if case .reference(let item) = $0 { return item.id == activePopoverReferenceID }; return false }) {
                popover?.close()
                popover = nil
                self.activePopoverReferenceID = nil
            }
            let selection = textView.selectedRange()
            let result = NSMutableAttributedString(string: "")
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: parent.fontSize),
                                                               .foregroundColor: NSColor.labelColor]
            for segment in draft.segments {
                switch segment {
                case .text(let text):
                    result.append(NSAttributedString(string: text, attributes: attributes))
                case .reference(let reference):
                    let attachment = TaskComposerTextAttachment(reference: reference,
                        label: draft.displayLabel(for: reference))
                    let value = NSMutableAttributedString(attachment: attachment)
                    value.addAttributes(attributes, range: NSRange(location: 0, length: value.length))
                    value.addAttribute(.baselineOffset, value: -3, range: NSRange(location: 0, length: value.length))
                    result.append(value)
                }
            }
            textView.textStorage?.setAttributedString(result)
            textView.setSelectedRange(NSRange(location: min(selection.location, result.length), length: 0))
            lastRenderedDraft = draft
            textView.typingAttributes = attributes
            refreshLabels(in: textView, draft: draft)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TaskComposerTextView else { return }
            let updated = Self.draft(from: textView.attributedString())
            if let activePopoverReferenceID,
               !updated.segments.contains(where: { if case .reference(let item) = $0 { return item.id == activePopoverReferenceID }; return false }) {
                popover?.close()
                popover = nil
                self.activePopoverReferenceID = nil
            }
            parent.draft = updated
            lastRenderedDraft = updated
            refreshLabels(in: textView, draft: updated)
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChanged(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChanged(false) }

        func handleChip(_ reference: TaskComposerReference, anchor: NSRect, in textView: TaskComposerTextView) {
            popover?.close()
            activePopoverReferenceID = reference.id
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.contentSize = NSSize(width: 330, height: 190)
            popover.contentViewController = NSHostingController(rootView: TaskComposerReferencePopover(
                reference: reference,
                onRemove: { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.remove(reference.id, from: textView)
                    self.popover?.close()
                }
            ))
            self.popover = popover
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
        }

        func remove(_ id: UUID, from textView: TaskComposerTextView) {
            guard let range = Self.attachmentRange(id: id, in: textView.attributedString()) else { return }
            textView.insertText("", replacementRange: range)
        }

        func copySelection(from textView: TaskComposerTextView, cut: Bool) {
            let selection = textView.selectedRange()
            guard selection.length > 0, let storage = textView.textStorage else { return }
            let selected = storage.attributedSubstring(from: selection)
            let pieces = Self.pieces(from: selected)
            let plain = pieces.map { $0.value ?? $0.text ?? "" }.joined()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let customType = NSPasteboard.PasteboardType("com.taskpilot.exact-input-fragment")
            pasteboard.declareTypes([.string, customType], owner: nil)
            pasteboard.setString(plain, forType: .string)
            if let data = try? JSONEncoder().encode(TaskComposerClipboard(version: 1, pieces: pieces)) {
                pasteboard.setData(data, forType: customType)
            }
            if cut { textView.insertText("", replacementRange: selection) }
        }

        func paste(into textView: TaskComposerTextView) {
            let pasteboard = NSPasteboard.general
            let customType = NSPasteboard.PasteboardType("com.taskpilot.exact-input-fragment")
            if let data = pasteboard.data(forType: customType),
               let fragment = try? JSONDecoder().decode(TaskComposerClipboard.self, from: data),
               fragment.version == 1,
               let value = Self.attributedString(from: fragment) {
                textView.insertText(value, replacementRange: textView.selectedRange())
                return
            }
            let value = pasteboard.string(forType: .string)
            let urls = TaskComposerTextView.dragURLs(pasteboard)
            if let references = TaskComposerReferenceParser.pasted(text: value, urls: urls) {
                insert(references, at: textView.selectedRange().location, in: textView)
            } else {
                guard let value else { return }
                textView.insertText(value, replacementRange: textView.selectedRange())
            }
        }

        func insertDropped(_ urls: [URL], at index: Int, in textView: TaskComposerTextView) {
            let references = urls.compactMap { TaskComposerReferenceParser.dropped($0) }
            guard !references.isEmpty else { return }
            insert(references, at: index, in: textView)
        }

        private func insert(_ references: [TaskComposerReference], at index: Int, in textView: TaskComposerTextView) {
            guard !references.isEmpty else { return }
            let draft = parent.draft
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: parent.fontSize),
                                                               .foregroundColor: NSColor.labelColor]
            let insertion = NSMutableAttributedString(string: "")
            for (position, reference) in references.enumerated() {
                if position > 0 { insertion.append(NSAttributedString(string: " ", attributes: attributes)) }
                let attachment = TaskComposerTextAttachment(reference: reference, label: draft.displayLabel(for: reference))
                insertion.append(NSAttributedString(attachment: attachment))
            }
            textView.insertText(insertion, replacementRange: NSRange(location: index, length: 0))
        }

        private func refreshLabels(in textView: NSTextView, draft: TaskComposerDraft) {
            guard let storage = textView.textStorage else { return }
            var updates: [(NSRange, TaskComposerTextAttachment, String)] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attachment = value as? TaskComposerTextAttachment else { return }
                updates.append((range, attachment, draft.displayLabel(for: attachment.reference)))
            }
            for (range, attachment, label) in updates where attachment.label != label {
                attachment.updateLabel(label)
                textView.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                textView.setNeedsDisplay(textView.bounds)
            }
        }

        private static func draft(from attributed: NSAttributedString) -> TaskComposerDraft {
            var segments: [TaskComposerSegment] = []
            var text = ""
            for index in 0..<attributed.length {
                let range = NSRange(location: index, length: 1)
                if let attachment = attributed.attribute(.attachment, at: index, effectiveRange: nil) as? TaskComposerTextAttachment {
                    if !text.isEmpty { segments.append(.text(text)); text = "" }
                    segments.append(.reference(attachment.reference))
                } else {
                    text += attributed.attributedSubstring(from: range).string
                }
            }
            if !text.isEmpty { segments.append(.text(text)) }
            return TaskComposerDraft(segments: segments)
        }

        private static func pieces(from attributed: NSAttributedString) -> [TaskComposerClipboard.Piece] {
            var pieces: [TaskComposerClipboard.Piece] = []
            for segment in draft(from: attributed).segments {
                switch segment {
                case .text(let text): pieces.append(.init(text: text))
                case .reference(let reference): pieces.append(.init(kind: reference.kind.rawValue, value: reference.value))
                }
            }
            return pieces
        }

        private static func attributedString(from fragment: TaskComposerClipboard) -> NSAttributedString? {
            let result = NSMutableAttributedString(string: "")
            for piece in fragment.pieces {
                if let text = piece.text, piece.kind == nil, piece.value == nil {
                    result.append(NSAttributedString(string: text))
                } else if piece.text == nil, let rawKind = piece.kind, let kind = AgentTaskInputKind(rawValue: rawKind),
                          let value = piece.value,
                          let reference = TaskComposerReferenceParser.restored(kind: kind, value: value) {
                    result.append(NSAttributedString(attachment: TaskComposerTextAttachment(reference: reference,
                        label: displayLabel(reference))))
                } else { return nil }
            }
            return result
        }

        private static func attachmentRange(id: UUID, in attributed: NSAttributedString) -> NSRange? {
            guard attributed.length > 0 else { return nil }
            var found: NSRange?
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, stop in
                if (value as? TaskComposerTextAttachment)?.reference.id == id { found = range; stop.pointee = true }
            }
            return found
        }

        private static func displayLabel(_ reference: TaskComposerReference) -> String {
            if reference.kind == .url, let components = URLComponents(string: reference.value) {
                return components.host.map { $0 + (components.percentEncodedPath == "/" ? "" : components.percentEncodedPath) } ?? "Web address"
            }
            return URL(fileURLWithPath: reference.value).lastPathComponent
        }
    }
}

private struct TaskComposerClipboard: Codable {
    struct Piece: Codable {
        var text: String? = nil
        var kind: String? = nil
        var value: String? = nil
        init(text: String) { self.text = text }
        init(kind: String, value: String) { self.kind = kind; self.value = value }
    }
    let version: Int
    let pieces: [Piece]
}

private final class TaskComposerTextAttachment: NSTextAttachment {
    let reference: TaskComposerReference
    private(set) var label: String

    init(reference: TaskComposerReference, label: String) {
        self.reference = reference
        self.label = label
        super.init(data: nil, ofType: "com.taskpilot.exact-input-reference")
        attachmentCell = TaskComposerChipCell(label: label, reference: reference)
    }

    required init?(coder: NSCoder) { return nil }

    func updateLabel(_ label: String) {
        self.label = label
        attachmentCell = TaskComposerChipCell(label: label, reference: reference)
    }
}

private final class TaskComposerChipCell: NSTextAttachmentCell {
    private let reference: TaskComposerReference
    private let labelText: String
    private let icon: NSImage

    init(label: String, reference: TaskComposerReference) {
        self.reference = reference
        self.labelText = label
        if reference.kind == .url {
            self.icon = NSImage(systemSymbolName: "link", accessibilityDescription: "Web address") ?? NSImage()
        } else {
            self.icon = NSWorkspace.shared.icon(forFile: reference.value)
        }
        super.init(textCell: label)
        setAccessibilityLabel("\(reference.kind == .folder ? "Folder" : reference.kind == .file ? "File" : "Web address"): \(label)")
    }

    required init(coder: NSCoder) { fatalError("Task composer chip cells are not archived") }

    override func cellSize() -> NSSize {
        let textWidth = (labelText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        return NSSize(width: min(310, max(72, textWidth + 34)), height: 23)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let bounds = cellFrame.insetBy(dx: 0.5, dy: 1.5)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let iconRect = NSRect(x: bounds.minX + 5, y: bounds.minY + 3, width: 15, height: 15)
        icon.draw(in: iconRect)
        let titleRect = NSRect(x: iconRect.maxX + 4, y: bounds.minY + 3,
                               width: max(0, bounds.maxX - iconRect.maxX - 8), height: 15)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        labelText.draw(in: titleRect, withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                    .foregroundColor: NSColor.labelColor,
                                                    .paragraphStyle: style])
    }
}

final class TaskComposerTextView: NSTextView {
    weak var composerCoordinator: TaskRequestComposer.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let (attachment, anchor) = attachment(at: event.locationInWindow) {
            composerCoordinator?.handleChip(attachment.reference, anchor: anchor, in: self)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49,
           let attachment = adjacentAttachment() {
            let range = selectedRange()
            let rect = layoutManager?.boundingRect(forGlyphRange: NSRange(location: range.location, length: 0), in: textContainer!) ?? .zero
            composerCoordinator?.handleChip(attachment.reference, anchor: rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), in: self)
            return
        }
        super.keyDown(with: event)
    }

    override func copy(_ sender: Any?) { composerCoordinator?.copySelection(from: self, cut: false) }
    override func cut(_ sender: Any?) { composerCoordinator?.copySelection(from: self, cut: true) }
    override func paste(_ sender: Any?) { composerCoordinator?.paste(into: self) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.dragURLs(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        let urls = Self.dragURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        composerCoordinator?.insertDropped(urls, at: index, in: self)
        return true
    }

    private func attachment(at windowPoint: NSPoint) -> (TaskComposerTextAttachment, NSRect)? {
        guard let layoutManager, let textContainer else { return nil }
        let point = convert(windowPoint, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < attributedString().length,
              let attachment = attributedString().attribute(.attachment, at: character, effectiveRange: nil) as? TaskComposerTextAttachment else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return (attachment, rect)
    }

    private func adjacentAttachment() -> TaskComposerTextAttachment? {
        let position = selectedRange().location
        let attributed = attributedString()
        for index in [position, position - 1] where index >= 0 && index < attributed.length {
            if let attachment = attributed.attribute(.attachment, at: index, effectiveRange: nil) as? TaskComposerTextAttachment {
                return attachment
            }
        }
        return nil
    }

    static func dragURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []).filter {
            $0.isFileURL || (["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil)
        }
    }
}

private struct TaskComposerReferencePopover: View {
    let reference: TaskComposerReference
    let onRemove: () -> Void
    @State private var showQuickLook = false
    @State private var localDetails: String?
    @State private var previewUnavailable = false

    private var fileURL: URL? {
        guard reference.kind != .url else { return nil }
        return URL(fileURLWithPath: reference.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: reference.kind == .url ? "link" : reference.kind == .folder ? "folder" : "doc")
                    .foregroundStyle(.tint)
                Text(reference.kind == .url ? "Web address" : reference.kind == .folder ? "Folder reference" : "File reference")
                    .font(.headline)
                Spacer()
                Button("Remove", role: .destructive, action: onRemove)
                    .keyboardShortcut(.delete, modifiers: [])
            }
            Text(reference.value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
            if let localDetails {
                Text(localDetails).font(.caption).foregroundStyle(.secondary)
            }
            if previewUnavailable {
                Text("This reference is currently unavailable.").font(.caption).foregroundStyle(.secondary)
            }
            if reference.kind == .file, !previewUnavailable {
                Button(showQuickLook ? "Hide Quick Look" : "Quick Look") { showQuickLook.toggle() }
                    .buttonStyle(.bordered)
            }
            if showQuickLook, let fileURL {
                TaskResultQuickLookView(url: fileURL).frame(height: 220)
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        .task(id: reference.id) { await inspectLocalReference() }
    }

    @MainActor
    private func inspectLocalReference() async {
        guard let fileURL else { return }
        let path = fileURL.path
        let detail = await Task.detached(priority: .utility) { () -> (String?, Bool) in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return (nil, true) }
            guard FileManager.default.isReadableFile(atPath: path) else { return (nil, true) }
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            if isDirectory.boolValue || values?.isDirectory == true {
                let modified = values?.contentModificationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
                return (modified.map { "Folder · modified \($0)" } ?? "Folder exists and is readable", false)
            }
            let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "File"
            return ("\(size) · local file", false)
        }.value
        guard !Task.isCancelled else { return }
        localDetails = detail.0
        previewUnavailable = detail.1
        if detail.1 { showQuickLook = false }
    }
}
