import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

enum TaskComposerRoleOrigin: Equatable {
    case chosen
    case inferred
    case unresolved
}

struct TaskComposerReference: Equatable, Identifiable {
    let id: UUID
    let kind: AgentTaskInputKind
    let value: String
    var userRole: AgentTaskInputRole?
    var presentedRole: AgentTaskInputRole?
    var roleOrigin: TaskComposerRoleOrigin
    var inferredRole: AgentTaskInputRole?
    var pendingRole: AgentTaskInputRole?
    var roleCorrectionPending: Bool
    var occurrenceID: String?

    var rolePickerSelection: AgentTaskInputRole? {
        roleCorrectionPending ? pendingRole : userRole
    }

    init(id: UUID = UUID(), kind: AgentTaskInputKind, value: String,
         userRole: AgentTaskInputRole? = nil, presentedRole: AgentTaskInputRole? = nil,
         roleOrigin: TaskComposerRoleOrigin? = nil, inferredRole: AgentTaskInputRole? = nil,
         pendingRole: AgentTaskInputRole? = nil,
         roleCorrectionPending: Bool = false, occurrenceID: String? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.userRole = userRole
        self.inferredRole = inferredRole ?? (userRole == nil && roleOrigin == .inferred ? presentedRole : nil)
        self.presentedRole = presentedRole ?? userRole ?? self.inferredRole
        self.roleOrigin = roleOrigin ?? (userRole == nil
            ? (self.inferredRole == nil ? .unresolved : .inferred) : .chosen)
        self.pendingRole = pendingRole
        self.roleCorrectionPending = roleCorrectionPending
        self.occurrenceID = occurrenceID
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
        case .text:
            break
        }
        return TaskComposerReference(kind: kind, value: value)
    }

    static func remixLiteral(_ value: String) -> TaskComposerReference? {
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil {
            return TaskComposerReference(kind: .url, value: value)
        }
        if value.hasPrefix("/") {
            let url = URL(fileURLWithPath: value)
            guard FileManager.default.fileExists(atPath: value) else {
                return TaskComposerReference(kind: .text, value: value)
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
            return TaskComposerReference(kind: isDirectory ? .folder : .file, value: value)
        }
        return TaskComposerReference(kind: .text, value: value)
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

private struct TaskComposerLabelInput: Equatable {
    let id: UUID
    let kind: AgentTaskInputKind
    let value: String
}

struct TaskComposerDraft: Equatable {
    private var invalidRestoredSubmission: AgentTaskSubmission?
    var segments: [TaskComposerSegment] {
        didSet {
            if oldValue != segments { invalidRestoredSubmission = nil }
        }
    }

    init(segments: [TaskComposerSegment] = []) {
        invalidRestoredSubmission = nil
        self.segments = Self.coalesced(segments)
    }

    init(plainText: String) {
        self.init(segments: plainText.isEmpty ? [] : [.text(plainText)])
    }

    init(submission: AgentTaskSubmission) {
        guard (try? submission.validateExactInputReferences()) != nil else {
            self.init(plainText: submission.request)
            invalidRestoredSubmission = submission
            return
        }
        let bytes = Array(submission.request.utf8)
        let references = submission.exactInputReferences.sorted { $0.utf8Start < $1.utf8Start }
        var result: [TaskComposerSegment] = []
        var cursor = 0
        for reference in references {
            guard reference.utf8Start >= cursor,
                  reference.utf8Start <= bytes.count,
                  reference.utf8Length > 0,
                  reference.utf8Length <= bytes.count - reference.utf8Start else {
                self.init(plainText: submission.request)
                invalidRestoredSubmission = submission
                return
            }
            let end = reference.utf8Start + reference.utf8Length
            guard
                  let value = String(bytes: bytes[reference.utf8Start..<end], encoding: .utf8),
                  value == reference.value else {
                self.init(plainText: submission.request)
                invalidRestoredSubmission = submission
                return
            }
            if cursor < reference.utf8Start {
                result.append(.text(String(decoding: bytes[cursor..<reference.utf8Start], as: UTF8.self)))
            }
            result.append(.reference(TaskComposerReference(id: Self.stableReferenceID(reference),
                kind: reference.kind, value: reference.value,
                userRole: reference.userRole, occurrenceID: reference.id)))
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

    func hasSameContent(as other: TaskComposerDraft) -> Bool {
        guard segments.count == other.segments.count else { return false }
        for (left, right) in zip(segments, other.segments) {
            switch (left, right) {
            case (.text(let lhs), .text(let rhs)) where lhs == rhs:
                continue
            case (.reference(let lhs), .reference(let rhs))
                where lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.value == rhs.value:
                continue
            default:
                return false
            }
        }
        return true
    }

    /// Compares the editable request rather than presentation-only role state.
    /// An explicit role is part of the draft and must invalidate another
    /// editor's stale undo history; inferred and pending labels are not edits.
    func hasSameEditorContent(as other: TaskComposerDraft) -> Bool {
        guard segments.count == other.segments.count else { return false }
        for (left, right) in zip(segments, other.segments) {
            switch (left, right) {
            case (.text(let lhs), .text(let rhs)) where lhs == rhs:
                continue
            case (.reference(let lhs), .reference(let rhs))
                where lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.value == rhs.value &&
                    lhs.userRole == rhs.userRole:
                continue
            default:
                return false
            }
        }
        return true
    }

    func submission() -> AgentTaskSubmission {
        if let invalidRestoredSubmission { return invalidRestoredSubmission }
        var text = ""
        var references: [AgentTaskInputReference] = []
        for segment in segments {
            switch segment {
            case .text(let value): text += value
            case .reference(let reference):
                let start = text.utf8.count
                text += reference.value
                references.append(AgentTaskInputReference(kind: reference.kind, utf8Start: start,
                    utf8Length: reference.value.utf8.count, value: reference.value, userRole: reference.userRole))
            }
        }
        return AgentTaskSubmission(request: text, exactInputReferences: references)
    }

    func displayLabel(for reference: TaskComposerReference) -> String {
        displayLabels()[reference.id] ?? (reference.kind == .url ? "Web address" : reference.value)
    }

    func displayLabels() -> [UUID: String] {
        let references = self.references
        let localReferences = references.filter { $0.kind == .file || $0.kind == .folder }
        let pathComponents = Dictionary(uniqueKeysWithValues: localReferences.map { reference in
            (reference.id, URL(fileURLWithPath: reference.value).standardizedFileURL.pathComponents.filter { $0 != "/" })
        })
        let uniquePathsByName = Dictionary(grouping: localReferences) { reference in
            pathComponents[reference.id]?.last ?? reference.value
        }.mapValues { group in
            Set(group.compactMap { pathComponents[$0.id] }.map { $0.joined(separator: "/") })
        }
        let nonURLReferences = references.filter { $0.kind != .url }
        let distinctTextValuesByName = Dictionary(grouping: nonURLReferences) {
            $0.value.split(separator: "/").last.map(String.init) ?? $0.value
        }.mapValues { Set($0.map(\.value)) }
        var distinctPathsBySuffix: [String: Set<String>] = [:]
        for group in Dictionary(grouping: localReferences, by: { pathComponents[$0.id]?.last ?? $0.value }).values {
            let paths = Set(group.compactMap { pathComponents[$0.id] })
            for components in paths {
                let fullPath = components.joined(separator: "/")
                for depth in 1...max(1, components.count) {
                    distinctPathsBySuffix[components.suffix(depth).joined(separator: "/"), default: []].insert(fullPath)
                }
            }
        }
        var labels: [UUID: String] = [:]

        for reference in references {
            if reference.kind == .text {
                let firstLine = reference.value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? reference.value
                let label = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                let basename = label.split(separator: "/").last.map(String.init)
                let hasDistinctPeer = basename.map { name in
                    (distinctTextValuesByName[name] ?? []).contains { $0 != reference.value }
                } ?? false
                labels[reference.id] = label.isEmpty ? "Exact text" :
                    String((hasDistinctPeer ? label.suffix(72) : label.prefix(48)))
                continue
            }
            if reference.kind == .url {
                guard let components = URLComponents(string: reference.value) else {
                    labels[reference.id] = "Web address"
                    continue
                }
                let host = components.host ?? "Web address"
                let path = components.percentEncodedPath
                labels[reference.id] = path.isEmpty || path == "/" ? host : host + path
                continue
            }

            let components = pathComponents[reference.id] ?? []
            let name = components.last ?? reference.value
            guard (uniquePathsByName[name]?.count ?? 0) > 1 else {
                labels[reference.id] = name
                continue
            }
            var distinguishingSuffix: String?
            for depth in 1...max(1, components.count) {
                let suffix = components.suffix(depth).joined(separator: "/")
                if distinctPathsBySuffix[suffix]?.count == 1 {
                    distinguishingSuffix = suffix
                    break
                }
            }
            labels[reference.id] = distinguishingSuffix ?? components.joined(separator: "/")
        }
        return labels
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

    private static func stableReferenceID(_ reference: AgentTaskInputReference) -> UUID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(reference.utf8Start):\(reference.utf8Length):\(reference.kind.rawValue)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let suffix = String(format: "%012llx", hash & 0x0000_FFFF_FFFF_FFFF)
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }
}

struct TaskRequestComposer: NSViewRepresentable {
    @Binding var draft: TaskComposerDraft
    let fontSize: CGFloat
    let focusRequested: Bool
    var managesFocus = true
    var editorSessionID: UUID? = nil
    let onFocusChanged: (Bool) -> Void
    let accessibilityLabel: String
    var isReadOnly = false
    var canChangeRole = false
    var hasExistingCorrection = false
    var onRoleCorrection: ((String, AgentTaskInputRole?) -> Bool)? = nil
    var onContinueCorrection: (() -> Void)? = nil

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
        textView.isEditable = !isReadOnly
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
        textView.setAccessibilityHelp(isReadOnly
            ? "Exact input references are shown as read-only chips. Press Return or Space beside or on a chip to inspect its purpose."
            : "Type spaces and line breaks normally beside input chips. Press Option-Return beside or on a chip to inspect it. Delete removes one reference.")
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.render(draft, in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? TaskComposerTextView else { return }
        let contentWidth = max(1, scrollView.contentSize.width)
        let desiredSize = NSSize(width: contentWidth, height: max(scrollView.contentSize.height, textView.frame.height))
        if textView.frame.size != desiredSize { textView.setFrameSize(desiredSize) }
        let containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        if textView.textContainer?.containerSize != containerSize {
            textView.textContainer?.containerSize = containerSize
        }
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.isEditable = !isReadOnly
        context.coordinator.applyFont(fontSize, to: textView)
        context.coordinator.update(draft, in: textView)
        context.coordinator.refreshActivePopover(using: draft, in: textView)
        context.coordinator.updateFocusRequest(focusRequested, managesFocus: managesFocus, in: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
        var parent: TaskRequestComposer
        weak var textView: TaskComposerTextView?
        var lastRenderedDraft: TaskComposerDraft?
        private var popover: NSPopover?
        private var popoverHost: NSHostingController<TaskComposerReferencePopover>?
        private var activePopoverReferenceID: UUID?
        private var lastPopoverReference: TaskComposerReference?
        private var lastPopoverCanChangeRole: Bool?
        private var lastPopoverHasExistingCorrection: Bool?
        private var lastAppliedFontSize: CGFloat?
        private var lastEditorSessionID: UUID?
        private var lastFocusRequest: Bool?
        private var lastManagesFocus: Bool?
        private var focusRequestNeedsApplication = false
        private var focusCallbackGeneration: UInt64 = 0
        private var lastReportedFocusState: Bool?
        private var isReplacingExternalContent = false
        private var labelCacheInputs: [TaskComposerLabelInput] = []
        private var labelCache: [UUID: String] = [:]
        private(set) var labelIndexBuildCount = 0

        init(parent: TaskRequestComposer) {
            self.parent = parent
            lastEditorSessionID = parent.editorSessionID
        }

        func applyFont(_ size: CGFloat, to view: NSTextView) {
            guard lastAppliedFontSize != size else { return }
            view.font = .systemFont(ofSize: size)
            view.typingAttributes[.font] = NSFont.systemFont(ofSize: size)
            lastAppliedFontSize = size
            guard let storage = view.textStorage, storage.length > 0 else { return }
            var attachments: [(NSRange, TaskComposerTextAttachment)] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attachment = value as? TaskComposerTextAttachment else { return }
                attachments.append((range, attachment))
            }
            for (range, attachment) in attachments {
                if attachment.updateFontSize(size) {
                    storage.edited(.editedAttributes, range: range, changeInLength: 0)
                }
            }
        }

        func render(_ draft: TaskComposerDraft, in textView: TaskComposerTextView) {
            if let activePopoverReferenceID,
               !draft.segments.contains(where: { if case .reference(let item) = $0 { return item.id == activePopoverReferenceID }; return false }) {
                dismissActivePopover()
            }
            let selection = textView.selectedRange()
            let labels = labelIndex(for: draft)
            let result = NSMutableAttributedString(string: "")
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: parent.fontSize),
                                                               .foregroundColor: NSColor.labelColor]
            for segment in draft.segments {
                switch segment {
                case .text(let text):
                    result.append(NSAttributedString(string: text, attributes: attributes))
                case .reference(let reference):
                    result.append(Self.attributedAttachment(reference,
                        label: labels[reference.id] ?? reference.value, fontSize: parent.fontSize))
                }
            }
            textView.textStorage?.setAttributedString(result)
            let location = min(max(0, selection.location), result.length)
            let available = result.length - location
            let length = min(max(0, selection.length), available)
            textView.setSelectedRange(NSRange(location: location, length: length))
            lastRenderedDraft = draft
            textView.typingAttributes = attributes
            refreshLabels(in: textView, draft: draft)
        }

        func update(_ draft: TaskComposerDraft, in textView: TaskComposerTextView) {
            let sessionChanged = lastEditorSessionID != parent.editorSessionID
            if sessionChanged {
                lastEditorSessionID = parent.editorSessionID
            }
            let externalContentChanged = lastRenderedDraft.map { !$0.hasSameEditorContent(as: draft) } ?? false
            if sessionChanged {
                replaceLoadedDraft(draft, in: textView)
                return
            }
            if externalContentChanged {
                guard let previous = lastRenderedDraft else {
                    replaceLoadedDraft(draft, in: textView)
                    return
                }
                if previous.hasSameContent(as: draft) {
                    // A role changed in another editor. Keep this editor's
                    // attachment and selection, but invalidate its stale undo
                    // entries before applying the shared role presentation.
                    textView.undoManager?.removeAllActions()
                    textView.breakUndoCoalescing()
                } else {
                    replaceLoadedDraft(draft, in: textView)
                    return
                }
            }
            guard let previous = lastRenderedDraft, previous != draft else { return }
            guard previous.hasSameContent(as: draft) else {
                render(draft, in: textView)
                return
            }
            let referencesByID = draft.segments.reduce(into: [UUID: TaskComposerReference]()) { result, segment in
                guard case .reference(let reference) = segment else { return }
                result[reference.id] = reference
            }
            guard let storage = textView.textStorage, storage.length > 0 else {
                lastRenderedDraft = draft
                return
            }
            var updates: [(TaskComposerTextAttachment, TaskComposerReference)] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                guard let attachment = value as? TaskComposerTextAttachment,
                      let updated = referencesByID[attachment.reference.id], attachment.reference != updated else { return }
                updates.append((attachment, updated))
            }
            for (attachment, reference) in updates { attachment.updateReference(reference) }
            lastRenderedDraft = draft
        }

        private func replaceLoadedDraft(_ draft: TaskComposerDraft, in textView: TaskComposerTextView) {
            dismissActivePopover()
            isReplacingExternalContent = true
            if textView.hasMarkedText() {
                textView.inputContext?.discardMarkedText()
            }
            textView.undoManager?.removeAllActions()
            textView.breakUndoCoalescing()
            render(draft, in: textView)
            isReplacingExternalContent = false
        }

        func detach() {
            focusCallbackGeneration &+= 1
            dismissActivePopover()
            textView?.composerCoordinator = nil
            textView = nil
        }

        func updateFocusRequest(_ requested: Bool, managesFocus: Bool,
                                in textView: TaskComposerTextView) {
            guard lastFocusRequest != requested || lastManagesFocus != managesFocus else { return }
            lastFocusRequest = requested
            lastManagesFocus = managesFocus
            focusCallbackGeneration &+= 1
            guard managesFocus, requested else {
                focusRequestNeedsApplication = false
                return
            }
            focusRequestNeedsApplication = true
            attemptRequestedFocus(in: textView)
        }

        func attemptRequestedFocus(in textView: TaskComposerTextView) {
            guard focusRequestNeedsApplication, parent.managesFocus, parent.focusRequested else { return }
            focusCallbackGeneration &+= 1
            let generation = focusCallbackGeneration
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.focusCallbackGeneration == generation,
                      self.textView === textView, self.parent.managesFocus,
                      self.focusRequestNeedsApplication, self.parent.focusRequested,
                      let window = textView.window else { return }
                if window.firstResponder === textView {
                    self.focusRequestNeedsApplication = false
                } else if window.makeFirstResponder(textView) {
                    self.focusRequestNeedsApplication = false
                }
            }
        }

        func textView(_ textView: TaskComposerTextView, didChangeFirstResponder focused: Bool) {
            focusCallbackGeneration &+= 1
            let generation = focusCallbackGeneration
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.focusCallbackGeneration == generation,
                      self.textView === textView, let window = textView.window,
                      (window.firstResponder === textView) == focused else { return }
                guard self.lastReportedFocusState != focused else { return }
                self.lastReportedFocusState = focused
                if focused { self.focusRequestNeedsApplication = false }
                self.parent.onFocusChanged(focused)
            }
        }

        func textViewDidMoveToWindow(_ textView: TaskComposerTextView) {
            guard textView.window != nil else {
                guard lastReportedFocusState == true else { return }
                focusCallbackGeneration &+= 1
                let generation = focusCallbackGeneration
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView, self.focusCallbackGeneration == generation,
                          self.textView === textView, textView.window == nil,
                          self.lastReportedFocusState == true else { return }
                    self.lastReportedFocusState = false
                    self.parent.onFocusChanged(false)
                }
                return
            }
            if textView.window?.firstResponder === textView {
                self.textView(textView, didChangeFirstResponder: true)
            }
            attemptRequestedFocus(in: textView)
        }

        func dismissActivePopover() {
            let closingPopover = popover
            popover = nil
            popoverHost = nil
            activePopoverReferenceID = nil
            lastPopoverReference = nil
            lastPopoverCanChangeRole = nil
            lastPopoverHasExistingCorrection = nil
            closingPopover?.delegate = nil
            closingPopover?.close()
            closingPopover?.contentViewController = nil
        }

        func popoverDidClose(_ notification: Notification) {
            guard let closedPopover = notification.object as? NSPopover, closedPopover === popover else { return }
            popover = nil
            popoverHost = nil
            activePopoverReferenceID = nil
            lastPopoverReference = nil
            lastPopoverCanChangeRole = nil
            lastPopoverHasExistingCorrection = nil
            closedPopover.contentViewController = nil
        }

        func textDidChange(_ notification: Notification) {
            guard !isReplacingExternalContent else { return }
            guard let textView = notification.object as? TaskComposerTextView else { return }
            let updated = Self.draft(from: textView.attributedString())
            if let activePopoverReferenceID,
               !updated.segments.contains(where: { if case .reference(let item) = $0 { return item.id == activePopoverReferenceID }; return false }) {
                dismissActivePopover()
            }
            parent.draft = updated
            lastRenderedDraft = updated
            refreshLabels(in: textView, draft: updated)
        }

        func handleChip(_ reference: TaskComposerReference, anchor: NSRect, in textView: TaskComposerTextView) {
            dismissActivePopover()
            activePopoverReferenceID = reference.id
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.contentSize = NSSize(width: 360, height: 280)
            popover.delegate = self
            let host = NSHostingController(rootView: makePopoverContent(reference, in: textView))
            popover.contentViewController = host
            self.popoverHost = host
            lastPopoverReference = reference
            lastPopoverCanChangeRole = parent.canChangeRole
            lastPopoverHasExistingCorrection = parent.hasExistingCorrection
            self.popover = popover
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
        }

        func refreshActivePopover(using draft: TaskComposerDraft, in textView: TaskComposerTextView) {
            guard let activePopoverReferenceID,
                  let popoverHost,
                  let reference = draft.segments.compactMap({ segment -> TaskComposerReference? in
                      if case .reference(let reference) = segment { return reference }
                      return nil
                  }).first(where: { $0.id == activePopoverReferenceID }) else { return }
            guard lastPopoverReference != reference ||
                    lastPopoverCanChangeRole != parent.canChangeRole ||
                    lastPopoverHasExistingCorrection != parent.hasExistingCorrection else { return }
            popoverHost.rootView = makePopoverContent(reference, in: textView)
            lastPopoverReference = reference
            lastPopoverCanChangeRole = parent.canChangeRole
            lastPopoverHasExistingCorrection = parent.hasExistingCorrection
        }

        private func makePopoverContent(_ reference: TaskComposerReference,
                                        in textView: TaskComposerTextView) -> TaskComposerReferencePopover {
            TaskComposerReferencePopover(
                reference: reference,
                isReadOnly: parent.isReadOnly,
                canChangeRole: parent.canChangeRole,
                hasExistingCorrection: parent.hasExistingCorrection,
                onReplace: { [weak self, weak textView] updated in
                    guard let self, let textView else { return }
                    self.replace(reference.id, with: updated, in: textView)
                    self.dismissActivePopover()
                },
                onRemove: { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.remove(reference.id, from: textView)
                    self.dismissActivePopover()
                },
                onRoleCorrection: { [weak self, weak textView] role in
                    guard let self else { return false }
                    return self.applyRoleCorrection(role, to: reference, in: textView)
                },
                onContinueCorrection: parent.onContinueCorrection
            )
        }

        func remove(_ id: UUID, from textView: TaskComposerTextView) {
            guard !parent.isReadOnly else { return }
            guard let range = Self.attachmentRange(id: id, in: textView.attributedString()) else { return }
            textView.insertText("", replacementRange: range)
        }

        func replace(_ id: UUID, with reference: TaskComposerReference, in textView: TaskComposerTextView) {
            guard !parent.isReadOnly else { return }
            guard let range = Self.attachmentRange(id: id, in: textView.attributedString()) else { return }
            let currentDraft = Self.draft(from: textView.attributedString())
            let updated = TaskComposerReference(id: id, kind: reference.kind, value: reference.value,
                userRole: reference.userRole, presentedRole: reference.presentedRole,
                roleOrigin: reference.roleOrigin, inferredRole: reference.inferredRole,
                pendingRole: reference.pendingRole,
                roleCorrectionPending: reference.roleCorrectionPending, occurrenceID: reference.occurrenceID)
            let projectedDraft = TaskComposerDraft(segments: currentDraft.segments.map { segment in
                guard case .reference(let current) = segment, current.id == id else { return segment }
                return .reference(updated)
            })
            let attributed = Self.attributedAttachment(updated,
                label: labelIndex(for: projectedDraft)[updated.id] ?? updated.value, fontSize: parent.fontSize)
            textView.insertText(attributed, replacementRange: range)
        }

        @discardableResult
        func applyRoleCorrection(_ role: AgentTaskInputRole?, to reference: TaskComposerReference,
                                 in textView: TaskComposerTextView?) -> Bool {
            if parent.isReadOnly {
                guard let textView,
                      let current = Self.attachment(id: reference.id, in: textView.attributedString())?.reference,
                      current.kind == reference.kind,
                      current.value == reference.value,
                      current.occurrenceID == reference.occurrenceID,
                      let occurrenceID = current.occurrenceID else { return false }
                guard current.userRole != role else { return true }
                return parent.onRoleCorrection?(occurrenceID, role) ?? false
            }
            guard let textView else { return false }
            guard let attachment = Self.attachment(id: reference.id, in: textView.attributedString()) else { return false }
            let previous = attachment.reference
            guard previous.kind == reference.kind,
                  previous.value == reference.value,
                  previous.occurrenceID == reference.occurrenceID else { return false }
            guard previous.userRole != role else { return true }
            let inferredRole = previous.inferredRole
            let updated = TaskComposerReference(id: previous.id, kind: previous.kind, value: previous.value,
                userRole: role, presentedRole: inferredRole,
                roleOrigin: role != nil ? .chosen : inferredRole == nil ? .unresolved : .inferred,
                inferredRole: inferredRole,
                occurrenceID: previous.occurrenceID)
            updateDraftReference(updated, replacing: previous, in: textView, registerUndo: true)
            return true
        }

        private func updateDraftReference(_ reference: TaskComposerReference,
                                          replacing previous: TaskComposerReference,
                                          in textView: TaskComposerTextView,
                                          registerUndo: Bool) {
            guard reference.id == previous.id,
                  let attachment = Self.attachment(id: reference.id, in: textView.attributedString()),
                  attachment.reference == previous else { return }
            if registerUndo, let undoManager = textView.undoManager {
                undoManager.registerUndo(withTarget: self) { [weak textView] coordinator in
                    guard let textView else { return }
                    coordinator.updateDraftReference(previous, replacing: reference, in: textView, registerUndo: true)
                }
                undoManager.setActionName("Change input role")
            }
            attachment.updateReference(reference)
            let updatedDraft = Self.draft(from: textView.attributedString())
            parent.draft = updatedDraft
            lastRenderedDraft = updatedDraft
        }

        func copySelection(from textView: TaskComposerTextView, cut: Bool,
                           to suppliedPasteboard: NSPasteboard? = nil) {
            guard !cut || !parent.isReadOnly else { return }
            let selection = textView.selectedRange()
            guard selection.length > 0, let storage = textView.textStorage else { return }
            let selected = storage.attributedSubstring(from: selection)
            let pieces = Self.pieces(from: selected)
            let plain = pieces.map { $0.value ?? $0.text ?? "" }.joined()
            let pasteboard = suppliedPasteboard ?? .general
            pasteboard.clearContents()
            let customType = NSPasteboard.PasteboardType("com.taskpilot.exact-input-fragment")
            pasteboard.declareTypes([.string, customType], owner: nil)
            pasteboard.setString(plain, forType: .string)
            if let data = try? JSONEncoder().encode(TaskComposerClipboard(version: 2, pieces: pieces)) {
                pasteboard.setData(data, forType: customType)
            }
            if cut { textView.insertText("", replacementRange: selection) }
        }

        func paste(into textView: TaskComposerTextView, from suppliedPasteboard: NSPasteboard? = nil) {
            guard !parent.isReadOnly else { return }
            let pasteboard = suppliedPasteboard ?? .general
            let customType = NSPasteboard.PasteboardType("com.taskpilot.exact-input-fragment")
            if let data = pasteboard.data(forType: customType),
               let fragment = try? JSONDecoder().decode(TaskComposerClipboard.self, from: data),
               (fragment.version == 1 || fragment.version == 2),
               let value = Self.attributedString(from: fragment, fontSize: parent.fontSize) {
                textView.insertText(value, replacementRange: textView.selectedRange())
                return
            }
            let value = pasteboard.string(forType: .string)
            let urls = TaskComposerTextView.dragURLs(pasteboard)
            if let references = TaskComposerReferenceParser.pasted(text: value, urls: urls) {
                insert(references, replacing: textView.selectedRange(), in: textView)
            } else {
                guard let value else { return }
                textView.insertText(value, replacementRange: textView.selectedRange())
            }
        }

        func insertDropped(_ urls: [URL], at index: Int, in textView: TaskComposerTextView) {
            guard !parent.isReadOnly else { return }
            let references = urls.compactMap { TaskComposerReferenceParser.dropped($0) }
            guard !references.isEmpty else { return }
            insert(references, replacing: NSRange(location: index, length: 0), in: textView)
        }

        private func insert(_ references: [TaskComposerReference], replacing range: NSRange, in textView: TaskComposerTextView) {
            guard !parent.isReadOnly, !references.isEmpty else { return }
            guard range.location >= 0, range.length >= 0,
                  range.location <= textView.attributedString().length,
                  range.length <= textView.attributedString().length - range.location else { return }
            let currentDraft = Self.draft(from: textView.attributedString())
            let projectedDraft = TaskComposerDraft(segments: currentDraft.segments + references.map { .reference($0) })
            let labels = labelIndex(for: projectedDraft)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: parent.fontSize),
                                                               .foregroundColor: NSColor.labelColor]
            let insertion = NSMutableAttributedString(string: "")
            for (position, reference) in references.enumerated() {
                if position > 0 { insertion.append(NSAttributedString(string: " ", attributes: attributes)) }
                insertion.append(Self.attributedAttachment(reference,
                    label: labels[reference.id] ?? reference.value, fontSize: parent.fontSize))
            }
            textView.insertText(insertion, replacementRange: range)
        }

        func refreshLabels(in textView: NSTextView, draft: TaskComposerDraft) {
            guard let storage = textView.textStorage else { return }
            let labels = labelIndex(for: draft)
            var updates: [(NSRange, TaskComposerTextAttachment, String)] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attachment = value as? TaskComposerTextAttachment else { return }
                updates.append((range, attachment, labels[attachment.reference.id] ?? attachment.reference.value))
            }
            for (range, attachment, label) in updates where attachment.label != label {
                attachment.updateLabel(label)
                textView.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                textView.setNeedsDisplay(textView.bounds)
            }
        }

        func labelIndex(for draft: TaskComposerDraft) -> [UUID: String] {
            let inputs = draft.references.map {
                TaskComposerLabelInput(id: $0.id, kind: $0.kind, value: $0.value)
            }
            guard inputs != labelCacheInputs else { return labelCache }
            labelCacheInputs = inputs
            labelCache = draft.displayLabels()
            labelIndexBuildCount += 1
            return labelCache
        }

        static func draft(from attributed: NSAttributedString) -> TaskComposerDraft {
            var segments: [TaskComposerSegment] = []
            guard attributed.length > 0 else { return TaskComposerDraft() }
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                if let attachment = value as? TaskComposerTextAttachment {
                    segments.append(.reference(attachment.reference))
                } else {
                    segments.append(.text(attributed.attributedSubstring(from: range).string))
                }
            }
            return TaskComposerDraft(segments: segments)
        }

        private static func pieces(from attributed: NSAttributedString) -> [TaskComposerClipboard.Piece] {
            var pieces: [TaskComposerClipboard.Piece] = []
            for segment in draft(from: attributed).segments {
                switch segment {
                case .text(let text): pieces.append(.init(text: text))
                case .reference(let reference):
                    pieces.append(.init(kind: reference.kind.rawValue, value: reference.value, role: reference.userRole))
                }
            }
            return pieces
        }

        private static func attributedString(from fragment: TaskComposerClipboard, fontSize: CGFloat) -> NSAttributedString? {
            var segments: [TaskComposerSegment] = []
            for piece in fragment.pieces {
                if let text = piece.text, piece.kind == nil, piece.value == nil {
                    segments.append(.text(text))
                } else if piece.text == nil, let rawKind = piece.kind, let kind = AgentTaskInputKind(rawValue: rawKind),
                          let value = piece.value,
                          let restored = TaskComposerReferenceParser.restored(kind: kind, value: value) {
                    let reference = TaskComposerReference(kind: restored.kind, value: restored.value,
                                                         userRole: piece.role)
                    segments.append(.reference(reference))
                } else { return nil }
            }
            let draft = TaskComposerDraft(segments: segments)
            let labels = draft.displayLabels()
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.labelColor
            ]
            let result = NSMutableAttributedString(string: "")
            for segment in draft.segments {
                switch segment {
                case .text(let text):
                    result.append(NSAttributedString(string: text, attributes: textAttributes))
                case .reference(let reference):
                    result.append(attributedAttachment(reference,
                        label: labels[reference.id] ?? reference.value, fontSize: fontSize))
                }
            }
            return result
        }

        private static func attributedAttachment(_ reference: TaskComposerReference,
                                                 label: String, fontSize: CGFloat) -> NSAttributedString {
            let attachment = TaskComposerTextAttachment(reference: reference, label: label, fontSize: fontSize)
            let result = NSMutableAttributedString(attachment: attachment)
            let range = NSRange(location: 0, length: result.length)
            result.addAttributes([.font: NSFont.systemFont(ofSize: fontSize),
                                  .foregroundColor: NSColor.labelColor], range: range)
            result.addAttribute(.baselineOffset, value: -3, range: range)
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

        private static func attachment(id: UUID, in attributed: NSAttributedString) -> TaskComposerTextAttachment? {
            guard attributed.length > 0 else { return nil }
            var found: TaskComposerTextAttachment?
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
                guard let attachment = value as? TaskComposerTextAttachment,
                      attachment.reference.id == id else { return }
                found = attachment
                stop.pointee = true
            }
            return found
        }

    }
}

private struct TaskComposerClipboard: Codable {
    struct Piece: Codable {
        var text: String? = nil
        var kind: String? = nil
        var value: String? = nil
        var role: AgentTaskInputRole? = nil
        init(text: String) { self.text = text }
        init(kind: String, value: String, role: AgentTaskInputRole?) {
            self.kind = kind
            self.value = value
            self.role = role
        }
    }
    let version: Int
    let pieces: [Piece]
}

final class TaskComposerTextAttachment: NSTextAttachment {
    private(set) var reference: TaskComposerReference
    private(set) var label: String
    private var chipCell: TaskComposerChipCell?
    private var fontSize: CGFloat

    var sizeMeasurementCount: Int { chipCell?.sizeMeasurementCount ?? 0 }

    init(reference: TaskComposerReference, label: String, fontSize: CGFloat = 12) {
        self.reference = reference
        self.label = label
        self.fontSize = fontSize
        super.init(data: nil, ofType: "com.taskpilot.exact-input-reference")
        let cell = TaskComposerChipCell(label: label, reference: reference, fontSize: fontSize)
        chipCell = cell
        attachmentCell = cell
    }

    required init?(coder: NSCoder) { return nil }

    func updateLabel(_ label: String) {
        guard self.label != label else { return }
        updateReference(reference, label: label)
    }

    func updateReference(_ reference: TaskComposerReference, label: String? = nil) {
        let nextLabel = label ?? self.label
        guard self.reference != reference || self.label != nextLabel else { return }
        self.reference = reference
        self.label = nextLabel
        if let chipCell {
            chipCell.update(reference: reference, label: nextLabel, fontSize: fontSize)
        } else {
            let cell = TaskComposerChipCell(label: nextLabel, reference: reference, fontSize: fontSize)
            chipCell = cell
            attachmentCell = cell
        }
    }

    @discardableResult
    func updateFontSize(_ fontSize: CGFloat) -> Bool {
        guard self.fontSize != fontSize else { return false }
        self.fontSize = fontSize
        chipCell?.update(reference: reference, label: label, fontSize: fontSize)
        return true
    }
}

final class TaskComposerChipCell: NSTextAttachmentCell {
    private var reference: TaskComposerReference
    private var labelText: String
    private var icon: NSImage
    private var fontSize: CGFloat
    private var cachedCellSize: NSSize?
    private(set) var sizeMeasurementCount = 0

    init(label: String, reference: TaskComposerReference, fontSize: CGFloat = 12) {
        self.reference = reference
        self.labelText = label
        self.fontSize = fontSize
        if reference.kind == .url || reference.kind == .text {
            let kind = reference.kind == .url ? "Web address" : "Exact text"
            self.icon = NSImage(systemSymbolName: "link", accessibilityDescription: kind) ?? NSImage()
        } else {
            self.icon = NSWorkspace.shared.icon(forFile: reference.value)
        }
        super.init(textCell: label)
        let kindLabel = reference.kind == .folder ? "Folder" : reference.kind == .file ? "File" : reference.kind == .url ? "Web address" : "Exact text"
        setAccessibilityLabel("\(kindLabel): \(label)")
    }

    func update(reference: TaskComposerReference, label: String, fontSize: CGFloat? = nil) {
        let identityChanged = self.reference.kind != reference.kind || self.reference.value != reference.value
        let nextFontSize = fontSize ?? self.fontSize
        let fontChanged = self.fontSize != nextFontSize
        if identityChanged {
            if reference.kind == .url || reference.kind == .text {
                let kind = reference.kind == .url ? "Web address" : "Exact text"
                icon = NSImage(systemSymbolName: "link", accessibilityDescription: kind) ?? NSImage()
            } else {
                icon = NSWorkspace.shared.icon(forFile: reference.value)
            }
        }
        self.reference = reference
        let labelChanged = labelText != label
        labelText = label
        self.fontSize = nextFontSize
        if labelChanged || fontChanged { cachedCellSize = nil }
        if identityChanged || labelChanged {
            let kindLabel = reference.kind == .folder ? "Folder" : reference.kind == .file ? "File" : reference.kind == .url ? "Web address" : "Exact text"
            setAccessibilityLabel("\(kindLabel): \(label)")
        }
    }

    required init(coder: NSCoder) { fatalError("Task composer chip cells are not archived") }

    override func cellSize() -> NSSize {
        if let cachedCellSize { return cachedCellSize }
        sizeMeasurementCount += 1
        let textWidth = (labelText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]).width
        let size = NSSize(width: min(310, max(72, textWidth + 34)), height: max(23, ceil(fontSize + 11)))
        cachedCellSize = size
        return size
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let bounds = cellFrame.insetBy(dx: 0.5, dy: 1.5)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let iconRect = NSRect(x: bounds.minX + 5, y: bounds.minY + 3, width: 15, height: 15)
        icon.draw(in: iconRect)
        let titleRect = NSRect(x: iconRect.maxX + 4, y: bounds.minY + 3,
                               width: max(0, bounds.maxX - iconRect.maxX - 8), height: max(15, fontSize + 2))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        labelText.draw(in: titleRect, withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                                                    .foregroundColor: NSColor.labelColor,
                                                    .paragraphStyle: style])
    }
}

final class TaskComposerTextView: NSTextView {
    weak var composerCoordinator: TaskRequestComposer.Coordinator?
    private let composerUndoManager = UndoManager()

    override var undoManager: UndoManager? { composerUndoManager }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            composerCoordinator?.textView(self, didChangeFirstResponder: true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            composerCoordinator?.textView(self, didChangeFirstResponder: false)
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        composerCoordinator?.textViewDidMoveToWindow(self)
    }

    override func mouseDown(with event: NSEvent) {
        let selectionModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]
        if event.clickCount == 1,
           event.modifierFlags.intersection(selectionModifiers).isEmpty,
           let (attachment, anchor) = attachment(at: event.locationInWindow) {
            window?.makeFirstResponder(self)
            composerCoordinator?.handleChip(attachment.reference, anchor: anchor, in: self)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let (reference, anchor) = chipInspectionTarget(for: event) {
            composerCoordinator?.handleChip(reference, anchor: anchor, in: self)
            return
        }
        super.keyDown(with: event)
    }

    func chipInspectionTarget(for event: NSEvent) -> (TaskComposerReference, NSRect)? {
        guard !hasMarkedText() else {
            return nil
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isReadOnlyInspectionKey = !isEditable && (isReturn || event.keyCode == 49)
        let isEditableInspectionKey = isEditable && isReturn && event.modifierFlags.contains(.option)
        guard isReadOnlyInspectionKey || isEditableInspectionKey,
              let attachment = adjacentAttachment(for: selectedRange()),
              let layoutManager, let textContainer else { return nil }
        let range = selectedRange()
        let glyphRange: NSRange
        if range.length == 1,
           attributedString().attribute(.attachment, at: range.location, effectiveRange: nil) is TaskComposerTextAttachment {
            glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        } else {
            glyphRange = NSRange(location: range.location, length: 0)
        }
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return (attachment.reference, rect)
    }

    override func copy(_ sender: Any?) { composerCoordinator?.copySelection(from: self, cut: false) }
    override func cut(_ sender: Any?) { composerCoordinator?.copySelection(from: self, cut: true) }
    override func paste(_ sender: Any?) { composerCoordinator?.paste(into: self) }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isEditable else { return }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        guard isEditable else { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        guard isEditable else { return }
        super.deleteForward(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard isEditable else { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        guard isEditable else { return }
        super.pasteAsRichText(sender)
    }

    @IBAction func pasteAndMatchStyle(_ sender: Any?) {
        guard isEditable else { return }
        paste(sender)
    }

    @IBAction func undo(_ sender: Any?) {
        guard isEditable else { return }
        undoManager?.undo()
    }

    @IBAction func redo(_ sender: Any?) {
        guard isEditable else { return }
        undoManager?.redo()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        !isEditable || Self.dragURLs(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        let urls = Self.dragURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        composerCoordinator?.insertDropped(urls, at: index, in: self)
        return true
    }

    func attachment(at windowPoint: NSPoint) -> (TaskComposerTextAttachment, NSRect)? {
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
        guard rect.contains(point) else { return nil }
        return (attachment, rect)
    }

    private func adjacentAttachment(for range: NSRange) -> TaskComposerTextAttachment? {
        let attributed = attributedString()
        if range.length > 0 {
            guard range.length == 1, range.location >= 0, range.location < attributed.length else { return nil }
            return attributed.attribute(.attachment, at: range.location, effectiveRange: nil) as? TaskComposerTextAttachment
        }
        let position = range.location
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
    let isReadOnly: Bool
    let canChangeRole: Bool
    let hasExistingCorrection: Bool
    let onReplace: (TaskComposerReference) -> Void
    let onRemove: () -> Void
    let onRoleCorrection: (AgentTaskInputRole?) -> Bool
    let onContinueCorrection: (() -> Void)?
    @State private var showQuickLook = false
    @State private var localDetails: String?
    @State private var previewUnavailable = false
    @State private var replacementValue = ""
    @State private var replacementError: String?
    @State private var selectedRole: AgentTaskInputRole?
    @State private var roleCorrectionError: String?

    init(reference: TaskComposerReference, isReadOnly: Bool, canChangeRole: Bool,
         hasExistingCorrection: Bool, onReplace: @escaping (TaskComposerReference) -> Void,
         onRemove: @escaping () -> Void, onRoleCorrection: @escaping (AgentTaskInputRole?) -> Bool,
         onContinueCorrection: (() -> Void)?) {
        self.reference = reference
        self.isReadOnly = isReadOnly
        self.canChangeRole = canChangeRole
        self.hasExistingCorrection = hasExistingCorrection
        self.onReplace = onReplace
        self.onRemove = onRemove
        self.onRoleCorrection = onRoleCorrection
        self.onContinueCorrection = onContinueCorrection
        _selectedRole = State(initialValue: reference.rolePickerSelection)
    }

    private var localURL: URL? {
        guard reference.kind == .file || reference.kind == .folder else { return nil }
        return URL(fileURLWithPath: reference.value)
    }

    private var fileURL: URL? { reference.kind == .file ? localURL : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
            Image(systemName: reference.kind == .url ? "link" : reference.kind == .folder ? "folder" : reference.kind == .text ? "text.quote" : "doc")
                    .foregroundStyle(.tint)
                Text(reference.kind == .url ? "Web address" : reference.kind == .folder ? "Folder reference" : reference.kind == .text ? "Exact text" : "File reference")
                    .font(.headline)
                Spacer()
                if !isReadOnly {
                    Button("Remove", role: .destructive, action: onRemove)
                        .keyboardShortcut(.delete, modifiers: [])
                }
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
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("Used as").font(.caption.weight(.semibold))
                HStack(spacing: 6) {
                    Text((reference.userRole ?? reference.presentedRole)?.title ?? "Not established yet")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 4)
                    Text(roleOriginLabel).font(.caption2).foregroundStyle(.secondary)
                }
                if reference.roleCorrectionPending {
                    Text("Role correction pending · requested: \(reference.pendingRole?.title ?? "Automatic")")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("Used as role", selection: $selectedRole) {
                    Text("Automatic").tag(Optional<AgentTaskInputRole>.none)
                    ForEach(AgentTaskInputRole.allCases) { role in
                        Text(role.title).tag(Optional(role))
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Used as role")
                .disabled(isReadOnly && (hasExistingCorrection || !canChangeRole || reference.roleCorrectionPending))
                if isReadOnly {
                    Text("Source is acted on; Destination is an intended output; Reference example guides style, structure, or content.")
                        .font(.caption).foregroundStyle(.secondary)
                    if hasExistingCorrection {
                        Button("Continue existing correction") { onContinueCorrection?() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Apply role correction") {
                            if !onRoleCorrection(selectedRole) {
                                roleCorrectionError = "The role could not be applied. Continue any open correction or try again."
                            } else {
                                roleCorrectionError = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canChangeRole || reference.roleCorrectionPending || selectedRole == reference.userRole)
                    }
                    if let roleCorrectionError {
                        Text(roleCorrectionError).font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("A source is acted on; a destination is an intended output; a reference example guides style or structure.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !isReadOnly {
            VStack(alignment: .leading, spacing: 6) {
                Text("Replace exact input")
                    .font(.caption.weight(.semibold))
                TextField("New exact value", text: $replacementValue, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityLabel("Replacement exact input")
                HStack {
                    if reference.kind == .file || reference.kind == .folder {
                        Button("Choose…", action: chooseLocalReference)
                    }
                    Spacer()
                    Button("Replace", action: applyReplacement)
                        .buttonStyle(.borderedProminent)
                        .disabled(replacementValue.isEmpty)
                }
                if let replacementError {
                    Text(replacementError).font(.caption).foregroundStyle(.red)
                }
            }
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
        .frame(width: 360, alignment: .leading)
        .task(id: reference.id) { await inspectLocalReference() }
        .onAppear {
            replacementValue = reference.value
        }
        .onChange(of: reference.pendingRole) { _, _ in
            synchronizeReadOnlyRolePicker()
        }
        .onChange(of: reference.userRole) { _, _ in
            synchronizeReadOnlyRolePicker()
        }
        .onChange(of: reference.roleCorrectionPending) { _, _ in
            synchronizeReadOnlyRolePicker()
        }
        .onChange(of: selectedRole) { _, role in
            guard !isReadOnly, role != reference.userRole else { return }
            _ = onRoleCorrection(role)
        }
    }

    private var rolePickerValue: AgentTaskInputRole? {
        reference.rolePickerSelection
    }

    private func synchronizeReadOnlyRolePicker() {
        guard isReadOnly else { return }
        selectedRole = rolePickerValue
    }

    private var roleOriginLabel: String {
        if reference.userRole != nil { return "Chosen by you" }
        switch reference.roleOrigin {
        case .chosen: return "Chosen by you"
        case .inferred: return "Inferred for this run"
        case .unresolved: return "Not established yet"
        }
    }

    private func chooseLocalReference() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = reference.kind == .file
        panel.canChooseDirectories = reference.kind == .folder
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            replacementValue = url.path
        }
    }

    private func applyReplacement() {
        guard !replacementValue.isEmpty else { return }
        if reference.kind == .url {
            guard let components = URLComponents(string: replacementValue),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  components.host != nil else {
                replacementError = "Enter a complete HTTP or HTTPS address."
                return
            }
        }
        if reference.kind == .file || reference.kind == .folder {
            guard replacementValue.hasPrefix("/") else {
                replacementError = "Enter an absolute local path."
                return
            }
        }
        onReplace(TaskComposerReference(id: reference.id, kind: reference.kind, value: replacementValue,
            userRole: reference.userRole, presentedRole: reference.presentedRole,
            roleOrigin: reference.roleOrigin, inferredRole: reference.inferredRole,
            occurrenceID: reference.occurrenceID))
    }

    @MainActor
    private func inspectLocalReference() async {
        guard let localURL else { return }
        let path = localURL.path
        let detail = await Task.detached(priority: .utility) { () -> (String?, Bool) in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return (nil, true) }
            guard FileManager.default.isReadableFile(atPath: path) else { return (nil, true) }
            let values = try? localURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
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
