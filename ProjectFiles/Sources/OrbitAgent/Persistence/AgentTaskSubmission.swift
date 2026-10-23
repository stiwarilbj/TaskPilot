import Foundation

enum AgentTaskInputKind: String, Codable, Equatable {
    case file
    case folder
    case url
}

/// An exact occurrence in the submitted UTF-8 request. Offsets are measured
/// against the request bytes so paths, Unicode and URL escapes remain intact.
struct AgentTaskInputReference: Codable, Equatable, Identifiable {
    let version: Int
    let kind: AgentTaskInputKind
    let utf8Start: Int
    let utf8Length: Int
    let value: String

    init(version: Int = 1, kind: AgentTaskInputKind, utf8Start: Int, utf8Length: Int, value: String) {
        self.version = version
        self.kind = kind
        self.utf8Start = utf8Start
        self.utf8Length = utf8Length
        self.value = value
    }

    var id: String { "\(utf8Start):\(utf8Length):\(kind.rawValue)" }

    var wireValue: [String: Any] {
        ["version": version, "kind": kind.rawValue, "utf8_start": utf8Start,
         "utf8_length": utf8Length, "value": value]
    }
}

/// Frozen task input shared by queueing, authorization, history and runtime
/// startup. The reference list describes occurrences, so repeated chips stay
/// distinct even when they contain the same value.
struct AgentTaskSubmission: Codable, Equatable {
    let request: String
    let exactInputReferences: [AgentTaskInputReference]

    init(request: String, exactInputReferences: [AgentTaskInputReference] = []) {
        self.request = request
        self.exactInputReferences = exactInputReferences
    }

    func trimmedForSubmission() -> AgentTaskSubmission {
        let bytes = Array(request.utf8)
        guard !bytes.isEmpty else { return self }
        let references = exactInputReferences.sorted { $0.utf8Start < $1.utf8Start }
        let firstProtectedByte = references.first?.utf8Start ?? bytes.count
        let lastProtectedByte = references.last.map { $0.utf8Start + $0.utf8Length } ?? 0
        let prefix = String(decoding: bytes[..<max(0, min(firstProtectedByte, bytes.count))], as: UTF8.self)
        let suffix = String(decoding: bytes[max(0, min(lastProtectedByte, bytes.count))...], as: UTF8.self)
        let leading = prefix.unicodeScalars.prefix {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }.reduce(0) { $0 + $1.utf8.count }
        let trailing = suffix.unicodeScalars.reversed().prefix {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }.reduce(0) { $0 + $1.utf8.count }
        let end = max(leading, bytes.count - trailing)
        let trimmed = String(decoding: bytes[leading..<end], as: UTF8.self)
        let adjusted = references.map {
            AgentTaskInputReference(version: $0.version, kind: $0.kind, utf8Start: $0.utf8Start - leading,
                                    utf8Length: $0.utf8Length, value: $0.value)
        }
        return AgentTaskSubmission(request: trimmed, exactInputReferences: adjusted)
    }
}
