import CoreFoundation
import CryptoKit
import Foundation

struct AgentTaskContinuationResult: Equatable, Identifiable {
    let id: String
    let kind: String
    let name: String
    let location: String
}

struct AgentTaskContinuationCheckpoint {
    static let protocolVersion = 1
    static let maximumBytes = 262_144

    let generationID: String
    let revision: UInt64
    let instructionRevision: UInt64
    let taskSHA256: String
    let inputReferencesSHA256: String
    let isEligible: Bool
    let priorVerifiedRequirementCount: Int
    let unfinishedRequirementCount: Int
    let unresolvedReceiptCount: Int
    let results: [AgentTaskContinuationResult]
    let payload: [String: Any]

    var estimatedByteCount: Int {
        (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).count) ?? Self.maximumBytes
    }

    var explanation: String {
        let resultPhrase: String
        if results.isEmpty {
            resultPhrase = "Recheck the previous run’s verified results"
        } else {
            let names = results.prefix(2).map(\.name).joined(separator: ", ")
            let extra = results.count > 2 ? " and \(results.count - 2) more" : ""
            resultPhrase = "Recheck \(names)\(extra)"
        }
        guard unfinishedRequirementCount > 0 else {
            return "\(resultPhrase), then verify the complete request."
        }
        return "\(resultPhrase), then continue \(unfinishedRequirementCount == 1 ? "the unfinished requirement" : "\(unfinishedRequirementCount) unfinished requirements")."
    }

    var startupPayload: [String: Any] { payload }

    static func requestFingerprint(_ request: String) -> String {
        SHA256.hash(data: Data(request.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func inputReferencesFingerprint(_ references: [AgentTaskInputReference]) -> String {
        var data = Data()
        for reference in references.sorted(by: { $0.utf8Start < $1.utf8Start }) {
            for part in [reference.kind.rawValue, String(reference.utf8Start),
                         String(reference.utf8Length), reference.value] {
                let bytes = Data(part.utf8)
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
                data.append(bytes)
            }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ submission: AgentTaskSubmission) -> Bool {
        Self.requestFingerprint(submission.request) == taskSHA256 &&
            Self.inputReferencesFingerprint(submission.exactInputReferences) == inputReferencesSHA256
    }

    static func parse(_ message: [String: Any], generationID: String) -> Self? {
        let keys: Set<String> = [
            "kind", "task_generation_id", "version", "eligible", "task_sha256",
            "input_references_sha256", "source_task_generation_id", "expected_file_identities", "expected_web_destinations",
            "instruction_revision", "revision", "requirements", "observation_targets",
            "batch", "result_summaries", "unresolved_receipts"
        ]
        guard Set(message.keys) == keys,
              message["kind"] as? String == "task_continuation_checkpoint",
              message["task_generation_id"] as? String == generationID,
              let rawVersion = exactInteger(message["version"]), rawVersion == protocolVersion,
              let eligibleNumber = message["eligible"] as? NSNumber,
              CFGetTypeID(eligibleNumber) == CFBooleanGetTypeID(),
              let taskSHA256 = message["task_sha256"] as? String,
              taskSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let inputReferencesSHA256 = message["input_references_sha256"] as? String,
              inputReferencesSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let sourceGenerationID = message["source_task_generation_id"] as? String,
              sourceGenerationID == generationID,
              let rawInstructionRevision = exactInteger(message["instruction_revision"]),
              rawInstructionRevision >= 0,
              let rawRevision = exactInteger(message["revision"]), rawRevision > 0,
              let rawUnresolved = exactInteger(message["unresolved_receipts"]),
              (0...4096).contains(rawUnresolved),
              let requirements = message["requirements"] as? [[String: Any]], requirements.count <= 512,
              let targets = message["observation_targets"] as? [String: [String: Any]],
              let expectedFileIdentities = message["expected_file_identities"] as? [String: [String: String]],
              let expectedWebDestinations = message["expected_web_destinations"] as? [String: String],
              let summaries = message["result_summaries"] as? [[String: Any]], summaries.count <= 64 else {
            return nil
        }

        if eligibleNumber.boolValue && requirements.isEmpty { return nil }
        var identifiers = Set<String>()
        var priorVerified = 0
        var unfinished = 0
        for item in requirements {
            guard Set(item.keys).isSubset(of: [
                "id", "source", "description", "check", "depends_on", "scope", "previously_proven", "superseded_by"
            ]),
                  let id = item["id"] as? String,
                  id.range(of: #"^r[1-9][0-9]*$"#, options: .regularExpression) != nil,
                  identifiers.insert(id).inserted,
                  let source = safeText(item["source"], max: 8_192),
                  let description = safeText(item["description"], max: 8_192),
                  let check = item["check"] as? [String: Any],
                  validCheck(check),
                  let dependencies = item["depends_on"] as? [String],
                  dependencies.count <= 512,
                  Set(dependencies).count == dependencies.count,
                  dependencies.allSatisfy({ $0.range(of: #"^r[1-9][0-9]*$"#, options: .regularExpression) != nil }),
                  let previouslyProvenNumber = item["previously_proven"] as? NSNumber,
                  CFGetTypeID(previouslyProvenNumber) == CFBooleanGetTypeID() else {
                return nil
            }
            _ = source
            _ = description
            let previouslyProven = previouslyProvenNumber.boolValue
            let checkType = check["type"] as? String ?? ""
            if previouslyProven && !["file_exists", "directory_exists", "path_absent", "file_contents", "window_active"].contains(checkType) {
                return nil
            }
            if item["superseded_by"] == nil {
                if previouslyProven { priorVerified += 1 } else { unfinished += 1 }
            }
        }
        for item in requirements {
            guard let dependencies = item["depends_on"] as? [String],
                  dependencies.allSatisfy({ identifiers.contains($0) }) else { return nil }
        }
        for (requirementID, target) in targets {
            guard identifiers.contains(requirementID),
                  Set(target.keys).isSubset(of: ["pid", "name", "bundle_id"]),
                  let pid = exactInteger(target["pid"]), pid > 0,
                  target["name"] == nil || safeText(target["name"], max: 512) != nil,
                  target["bundle_id"] == nil || safeText(target["bundle_id"], max: 512) != nil else { return nil }
        }
        for (requirementID, identity) in expectedFileIdentities {
            guard identifiers.contains(requirementID), !identity.isEmpty,
                  Set(identity.keys).isSubset(of: ["file_identity", "file_version", "parent_identity"]),
                  identity.values.allSatisfy({ $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }) else {
                return nil
            }
        }
        for (requirementID, fingerprint) in expectedWebDestinations {
            guard identifiers.contains(requirementID),
                  requirements.contains(where: { item in
                      item["id"] as? String == requirementID &&
                          (item["previously_proven"] as? Bool == true) &&
                          ((item["check"] as? [String: Any])?["type"] as? String == "window_active")
                  }),
                  fingerprint.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { return nil }
        }
        for requirement in requirements {
            guard let id = requirement["id"] as? String,
                  let check = requirement["check"] as? [String: Any] else { return nil }
            if requirement["previously_proven"] as? Bool == true, check["type"] as? String == "window_active",
               targets[id] == nil { return nil }
            if expectedFileIdentities[id] != nil, !["file_exists", "directory_exists", "path_absent", "file_contents"].contains(check["type"] as? String ?? "") {
                return nil
            }
        }
        var results: [AgentTaskContinuationResult] = []
        for (index, item) in summaries.enumerated() {
            guard Set(item.keys).isSubset(of: ["kind", "name", "location"]),
                  let kind = item["kind"] as? String, ["file", "folder", "web"].contains(kind),
                  let name = safeText(item["name"], max: 512),
                  let location = safeText(item["location"], max: 512) else { return nil }
            results.append(.init(id: "result-\(index)", kind: kind, name: name, location: location))
        }
        if let batch = message["batch"], !(batch is NSNull) {
            guard JSONSerialization.isValidJSONObject(batch),
                  let data = try? JSONSerialization.data(withJSONObject: batch, options: [.sortedKeys]),
                  data.count <= 65_536 else { return nil }
        }
        guard JSONSerialization.isValidJSONObject(message),
              let encoded = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
              encoded.count <= maximumBytes else { return nil }
        let isEligible = eligibleNumber.boolValue && priorVerified > 0 && rawUnresolved == 0
        return Self(generationID: generationID, revision: UInt64(rawRevision),
                    instructionRevision: UInt64(rawInstructionRevision), taskSHA256: taskSHA256,
                    inputReferencesSHA256: inputReferencesSHA256,
                    isEligible: isEligible, priorVerifiedRequirementCount: priorVerified,
                    unfinishedRequirementCount: unfinished, unresolvedReceiptCount: rawUnresolved,
                    results: results, payload: message)
    }

    private static func validCheck(_ check: [String: Any]) -> Bool {
        guard let kind = check["type"] as? String else { return false }
        switch kind {
        case "file_exists", "directory_exists", "path_absent":
            return check["path"] as? String != nil
        case "file_contents":
            return check["path"] as? String != nil && check["content"] as? String != nil
        case "window_active":
            return exactInteger(check["pid"]).map { $0 > 0 } == true && check["title"] as? String != nil
        case "answer", "visual":
            return check["expected"] as? String != nil
        default:
            return false
        }
    }

    private static func safeText(_ value: Any?, max: Int) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= max,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            return nil
        }
        return text
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return Int(number.stringValue)
    }
}

struct AgentTaskContinuationCandidate {
    let historyEntryID: UUID
    let submission: AgentTaskSubmission
    let checkpoint: AgentTaskContinuationCheckpoint
}
