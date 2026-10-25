import CoreFoundation
import Foundation

enum AgentTargetChoiceProtocol {
    static let version = 1
}

enum AgentTargetChoiceKind: String, Equatable {
    case file
    case folder
    case document

    var symbol: String {
        switch self {
        case .file: "doc"
        case .folder: "folder"
        case .document: "rectangle.on.rectangle"
        }
    }
}

struct AgentTargetChoiceCandidate: Equatable, Identifiable {
    let id: String
    let kind: AgentTargetChoiceKind
    let label: String
    let detail: String
}

struct AgentTargetChoiceRequest: Equatable, Identifiable {
    enum State: Equatable { case pending, applying, applied }

    let id: String
    let taskGenerationID: String
    let instructionRevision: UInt64
    let workingDocumentRevision: UInt64
    let bindingRevision: UInt64
    let reference: String
    let requirementID: String
    let scope: String
    let candidates: [AgentTargetChoiceCandidate]
    let inspectAgainAllowed: Bool
    var state: State = .pending
    var appliedLabel: String?
    var appliedDetail: String?
    var notice: String?

    static func parse(_ message: [String: Any], generationID: String,
                      instructionRevision expectedInstruction: UInt64,
                      workingDocumentRevision expectedDocument: UInt64,
                      targetBindingRevision currentBinding: UInt64) -> Self? {
        let keys: Set<String> = ["kind", "task_generation_id", "instruction_revision", "working_document_revision",
                                 "version", "request_id", "binding_revision", "reference", "requirement_id",
                                 "scope", "candidates", "inspect_again_allowed"]
        guard Set(message.keys) == keys,
              message["kind"] as? String == "target_choice_required",
              message["task_generation_id"] as? String == generationID,
              exactInteger(message["version"]) == UInt64(AgentTargetChoiceProtocol.version),
              let instruction = exactInteger(message["instruction_revision"]), instruction == expectedInstruction,
              let document = exactInteger(message["working_document_revision"]), document == expectedDocument,
              let binding = exactInteger(message["binding_revision"]), binding == currentBinding + 1,
              let requestID = canonicalUUID(message["request_id"]),
              let reference = safeText(message["reference"], maximumBytes: 240),
              let requirementID = message["requirement_id"] as? String,
              requirementID.range(of: #"^r[1-9][0-9]{0,3}$"#, options: .regularExpression) != nil,
              let scope = message["scope"] as? String,
              ["source", "destination", "document"].contains(scope),
              let rawCandidates = message["candidates"] as? [[String: Any]],
              (2...8).contains(rawCandidates.count),
              let inspectAgainNumber = message["inspect_again_allowed"] as? NSNumber,
              CFGetTypeID(inspectAgainNumber) == CFBooleanGetTypeID() else {
            return nil
        }
        let inspectAgain = inspectAgainNumber.boolValue
        var candidates: [AgentTargetChoiceCandidate] = []
        for row in rawCandidates {
            guard Set(row.keys) == Set(["id", "kind", "label", "detail"]),
                  let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 96,
                  let kindRaw = row["kind"] as? String, let kind = AgentTargetChoiceKind(rawValue: kindRaw),
                  let label = safeText(row["label"], maximumBytes: 160),
                  let detail = safeText(row["detail"], maximumBytes: 480) else { return nil }
            if scope == "document" && kind != .document { return nil }
            if scope != "document" && kind == .document { return nil }
            if kind == .document && canonicalUUID(id) == nil { return nil }
            if kind != .document && id.range(of: #"^input_[0-9a-f]{16}_[1-9][0-9]*$"#, options: .regularExpression) == nil { return nil }
            candidates.append(.init(id: id, kind: kind, label: label, detail: detail))
        }
        guard Set(candidates.map(\.id)).count == candidates.count else { return nil }
        let visible = candidates.map {
            "\($0.kind.rawValue)|\($0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))|\($0.detail.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
        }
        guard Set(visible).count == visible.count else { return nil }
        return Self(id: requestID, taskGenerationID: generationID, instructionRevision: instruction,
                    workingDocumentRevision: document, bindingRevision: binding, reference: reference,
                    requirementID: requirementID, scope: scope, candidates: candidates,
                    inspectAgainAllowed: inspectAgain)
    }

    private static func exactInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return UInt64(number.stringValue)
    }

    private static func canonicalUUID(_ value: Any?) -> String? {
        guard let text = value as? String, let uuid = UUID(uuidString: text),
              uuid.uuidString.lowercased() == text else { return nil }
        return text
    }

    private static func safeText(_ value: Any?, maximumBytes: Int) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximumBytes,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
}
