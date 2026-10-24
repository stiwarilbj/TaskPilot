import CoreFoundation
import Foundation

enum AgentTaskProgressLifecycle: String, Equatable {
    case running
    case waitingForUser = "waiting_for_user"
    case paused
    case stopping
    case completed
    case failed
    case stopped
}

enum AgentTaskProgressRequirementState: String, Equatable {
    case pending
    case proven
    case invalidated
}

struct AgentTaskProgressEvidence: Equatable {
    let label: String
    let detail: String
    let revealPath: String?
}

struct AgentTaskProgressRequirement: Equatable, Identifiable {
    let id: String
    let sourceRanges: [Range<Int>]
    let state: AgentTaskProgressRequirementState
    let active: Bool
    let evidence: [AgentTaskProgressEvidence]
}

struct AgentTaskProgressSnapshot: Equatable {
    let generationID: String
    let revision: UInt64
    let lifecycle: AgentTaskProgressLifecycle
    let wholeRequestCoverage: String
    let activeRequirementIDs: [String]
    let requirements: [AgentTaskProgressRequirement]
    let resultObjects: [AgentTaskResultObject]

    var estimatedByteCount: Int {
        let textBytes = requirements.reduce(0) { total, requirement in
            total + requirement.id.utf8.count + requirement.sourceRanges.count * 40 + 64 +
                requirement.evidence.reduce(0) {
                    $0 + $1.label.utf8.count + $1.detail.utf8.count + ($1.revealPath?.utf8.count ?? 0) + 48
                }
        } + activeRequirementIDs.reduce(0) { $0 + $1.utf8.count + 4 }
            + resultObjects.reduce(0) { $0 + $1.estimatedByteCount }
        // JSON escaping can expand control characters to six bytes each.
        return 1_024 + textBytes * 6
    }

    static func parse(_ message: [String: Any], generationID: String) -> Self? {
        let requiredKeys: Set<String> = ["kind", "task_generation_id", "revision", "version", "lifecycle",
                                         "whole_request_coverage", "active_requirement_ids", "requirements",
                                         "result_objects"]
        guard Set(message.keys) == requiredKeys,
              message["kind"] as? String == "task_progress",
              message["task_generation_id"] as? String == generationID,
              let revisionNumber = message["revision"] as? NSNumber,
              CFGetTypeID(revisionNumber) != CFBooleanGetTypeID(),
              let revision = UInt64(revisionNumber.stringValue), revision > 0,
              let version = message["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 2, version.doubleValue == 2,
              let lifecycleRaw = message["lifecycle"] as? String,
              let lifecycle = AgentTaskProgressLifecycle(rawValue: lifecycleRaw),
              lifecycle != .paused, lifecycle != .stopping,
              let coverage = message["whole_request_coverage"] as? String,
              ["pending", "audited"].contains(coverage),
              let activeValues = message["active_requirement_ids"] as? [String], activeValues.count <= 512,
              Set(activeValues).count == activeValues.count,
              activeValues.allSatisfy(isRequirementID),
              let rawRequirements = message["requirements"] as? [[String: Any]], rawRequirements.count <= 512,
              let resultObjects = AgentTaskResultObject.parseList(message["result_objects"]) else {
            return nil
        }

        var requirements: [AgentTaskProgressRequirement] = []
        var identifiers = Set<String>()
        var sourceRangeCount = 0
        var evidenceBytes = 0
        for raw in rawRequirements {
            guard Set(raw.keys) == ["id", "source_ranges", "state", "active", "evidence"],
                  let id = raw["id"] as? String, isRequirementID(id), identifiers.insert(id).inserted,
                  let rawState = raw["state"] as? String,
                  let state = AgentTaskProgressRequirementState(rawValue: rawState),
                  let activeNumber = raw["active"] as? NSNumber,
                  CFGetTypeID(activeNumber) == CFBooleanGetTypeID(),
                  let rawRanges = raw["source_ranges"] as? [[Any]], rawRanges.count <= 256,
                  let rawEvidence = raw["evidence"] as? [[String: Any]], rawEvidence.count <= 2 else {
                return nil
            }
            var sourceRanges: [Range<Int>] = []
            var lastStart = -1
            for pair in rawRanges {
                guard pair.count == 2,
                      let start = exactInteger(pair[0]), let end = exactInteger(pair[1]),
                      start >= 0, start >= lastStart, end > start, end <= 16 * 1024 * 1024 else { return nil }
                sourceRanges.append(start..<end)
                lastStart = start
            }
            sourceRangeCount += sourceRanges.count
            guard sourceRangeCount <= 4096 else { return nil }

            let active = activeNumber.boolValue
            guard active == activeValues.contains(id),
                  !active || (lifecycle == .running && state != .proven) else { return nil }

            var evidence: [AgentTaskProgressEvidence] = []
            for item in rawEvidence {
                guard Set(item.keys).isSubset(of: ["label", "detail", "reveal_path"]),
                      Set(item.keys).isSuperset(of: ["label", "detail"]),
                      let label = item["label"] as? String, !label.isEmpty, label.utf8.count <= 160,
                      let detail = item["detail"] as? String, detail.utf8.count <= 4096 else { return nil }
                let revealPath: String?
                if let value = item["reveal_path"] as? String,
                   value.hasPrefix("/"), value.utf8.count <= 4096,
                   ["File contents matched", "File write verified", "File append verified", "File exists",
                    "Folder exists", "Full file contents read"].contains(label), state == .proven {
                    revealPath = value
                } else if item["reveal_path"] == nil {
                    revealPath = nil
                } else {
                    return nil
                }
                evidence.append(AgentTaskProgressEvidence(label: label, detail: detail, revealPath: revealPath))
                evidenceBytes += label.utf8.count + detail.utf8.count + (revealPath?.utf8.count ?? 0)
                guard evidenceBytes <= 512 * 1024 else { return nil }
            }
            guard (state == .proven && !evidence.isEmpty) || (state != .proven && evidence.isEmpty) else { return nil }
            requirements.append(AgentTaskProgressRequirement(id: id, sourceRanges: sourceRanges, state: state,
                                                              active: active, evidence: evidence))
        }
        guard Set(activeValues).isSubset(of: identifiers) else { return nil }
        return Self(generationID: generationID, revision: revision, lifecycle: lifecycle,
                    wholeRequestCoverage: coverage, activeRequirementIDs: activeValues, requirements: requirements,
                    resultObjects: resultObjects)
    }

    private static func isRequirementID(_ value: String) -> Bool {
        value.range(of: #"^r[1-9][0-9]*$"#, options: .regularExpression) != nil
    }

    private static func exactInteger(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return Int(number.stringValue)
    }
}

struct TaskProgressMap: Equatable {
    var originalRequest: String
    let generationID: String
    var revision: UInt64
    var lifecycle: AgentTaskProgressLifecycle
    var wholeRequestCoverage: String
    var activeRequirementIDs: [String]
    var requirements: [AgentTaskProgressRequirement]
    var resultObjects: [AgentTaskResultObject]

    init(request: String, generationID: String) {
        originalRequest = request
        self.generationID = generationID
        revision = 0
        lifecycle = .running
        wholeRequestCoverage = "pending"
        activeRequirementIDs = []
        requirements = []
        resultObjects = []
    }

    init(request: String, snapshot: AgentTaskProgressSnapshot) {
        originalRequest = request
        generationID = snapshot.generationID
        revision = snapshot.revision
        lifecycle = snapshot.lifecycle
        wholeRequestCoverage = snapshot.wholeRequestCoverage
        activeRequirementIDs = snapshot.activeRequirementIDs
        requirements = snapshot.requirements
        resultObjects = snapshot.resultObjects
    }
}
