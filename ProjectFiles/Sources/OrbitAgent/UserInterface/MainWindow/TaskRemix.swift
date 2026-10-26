import Foundation
import SwiftUI

struct TaskRemixSession: Equatable, Identifiable {
    let id: UUID
    let sourceEntryID: UUID
    let sourceRequest: String
    let baselineDraft: TaskComposerDraft
    let preservedDraft: TaskComposerDraft

    init(sourceEntryID: UUID, sourceRequest: String,
         baselineDraft: TaskComposerDraft, preservedDraft: TaskComposerDraft) {
        id = UUID()
        self.sourceEntryID = sourceEntryID
        self.sourceRequest = sourceRequest
        self.baselineDraft = baselineDraft
        self.preservedDraft = preservedDraft
    }
}

struct TaskRemixInputChange: Equatable, Identifiable {
    enum Kind: Equatable { case replaced, added, removed, roleChanged }

    let id: UUID
    let kind: Kind
    let oldReference: TaskComposerReference?
    let newReference: TaskComposerReference?
}

struct TaskRemixReview: Equatable {
    let changes: [TaskRemixInputChange]
    let wordingChanged: Bool

    static func make(baseline: TaskComposerDraft, current: TaskComposerDraft) -> Self {
        let oldReferences = baseline.references
        let newReferences = current.references
        var usedOld = Set<Int>()
        var usedNew = Set<Int>()
        var changes: [TaskRemixInputChange] = []

        let newIndexByID = Dictionary(newReferences.enumerated().map { ($0.element.id, $0.offset) },
                                      uniquingKeysWith: { first, _ in first })
        for (oldIndex, old) in oldReferences.enumerated() {
            guard let newIndex = newIndexByID[old.id], !usedNew.contains(newIndex) else { continue }
            let new = newReferences[newIndex]
            usedOld.insert(oldIndex)
            usedNew.insert(newIndex)
            if old.kind != new.kind || old.value != new.value {
                changes.append(TaskRemixInputChange(id: old.id, kind: .replaced,
                                                    oldReference: old, newReference: new))
            } else if old.userRole != new.userRole {
                changes.append(TaskRemixInputChange(id: old.id, kind: .roleChanged,
                                                    oldReference: old, newReference: new))
            }
        }

        // Clipboard moves create new editor identities. First retain exact
        // resource and explicit-role matches as a multiset.
        struct ExactKey: Hashable {
            let kind: String
            let value: String
            let userRole: String?
        }
        var newIndicesByExactKey: [ExactKey: [Int]] = [:]
        for (index, reference) in newReferences.enumerated() where !usedNew.contains(index) {
            let key = ExactKey(kind: reference.kind.rawValue, value: reference.value,
                               userRole: reference.userRole?.rawValue)
            newIndicesByExactKey[key, default: []].append(index)
        }
        var exactKeyOffsets: [ExactKey: Int] = [:]
        for (oldIndex, old) in oldReferences.enumerated() where !usedOld.contains(oldIndex) {
            let key = ExactKey(kind: old.kind.rawValue, value: old.value,
                               userRole: old.userRole?.rawValue)
            guard let candidates = newIndicesByExactKey[key] else { continue }
            let offset = exactKeyOffsets[key, default: 0]
            guard offset < candidates.count else { continue }
            let newIndex = candidates[offset]
            exactKeyOffsets[key] = offset + 1
            usedOld.insert(oldIndex)
            usedNew.insert(newIndex)
        }

        // A changed role is attributable only when one unmatched occurrence
        // of that exact resource remains on each side. Duplicates stay as
        // additions/removals rather than receiving an invented pairing.
        struct ResourceKey: Hashable {
            let kind: String
            let value: String
        }
        var oldByResource: [ResourceKey: [Int]] = [:]
        var newByResource: [ResourceKey: [Int]] = [:]
        for (index, reference) in oldReferences.enumerated() where !usedOld.contains(index) {
            oldByResource[ResourceKey(kind: reference.kind.rawValue, value: reference.value), default: []].append(index)
        }
        for (index, reference) in newReferences.enumerated() where !usedNew.contains(index) {
            newByResource[ResourceKey(kind: reference.kind.rawValue, value: reference.value), default: []].append(index)
        }
        for (oldIndex, old) in oldReferences.enumerated() where !usedOld.contains(oldIndex) {
            let key = ResourceKey(kind: old.kind.rawValue, value: old.value)
            guard let oldIndices = oldByResource[key], oldIndices.count == 1,
                  let newIndices = newByResource[key], newIndices.count == 1,
                  let newIndex = newIndices.first else { continue }
            let new = newReferences[newIndex]
            usedOld.insert(oldIndex)
            usedNew.insert(newIndex)
            changes.append(TaskRemixInputChange(id: old.id, kind: .roleChanged,
                                                oldReference: old, newReference: new))
        }

        for (oldIndex, old) in oldReferences.enumerated() where !usedOld.contains(oldIndex) {
            changes.append(TaskRemixInputChange(id: old.id, kind: .removed,
                                                oldReference: old, newReference: nil))
        }
        for (newIndex, new) in newReferences.enumerated() where !usedNew.contains(newIndex) {
            changes.append(TaskRemixInputChange(id: new.id, kind: .added,
                                                oldReference: nil, newReference: new))
        }

        return TaskRemixReview(changes: changes,
                               wordingChanged: baseline.proseText != current.proseText)
    }
}

struct TaskRemixReviewCache {
    private struct Entry {
        let sessionID: UUID
        let draftRevision: UInt64
        let review: TaskRemixReview
    }

    private var entry: Entry?
    private(set) var buildCount = 0
    private(set) var cacheHitCount = 0

    mutating func review(sessionID: UUID, draftRevision: UInt64, baseline: TaskComposerDraft,
                         current: TaskComposerDraft) -> TaskRemixReview {
        if let entry, entry.sessionID == sessionID,
           entry.draftRevision == draftRevision {
            cacheHitCount += 1
            return entry.review
        }
        let review = TaskRemixReview.make(baseline: baseline, current: current)
        entry = Entry(sessionID: sessionID, draftRevision: draftRevision, review: review)
        buildCount += 1
        return review
    }

    mutating func clear() { entry = nil }
}

extension TaskComposerDraft {
    var references: [TaskComposerReference] {
        segments.compactMap { if case .reference(let reference) = $0 { reference } else { nil } }
    }

    var proseText: String {
        segments.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }

    init(remixing submission: AgentTaskSubmission) {
        let source = submission.request
        let bytes = Array(source.utf8)
        let explicit = submission.exactInputReferences.sorted { $0.utf8Start < $1.utf8Start }
        var spans: [(NSRange, TaskComposerReference)] = []
        var excluded: [NSRange] = []

        let explicitMetadataIsValid = (try? submission.validateExactInputReferences()) != nil
        for item in explicit where explicitMetadataIsValid {
            let end = item.utf8Start + item.utf8Length
            guard item.utf8Start >= 0, item.utf8Length > 0, end <= bytes.count,
                  let value = String(bytes: bytes[item.utf8Start..<end], encoding: .utf8),
                  value == item.value else { continue }
            let start16 = String(decoding: bytes[..<item.utf8Start], as: UTF8.self).utf16.count
            let end16 = String(decoding: bytes[..<end], as: UTF8.self).utf16.count
            let range = NSRange(location: start16, length: end16 - start16)
            spans.append((range, TaskComposerReference(kind: item.kind, value: item.value,
                                                       userRole: item.userRole)))
            excluded.append(range)
        }

        for (range, value) in TaskRemixLiteralScanner.references(in: source) {
            guard !excluded.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  let reference = TaskComposerReferenceParser.remixLiteral(value) else { continue }
            spans.append((range, reference))
        }

        let input = source as NSString
        spans.sort { $0.0.location < $1.0.location }
        var result: [TaskComposerSegment] = []
        var cursor = 0
        for (range, reference) in spans {
            guard range.location >= cursor, range.length > 0,
                  range.location + range.length <= input.length else { continue }
            if range.location > cursor {
                result.append(.text(input.substring(with: NSRange(location: cursor,
                    length: range.location - cursor))))
            }
            result.append(.reference(reference))
            cursor = range.location + range.length
        }
        if cursor < input.length {
            result.append(.text(input.substring(from: cursor)))
        }
        self.init(segments: result)
    }
}

struct TaskRemixReviewView: View {
    let review: TaskRemixReview
    let surface: Color
    let border: Color

    @State private var expandedChanges = Set<UUID>()
    @State private var showAllChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !review.changes.isEmpty {
                Label("Changed inputs · \(review.changes.count)", systemImage: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                Group {
                    if showAllChanges {
                        ScrollView {
                            changeRows(review.changes)
                        }
                        .frame(height: 150)
                    } else {
                        changeRows(Array(review.changes.prefix(2)))
                    }
                }
                if review.changes.count > 2 {
                    Button(showAllChanges ? "Show fewer inputs" : "Show all \(review.changes.count) inputs") {
                        showAllChanges.toggle()
                    }
                    .font(.caption)
                }
            }
            if review.wordingChanged {
                Label("Request wording also changed", systemImage: "text.alignleft")
                    .font(.caption)
            }
            if review.changes.isEmpty && !review.wordingChanged {
                Text("No input changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-remix-input-comparison")
    }

    private func changeRows(_ changes: [TaskRemixInputChange]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(changes) { change in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedChanges.contains(change.id) },
                    set: { isExpanded in
                        if isExpanded { expandedChanges.insert(change.id) }
                        else { expandedChanges.remove(change.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let old = change.oldReference {
                            exactValueRow(title: "Original", reference: old)
                        }
                        if let new = change.newReference {
                            exactValueRow(title: "New", reference: new)
                        }
                    }
                    .padding(.leading, 6)
                    .padding(.vertical, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text(change.kind.title)
                            .font(.caption.weight(.medium))
                        if let old = change.oldReference {
                            Text(old.value.previewText)
                                .lineLimit(1).truncationMode(.middle)
                            if change.kind == .replaced {
                                Image(systemName: "arrow.right")
                                Text(change.newReference?.value.previewText ?? "")
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        } else if let new = change.newReference {
                            Text(new.value.previewText).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("\(change.kind.title) input. Expand to inspect the full value.")
            }
        }
    }

    private func exactValueRow(title: String, reference: TaskComposerReference) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text("Used as: \(reference.userRole?.title ?? "Automatic")")
                .font(.caption2).foregroundStyle(.secondary)
            Text(reference.value)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension TaskRemixInputChange.Kind {
    var title: String {
        switch self {
        case .replaced: "Replaced"
        case .added: "Added"
        case .removed: "Removed"
        case .roleChanged: "Role changed"
        }
    }
}

private extension String {
    var previewText: String {
        let compact = split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(compact.prefix(72))
    }
}

private enum TaskRemixLiteralScanner {
    static func references(in source: String) -> [(NSRange, String)] {
        let input = source as NSString
        var spans: [(NSRange, String)] = []
        var covered: [NSRange] = []

        collectFencedText(input, spans: &spans, covered: &covered)
        collectQuotedText(input, spans: &spans, covered: &covered)
        collectMatches(#"(?<![\w/])(?:https?://|~/|/|\.\./|\./)[^\s"'`<>]+"#,
                       in: input, spans: &spans, covered: &covered, trimSentencePunctuation: false)
        collectMatches(#"(?<!\S)(?:\.?[\w-]+\.)+[\w-]+(?=\s|$|[.,;:!?])"#,
                       in: input, spans: &spans, covered: &covered, trimSentencePunctuation: false)

        return spans.sorted { $0.0.location < $1.0.location }
    }

    private static func collectFencedText(_ input: NSString,
                                          spans: inout [(NSRange, String)],
                                          covered: inout [NSRange]) {
        let pattern = #"(?m)^[ \t]*(`{3,}|~{3,})[^\r\n]*\r?\n([\s\S]*?)^[ \t]*\1[ \t]*(?:\r?\n|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        for match in expression.matches(in: input as String, range: NSRange(location: 0, length: input.length)) {
            guard match.numberOfRanges > 2 else { continue }
            let full = match.range(at: 0)
            let body = match.range(at: 2)
            covered.append(full)
            if body.length > 0 { spans.append((body, input.substring(with: body))) }
        }
    }

    private static func collectQuotedText(_ input: NSString,
                                          spans: inout [(NSRange, String)],
                                          covered: inout [NSRange]) {
        let pairs: [unichar: unichar] = [34: 34, 39: 39, 96: 96, 0x201C: 0x201D, 0x2018: 0x2019]
        let length = input.length
        var offset = 0
        while offset < length {
            let opening = input.character(at: offset)
            guard let closing = pairs[opening], !overlaps(offset, covered) else {
                offset += 1
                continue
            }
            if offset > 0 && isAlphanumeric(input.character(at: offset - 1)) {
                offset += 1
                continue
            }
            var delimiterLength = 1
            if opening == 96 {
                while offset + delimiterLength < length,
                      input.character(at: offset + delimiterLength) == opening {
                    delimiterLength += 1
                }
            }
            var cursor = offset + delimiterLength
            var closeStart: Int?
            while cursor < length {
                if input.character(at: cursor) == closing {
                    if opening != 96 ||
                        (cursor == 0 || input.character(at: cursor - 1) != 96) &&
                        (cursor + delimiterLength >= length || input.character(at: cursor + delimiterLength) != 96) {
                        var backslashes = 0
                        var preceding = cursor - 1
                        while preceding >= 0 && input.character(at: preceding) == 92 {
                            backslashes += 1
                            preceding -= 1
                        }
                        let after = cursor + delimiterLength
                        let apostropheEndsWord = opening != 39 || after == length ||
                            !isAlphanumeric(input.character(at: after))
                        if backslashes.isMultiple(of: 2) && apostropheEndsWord {
                            closeStart = cursor
                            break
                        }
                    }
                }
                cursor += 1
            }
            guard let closeStart else {
                covered.append(NSRange(location: offset, length: length - offset))
                break
            }
            let body = NSRange(location: offset + delimiterLength, length: closeStart - offset - delimiterLength)
            let fullLength = closeStart + delimiterLength - offset
            covered.append(NSRange(location: offset, length: fullLength))
            if body.length > 0 { spans.append((body, input.substring(with: body))) }
            offset = closeStart + delimiterLength
        }
    }

    private static func collectMatches(_ pattern: String, in input: NSString,
                                       spans: inout [(NSRange, String)],
                                       covered: inout [NSRange],
                                       trimSentencePunctuation: Bool) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        for match in expression.matches(in: input as String, range: NSRange(location: 0, length: input.length)) {
            var range = match.range
            guard range.length > 0, !overlaps(range.location, covered),
                  !spans.contains(where: { NSIntersectionRange($0.0, range).length > 0 }) else { continue }
            if NSMaxRange(range) < input.length,
               "\"'`“”‘’".unicodeScalars.contains(UnicodeScalar(input.character(at: NSMaxRange(range))) ?? " ") {
                continue
            }
            if trimSentencePunctuation {
                while range.length > 0, let last = input.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)).unicodeScalars.first,
                      ".,;:!?".unicodeScalars.contains(last) {
                    range.length -= 1
                }
            } else {
                let rawValue = input.substring(with: range)
                if !rawValue.hasPrefix("http://") && !rawValue.hasPrefix("https://") {
                    while range.length > 0,
                          input.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "," {
                        range.length -= 1
                    }
                }
                if range.length > 0,
                   let last = input.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)).unicodeScalars.first,
                   ".,;:!?".unicodeScalars.contains(last) {
                    continue
                }
            }
            guard range.length > 0 else { continue }
            spans.append((range, input.substring(with: range)))
            covered.append(range)
        }
    }

    private static func overlaps(_ location: Int, _ ranges: [NSRange]) -> Bool {
        ranges.contains { location >= $0.location && location < NSMaxRange($0) }
    }

    private static func isAlphanumeric(_ value: unichar) -> Bool {
        guard let scalar = UnicodeScalar(value) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
