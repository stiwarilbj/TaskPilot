import Foundation

enum AgentTaskInputKind: String, Codable, Equatable {
    case file
    case folder
    case url
    /// Exact literal data that is not a verified local file, folder, or URL.
    case text
}

enum AgentTaskInputReferenceProtocol {
    static let version = 2
}

/// An exact occurrence in the submitted UTF-8 request. Offsets are measured
/// against the request bytes so paths, Unicode and URL escapes remain intact.
struct AgentTaskInputReference: Codable, Equatable, Identifiable {
    let version: Int
    let kind: AgentTaskInputKind
    let utf8Start: Int
    let utf8Length: Int
    let value: String

    init(version: Int = AgentTaskInputReferenceProtocol.version,
         kind: AgentTaskInputKind, utf8Start: Int, utf8Length: Int, value: String) {
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

    func includingCorrections(_ corrections: [TaskInstructionCorrection]) -> AgentTaskSubmission {
        guard !corrections.isEmpty else { return self }
        var request = self.request
        var references = exactInputReferences
        for correction in corrections.sorted(by: { $0.revision < $1.revision }) {
            let header = "\n\nUser correction: "
            let start = request.utf8.count + header.utf8.count
            request += header + correction.request
            references.append(contentsOf: correction.exactInputReferences.map {
                AgentTaskInputReference(version: $0.version, kind: $0.kind,
                    utf8Start: start + $0.utf8Start, utf8Length: $0.utf8Length, value: $0.value)
            })
        }
        return AgentTaskSubmission(request: request, exactInputReferences: references)
    }

    func validateExactInputReferences() throws {
        guard exactInputReferences.count <= 128 else {
            throw AgentTaskSubmissionError.tooManyReferences
        }
        let bytes = Array(request.utf8)
        var previousEnd = 0
        for (index, reference) in exactInputReferences.enumerated() {
            guard reference.version == 1 || reference.version == 2 else {
                throw AgentTaskSubmissionError.invalidReference(index)
            }
            guard reference.version == 2 || reference.kind != .text,
                  reference.utf8Start >= previousEnd,
                  reference.utf8Length > 0,
                  reference.utf8Start <= bytes.count,
                  reference.utf8Length <= bytes.count - reference.utf8Start else {
                throw AgentTaskSubmissionError.invalidReference(index)
            }
            let end = reference.utf8Start + reference.utf8Length
            guard let value = String(bytes: bytes[reference.utf8Start..<end], encoding: .utf8),
                  value == reference.value, !value.isEmpty else {
                throw AgentTaskSubmissionError.invalidReference(index)
            }
            switch reference.kind {
            case .file, .folder:
                guard value.hasPrefix("/") else { throw AgentTaskSubmissionError.invalidReference(index) }
            case .url:
                guard let components = URLComponents(string: value),
                      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                      components.host != nil else { throw AgentTaskSubmissionError.invalidReference(index) }
            case .text:
                break
            }
            previousEnd = end
        }
    }
}

enum AgentTaskSubmissionError: LocalizedError {
    case tooManyReferences
    case invalidReference(Int)

    var errorDescription: String? {
        switch self {
        case .tooManyReferences:
            "This request contains more than 128 exact inputs. Remove a few and try again."
        case .invalidReference(let index):
            "Exact input \(index + 1) no longer matches its text. Review the request and try again."
        }
    }
}
