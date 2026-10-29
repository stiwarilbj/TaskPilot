import CryptoKit
import Darwin
import Foundation

/// A verified, in-memory text comparison for one native file-write lineage.
/// Snapshot contents never enter task history, model context, or diagnostics.
struct AgentTaskChangeLensSnapshot: Equatable, Identifiable {
    let generationID: String
    let instructionRevision: UInt64
    let actionID: String
    let path: String
    let fileIdentity: String
    let fileVersion: String
    let parentIdentity: String
    let beforeVersion: String?
    let beforeText: String?
    let afterText: String
    let requirementIDs: [String]
    let created: Bool
    let chainReset: Bool

    var id: String { AgentTaskResultObject.resultID(kind: .file, target: path) }
    var estimatedByteCount: Int {
        (beforeText?.utf8.count ?? 0) + afterText.utf8.count + path.utf8.count +
            generationID.utf8.count + actionID.utf8.count + fileIdentity.utf8.count +
            fileVersion.utf8.count + parentIdentity.utf8.count +
            (beforeVersion?.utf8.count ?? 0) + requirementIDs.reduce(0) { $0 + $1.utf8.count } + 256
    }

    func currentDestinationMatches() -> Bool {
        let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard let resolved = realpath(parentPath, nil) else { return false }
        defer { free(resolved) }
        let resolvedPath = String(cString: resolved)
        let parentFD = open(resolvedPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { return false }
        defer { close(parentFD) }
        var parent = stat()
        guard fstat(parentFD, &parent) == 0, Self.identity(parent).object == parentIdentity else { return false }
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        var firstTarget = stat()
        guard leaf.withCString({ fstatat(parentFD, $0, &firstTarget, AT_SYMLINK_NOFOLLOW) }) == 0,
              firstTarget.st_mode & S_IFMT == S_IFREG,
              Self.identity(firstTarget).object == fileIdentity,
              Self.identity(firstTarget).version == fileVersion else { return false }
        var secondTarget = stat()
        guard leaf.withCString({ fstatat(parentFD, $0, &secondTarget, AT_SYMLINK_NOFOLLOW) }) == 0,
              Self.identity(secondTarget).object == fileIdentity,
              Self.identity(secondTarget).version == fileVersion,
              Self.identity(secondTarget).version == Self.identity(firstTarget).version,
              let currentParent = realpath(parentPath, nil) else { return false }
        defer { free(currentParent) }
        return String(cString: currentParent) == resolvedPath
    }

    /// Confirms that a correction passage still has one exact, line-bounded
    /// location in the captured verified version, using its adjacent anchors
    /// when available. The new task still performs a fresh native read before
    /// it edits anything.
    func uniquelyIdentifies(passage: String, beforeAnchor: String, afterAnchor: String) -> Bool {
        guard !passage.isEmpty, !passage.contains("\0") else { return false }
        let source = afterText.components(separatedBy: "\n")
        let selected = passage.components(separatedBy: "\n")
        guard !selected.isEmpty else { return false }
        var matches = 0
        if selected.count <= source.count {
            for start in 0...(source.count - selected.count) {
                guard Array(source[start..<(start + selected.count)]) == selected else { continue }
                if !beforeAnchor.isEmpty {
                    guard start > 0, source[start - 1] == beforeAnchor else { continue }
                }
                let afterIndex = start + selected.count
                if !afterAnchor.isEmpty {
                    guard afterIndex < source.count, source[afterIndex] == afterAnchor else { continue }
                }
                matches += 1
                if matches > 1 { return false }
            }
        }
        return matches == 1
    }

    static let maximumVersionBytes = 128 * 1024
    static let memoryBudgetBytes = 4 * 1024 * 1024
    static let maximumSnapshotCount = 128

    static func validatedCandidate(_ candidate: [String: Any],
                                   response: [String: Any],
                                   request: [String: Any],
                                   generationID: String,
                                   instructionRevision: UInt64,
                                   knownActionIDs: Set<String>) -> Self? {
        guard Set(candidate.keys) == ["action_id", "path", "file_identity", "file_version", "parent_identity",
                                      "before_version", "before_sha256", "before_data", "after_data",
                                      "requirement_ids", "created"],
              let actionID = candidate["action_id"] as? String,
              let uuid = UUID(uuidString: actionID), uuid.uuidString.lowercased() == actionID,
              knownActionIDs.contains(actionID),
              let requestID = request["request_id"] as? String, !requestID.isEmpty,
              let requestRevision = request["instruction_revision"] as? Int,
              requestRevision >= 0, UInt64(requestRevision) == instructionRevision,
              response["kind"] as? String == "bridge_response",
              response["task_generation_id"] as? String == generationID,
              response["request_id"] as? String == requestID,
              let responseRevision = response["instruction_revision"] as? Int,
              responseRevision >= 0, UInt64(responseRevision) == instructionRevision,
              let responseResult = response["result"] as? [String: Any],
              response["ok"] as? Bool == true,
              let receipt = response["action_receipt"] as? [String: Any],
              receipt["action_id"] as? String == actionID,
              receipt["state"] as? String == "confirmed",
              receipt["terminal"] as? Bool == true,
              responseResult["action_type"] as? String == "write_file",
              responseResult["outcome"] as? String == "verified",
              responseResult["verified"] as? Bool == true,
              responseResult["verification_scope"] as? String == "file_write",
              let actionParams = request["params"] as? [String: Any],
              let action = actionParams["action"] as? [String: Any],
              action["type"] as? String == "write_file",
              let actionIDFromRequest = actionParams["action_id"] as? String,
              actionIDFromRequest == actionID,
              let path = candidate["path"] as? String, path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.contains("\0"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              action["path"] as? String == path,
              responseResult["path"] as? String == path,
              let identity = candidate["file_identity"] as? String, validDigest(identity),
              let version = candidate["file_version"] as? String, validDigest(version),
              let parent = candidate["parent_identity"] as? String, validDigest(parent),
              responseResult["file_identity"] as? String == identity,
              responseResult["file_version"] as? String == version,
              responseResult["parent_identity"] as? String == parent,
              let fileHash = responseResult["file_sha256"] as? String, validDigest(fileHash),
              let afterData = candidate["after_data"] as? Data,
              afterData.count <= maximumVersionBytes,
              sha256(afterData) == fileHash,
              let after = validText(afterData),
              let requirementIDs = candidate["requirement_ids"] as? [String],
              requirementIDs.count <= 32, Set(requirementIDs).count == requirementIDs.count,
              requirementIDs.allSatisfy({ $0.range(of: #"^r[1-9][0-9]{0,3}$"#, options: .regularExpression) != nil }),
              requirementIDs == actionParams["target_requirement_ids"] as? [String],
              let created = candidate["created"] as? Bool else { return nil }

        let beforeData = candidate["before_data"] as? Data
        let beforeVersion = candidate["before_version"] as? String
        let beforeHash = candidate["before_sha256"] as? String
        let before: String?
        if created {
            guard beforeData == nil, beforeVersion == nil, beforeHash == nil else { return nil }
            before = nil
        } else {
            guard let beforeData, beforeData.count <= maximumVersionBytes,
                  let beforeVersion, validDigest(beforeVersion),
                  let beforeHash, validDigest(beforeHash), sha256(beforeData) == beforeHash,
                  let decoded = validText(beforeData) else { return nil }
            before = decoded
        }
        return Self(generationID: generationID, instructionRevision: instructionRevision,
                    actionID: actionID, path: path, fileIdentity: identity, fileVersion: version,
                    parentIdentity: parent, beforeVersion: beforeVersion, beforeText: before,
                    afterText: after, requirementIDs: requirementIDs, created: created, chainReset: false)
    }

    func extendingLineage(with newer: Self) -> Self {
        guard generationID == newer.generationID, path == newer.path,
              parentIdentity == newer.parentIdentity, fileVersion == newer.beforeVersion,
              !newer.created else {
            return Self(generationID: newer.generationID, instructionRevision: newer.instructionRevision,
                        actionID: newer.actionID, path: newer.path, fileIdentity: newer.fileIdentity,
                        fileVersion: newer.fileVersion, parentIdentity: newer.parentIdentity,
                        beforeVersion: newer.beforeVersion, beforeText: newer.beforeText,
                        afterText: newer.afterText, requirementIDs: newer.requirementIDs,
                        created: newer.created, chainReset: true)
        }
        return Self(generationID: newer.generationID, instructionRevision: newer.instructionRevision,
                    actionID: newer.actionID, path: newer.path, fileIdentity: newer.fileIdentity,
                    fileVersion: newer.fileVersion, parentIdentity: newer.parentIdentity,
                    beforeVersion: beforeVersion, beforeText: beforeText, afterText: newer.afterText,
                    requirementIDs: Array(Set(requirementIDs + newer.requirementIDs)).sorted(),
                    created: created, chainReset: chainReset)
    }

    private static func validText(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text
    }

    private static func identity(_ info: stat) -> (object: String, version: String) {
        let birth = info.st_birthtimespec
        let object = sha256(Data("\(info.st_dev):\(info.st_ino):\(birth.tv_sec):\(birth.tv_nsec)".utf8))
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        let version = sha256(Data("\(object):\(info.st_size):\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec):\(info.st_mode)".utf8))
        return (object, version)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct AgentTaskChangeLensLine: Equatable, Identifiable {
    let number: Int
    let text: String
    let changed: Bool
    var id: String { "\(number):\(changed ? 1 : 0):\(text)" }
}

struct AgentTaskChangeLensHunk: Equatable, Identifiable {
    let before: [AgentTaskChangeLensLine]
    let after: [AgentTaskChangeLensLine]
    let affectedBaselineLines: Range<Int>
    var id: String { "\(before.first?.number ?? 0):\(after.first?.number ?? 0)" }
}

enum AgentTaskChangeLensDiff {
    enum Result: Equatable {
        case hunks([AgentTaskChangeLensHunk])
        case unavailable(String)
    }

    static func build(before: String?, after: String) -> Result {
        guard let before else {
            let newLines = lines(after)
            guard newLines.count <= 1_000 else {
                return .unavailable("This text has too many lines for a bounded comparison.")
            }
            let rows = newLines.enumerated().map { AgentTaskChangeLensLine(number: $0.offset + 1, text: $0.element, changed: true) }
            return .hunks([AgentTaskChangeLensHunk(before: [], after: rows, affectedBaselineLines: 1..<1)])
        }
        let old = lines(before), new = lines(after)
        guard old.count <= 1_000, new.count <= 1_000 else {
            return .unavailable("This text has too many lines for a bounded comparison.")
        }
        if Task.isCancelled { return .unavailable("Comparison cancelled.") }
        if old == new { return .hunks([]) }

        // Traceback always consumes equal leading lines before consulting the
        // matrix, so those rows and columns cannot affect later choices.
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > prefix, newEnd > prefix, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1; newEnd -= 1
        }
        if oldEnd < old.count {
            // A suffix disjoint from both middles adds the same LCS length
            // to every middle choice. Otherwise retain it in the matrix:
            // repeated lines can change the established removal-first ties.
            let suffix = Set(old[oldEnd...])
            if old[prefix..<oldEnd].contains(where: suffix.contains) ||
                new[prefix..<newEnd].contains(where: suffix.contains) {
                oldEnd = old.count; newEnd = new.count
            }
        }
        let columns = newEnd - prefix + 1
        var common = [UInt16](repeating: 0, count: (oldEnd - prefix + 1) * columns)
        if oldEnd > prefix && newEnd > prefix {
            for oldIndex in (prefix..<oldEnd).reversed() {
                if Task.isCancelled { return .unavailable("Comparison cancelled.") }
                for newIndex in (prefix..<newEnd).reversed() {
                    let cell = (oldIndex - prefix) * columns + newIndex - prefix
                    if old[oldIndex] == new[newIndex] {
                        common[cell] = common[cell + columns + 1] &+ 1
                    } else {
                        common[cell] = max(common[cell + columns], common[cell + 1])
                    }
                }
            }
        }

        enum Operation { case same(Int, Int); case remove(Int); case insert(Int, Int) }
        var operations: [Operation] = (0..<prefix).map { .same($0, $0) }
        var i = prefix, j = prefix
        while i < oldEnd || j < newEnd {
            if i < oldEnd, j < newEnd, old[i] == new[j] {
                operations.append(.same(i, j)); i += 1; j += 1; continue
            }
            let cell = (i - prefix) * columns + j - prefix
            if i < oldEnd, (j == newEnd || common[cell + columns] >= common[cell + 1]) {
                operations.append(.remove(i)); i += 1
            } else if j < newEnd {
                operations.append(.insert(i, j)); j += 1
            }
        }
        for offset in 0..<(old.count - oldEnd) {
            operations.append(.same(oldEnd + offset, newEnd + offset))
        }
        let changedIndices = operations.indices.filter {
            switch operations[$0] { case .same: false; case .remove, .insert: true }
        }
        guard !changedIndices.isEmpty else { return .hunks([]) }
        var groups: [[Int]] = []
        for index in changedIndices {
            // Keep each contiguous edited passage separate. Nearby edits may
            // share context visually, but must not become one unmatchable
            // correction target.
            if let last = groups.last, let previous = last.last, index - previous <= 1 {
                groups[groups.count - 1].append(index)
            } else { groups.append([index]) }
        }
        let hunks = groups.map { group -> AgentTaskChangeLensHunk in
            let low = max(0, (group.first ?? 0) - 3)
            let high = min(operations.count, (group.last ?? 0) + 4)
            let selected = operations[low..<high]
            var beforeRows: [AgentTaskChangeLensLine] = []
            var afterRows: [AgentTaskChangeLensLine] = []
            var affected: [Int] = []
            for operation in selected {
                switch operation {
                case .same(let oldIndex, let newIndex):
                    beforeRows.append(AgentTaskChangeLensLine(number: oldIndex + 1, text: old[oldIndex], changed: false))
                    afterRows.append(AgentTaskChangeLensLine(number: newIndex + 1, text: new[newIndex], changed: false))
                case .remove(let oldIndex):
                    affected.append(oldIndex + 1)
                    beforeRows.append(AgentTaskChangeLensLine(number: oldIndex + 1, text: old[oldIndex], changed: true))
                case .insert(let oldOffset, let newIndex):
                    // Replacements inherit the removed line's scope. A pure
                    // insertion is checked against both adjacent baseline
                    // lines, conservatively flagging insertions at a scope
                    // boundary for review.
                    if let replacedLine = affected.last {
                        affected.append(replacedLine)
                    } else {
                        if oldOffset > 0 { affected.append(oldOffset) }
                        if oldOffset < old.count { affected.append(oldOffset + 1) }
                        if oldOffset == 0 && old.isEmpty { affected.append(1) }
                    }
                    afterRows.append(AgentTaskChangeLensLine(number: newIndex + 1, text: new[newIndex], changed: true))
                }
            }
            let first = affected.min() ?? 1
            let last = affected.max() ?? first
            return AgentTaskChangeLensHunk(before: beforeRows, after: afterRows,
                                           affectedBaselineLines: first..<(last + 1))
        }
        return .hunks(hunks)
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

}

enum AgentTaskChangeLensScope {
    enum Assessment: Equatable {
        case unrestricted
        case checked
        case potentialMismatch
        case imprecise
    }

    static func assess(request: String, before: String?, hunks: [AgentTaskChangeLensHunk]) -> Assessment {
        guard let before else { return .imprecise }
        guard let region = restrictedRegion(in: request, baseline: before) else {
            let hasRestriction = request.range(of: #"(?i)\b(?:only|except|without changing|leave .* unchanged)\b"#, options: .regularExpression) != nil
            return hasRestriction ? .imprecise : .unrestricted
        }
        return hunks.contains { hunk in
            !hunk.affectedBaselineLines.isEmpty && !hunk.affectedBaselineLines.allSatisfy(region.contains)
        } ? .potentialMismatch : .checked
    }

    static func hunkIsOutside(request: String, before: String,
                              hunk: AgentTaskChangeLensHunk) -> Bool? {
        guard let region = restrictedRegion(in: request, baseline: before) else { return nil }
        guard !hunk.affectedBaselineLines.isEmpty else { return false }
        return !hunk.affectedBaselineLines.allSatisfy(region.contains)
    }

    private static func restrictedRegion(in request: String, baseline: String) -> Range<Int>? {
        if let regex = try? NSRegularExpression(pattern: #"(?i)\bonly\s+(?:change|edit|rewrite|revise|update|modify)\s+[\"“]([^\"”]{1,160})[\"”]"#),
           let match = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
           let range = Range(match.range(at: 1), in: request) {
            let passage = String(request[range])
            guard let found = baseline.range(of: passage), baseline.range(of: passage, range: found.upperBound..<baseline.endIndex) == nil else { return nil }
            let line = baseline[..<found.lowerBound].filter { $0 == "\n" }.count + 1
            let endLine = baseline[..<found.upperBound].filter { $0 == "\n" }.count + 1
            return line..<(max(line, endLine) + 1)
        }
        let patterns = [
            #"(?i)\b(?:change|edit|rewrite|revise|update|modify)\s+only\s+(?:the\s+)?([a-z][a-z0-9 -]{1,60})"#,
            #"(?i)\bonly\s+(?:change|edit|rewrite|revise|update|modify)\s+(?:the\s+)?([a-z][a-z0-9 -]{1,60})"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
                  match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: request) else { continue }
            let rawHeading = String(request[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'“”`"))
            guard !rawHeading.isEmpty else { return nil }
            let baselineLines = baseline.components(separatedBy: "\n")
            let exact = baselineLines.indices.filter { baselineLines[$0].trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(rawHeading) == .orderedSame }
            guard exact.count == 1, let headingIndex = exact.first else { return nil }
            let headingLine = baselineLines[headingIndex]
            let level = headingLine.prefix(while: { $0 == "#" }).count
            var end = baselineLines.count
            if level > 0 {
                for next in (headingIndex + 1)..<baselineLines.count {
                    let line = baselineLines[next].trimmingCharacters(in: .whitespacesAndNewlines)
                    let nextLevel = line.prefix(while: { $0 == "#" }).count
                    if nextLevel > 0 && nextLevel <= level { end = next; break }
                }
            }
            let startLine = headingIndex + (level > 0 ? 1 : 0)
            return (startLine + 1)..<(end + 1)
        }
        return nil
    }
}

enum AgentTaskChangeCorrectionOutcome: Equatable {
    case applied
    case started
    case queued
    case existingCorrectionDraft
    case unavailable(String)
}
