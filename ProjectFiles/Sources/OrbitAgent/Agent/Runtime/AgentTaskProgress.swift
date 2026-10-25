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

enum AgentTaskBatchItemState: String, Equatable {
    case waiting
    case working
    case verified
    case needsRecheck = "needs_recheck"
    case unfinished
}

struct AgentTaskBatchOutcome: Equatable, Identifiable {
    let id: String
    let label: String
}

struct AgentTaskBatchItem: Equatable, Identifiable {
    let id: String
    let inputID: String
    let reference: String
    let kind: String
    let state: AgentTaskBatchItemState
    let active: Bool
    let currentStep: String
    let outcomes: [AgentTaskBatchOutcome]
}

struct AgentTaskBatchProgress: Equatable {
    let needsDeclaration: Bool
    let handledCount: Int
    let items: [AgentTaskBatchItem]
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

enum AgentTaskInputRoleOrigin: String, Equatable {
    case user
    case inferred
    case unresolved
}

struct AgentTaskInputRoleAssignment: Equatable {
    let role: AgentTaskInputRole?
    let origin: AgentTaskInputRoleOrigin
}

struct AgentTaskInputRolesSnapshot: Equatable {
    let generationID: String
    let instructionRevision: UInt64
    let revision: UInt64
    let assignments: [String: AgentTaskInputRoleAssignment]

    var estimatedByteCount: Int { 256 + assignments.reduce(0) { $0 + $1.key.utf8.count + 64 } }

    static func parse(_ message: [String: Any], generationID: String, instructionRevision: UInt64,
                      exactReferences: [AgentTaskInputReference]) -> Self? {
        guard Set(message.keys) == ["kind", "task_generation_id", "instruction_revision", "revision", "version", "roles"],
              message["kind"] as? String == "task_input_roles",
              message["task_generation_id"] as? String == generationID,
              exactUnsigned(message["instruction_revision"]) == instructionRevision,
              let revision = exactUnsigned(message["revision"]), revision > 0,
              exactUnsigned(message["version"]) == 1,
              let values = message["roles"] as? [[String: Any]], values.count == exactReferences.count,
              values.count <= 128 else { return nil }
        let known = Set(exactReferences.map(\.id))
        var assignments: [String: AgentTaskInputRoleAssignment] = [:]
        for value in values {
            guard Set(value.keys) == ["occurrence_id", "role", "origin"],
                  let identifier = value["occurrence_id"] as? String, known.contains(identifier),
                  assignments[identifier] == nil,
                  let originValue = value["origin"] as? String,
                  let origin = AgentTaskInputRoleOrigin(rawValue: originValue) else { return nil }
            let role: AgentTaskInputRole?
            if value["role"] is NSNull { role = nil }
            else if let rawRole = value["role"] as? String, let parsed = AgentTaskInputRole(rawValue: rawRole) { role = parsed }
            else { return nil }
            guard (origin == .unresolved) == (role == nil),
                  origin != .user || exactReferences.first(where: { $0.id == identifier })?.userRole == role else { return nil }
            assignments[identifier] = AgentTaskInputRoleAssignment(role: role, origin: origin)
        }
        guard Set(assignments.keys) == known else { return nil }
        return Self(generationID: generationID, instructionRevision: instructionRevision,
                    revision: revision, assignments: assignments)
    }
}

private func exactUnsigned(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue >= 0, number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
    return UInt64(number.stringValue)
}

struct AgentTaskProgressSnapshot: Equatable {
    let generationID: String
    let revision: UInt64
    let lifecycle: AgentTaskProgressLifecycle
    let wholeRequestCoverage: String
    let activeRequirementIDs: [String]
    let requirements: [AgentTaskProgressRequirement]
    let resultObjects: [AgentTaskResultObject]
    let batch: AgentTaskBatchProgress?

    var estimatedByteCount: Int {
        var textBytes = 0
        for requirement in requirements {
            var requirementBytes = requirement.id.utf8.count + requirement.sourceRanges.count * 40 + 64
            for evidence in requirement.evidence {
                requirementBytes += evidence.label.utf8.count + evidence.detail.utf8.count
                    + (evidence.revealPath?.utf8.count ?? 0) + 48
            }
            textBytes += requirementBytes
        }
        for identifier in activeRequirementIDs { textBytes += identifier.utf8.count + 4 }
        textBytes += resultObjects.reduce(0) { $0 + $1.estimatedByteCount }
        if let batch {
            textBytes += 64
            for item in batch.items {
                var itemBytes = item.id.utf8.count + item.inputID.utf8.count + item.reference.utf8.count
                    + item.kind.utf8.count + item.currentStep.utf8.count + 96
                for outcome in item.outcomes {
                    itemBytes += outcome.id.utf8.count + outcome.label.utf8.count + 24
                }
                textBytes += itemBytes
            }
        }
        // JSON escaping can expand control characters to six bytes each.
        return 1_024 + textBytes * 6
    }

    static func parse(_ message: [String: Any], generationID: String) -> Self? {
        let requiredKeys: Set<String> = ["kind", "task_generation_id", "revision", "version", "lifecycle",
                                         "whole_request_coverage", "active_requirement_ids", "requirements",
                                         "result_objects", "batch"]
        guard Set(message.keys) == requiredKeys,
              message["kind"] as? String == "task_progress",
              message["task_generation_id"] as? String == generationID,
              let revisionNumber = message["revision"] as? NSNumber,
              CFGetTypeID(revisionNumber) != CFBooleanGetTypeID(),
              let revision = UInt64(revisionNumber.stringValue), revision > 0,
              let version = message["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 3, version.doubleValue == 3,
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
        let batch: AgentTaskBatchProgress?
        if message["batch"] is NSNull {
            batch = nil
        } else if let value = parseBatch(message["batch"], lifecycle: lifecycle, requirements: requirements) {
            batch = value
        } else {
            return nil
        }
        return Self(generationID: generationID, revision: revision, lifecycle: lifecycle,
                    wholeRequestCoverage: coverage, activeRequirementIDs: activeValues, requirements: requirements,
                    resultObjects: resultObjects, batch: batch)
    }

    private static func parseBatch(_ value: Any?, lifecycle: AgentTaskProgressLifecycle,
                                   requirements: [AgentTaskProgressRequirement]) -> AgentTaskBatchProgress? {
        guard let raw = value as? [String: Any],
              Set(raw.keys) == ["version", "needs_declaration", "handled_count", "items"],
              let rawVersion = raw["version"], exactInteger(rawVersion) == 1,
              let needsDeclarationNumber = raw["needs_declaration"] as? NSNumber,
              CFGetTypeID(needsDeclarationNumber) == CFBooleanGetTypeID(),
              let rawHandledCount = raw["handled_count"], let handledCount = exactInteger(rawHandledCount), handledCount <= 128,
              let rawItems = raw["items"] as? [[String: Any]], rawItems.count >= 2, rawItems.count <= 128 else {
            return nil
        }
        let requirementsByID = Dictionary(uniqueKeysWithValues: requirements.map { ($0.id, $0) })
        var items: [AgentTaskBatchItem] = []
        var itemIDs = Set<String>()
        var inputIDs = Set<String>()
        var references = Set<String>()
        var associatedRequirements = Set<String>()
        var provenCount = 0
        for item in rawItems {
            guard Set(item.keys) == ["id", "input_id", "reference", "kind", "state", "active", "current_step", "outcomes"],
                  let id = item["id"] as? String, id.range(of: #"^b[1-9][0-9]*$"#, options: .regularExpression) != nil,
                  itemIDs.insert(id).inserted,
                  let inputID = item["input_id"] as? String,
                  inputID.range(of: #"^input_[0-9a-f]{16}_[1-9][0-9]*$"#, options: .regularExpression) != nil,
                  inputIDs.insert(inputID).inserted,
                  let reference = item["reference"] as? String, safeReference(reference), references.insert(reference).inserted,
                  let kind = item["kind"] as? String, ["file", "folder", "url", "path", "filename"].contains(kind),
                  let rawState = item["state"] as? String, let state = AgentTaskBatchItemState(rawValue: rawState),
                  let activeNumber = item["active"] as? NSNumber, CFGetTypeID(activeNumber) == CFBooleanGetTypeID(),
                  let step = safeText(item["current_step"], maximumBytes: 200),
                  let rawOutcomes = item["outcomes"] as? [[String: Any]], rawOutcomes.count <= 512 else {
                return nil
            }
            var outcomes: [AgentTaskBatchOutcome] = []
            for outcome in rawOutcomes {
                guard Set(outcome.keys) == ["id", "label"],
                      let requirementID = outcome["id"] as? String, isRequirementID(requirementID),
                      associatedRequirements.insert(requirementID).inserted,
                      requirementsByID[requirementID] != nil,
                      let label = safeText(outcome["label"], maximumBytes: 160) else { return nil }
                outcomes.append(AgentTaskBatchOutcome(id: requirementID, label: label))
            }
            let active = activeNumber.boolValue
            let associated = outcomes.compactMap { requirementsByID[$0.id] }
            let hasInvalidated = associated.contains(where: { $0.state == .invalidated })
            let allProven = !associated.isEmpty && associated.allSatisfy({ $0.state == .proven })
            let hasActivePending = associated.contains(where: { $0.active && $0.state != .proven })
            let isTerminal = lifecycle == .completed || lifecycle == .failed || lifecycle == .stopped
            let expectedState: AgentTaskBatchItemState
            if hasInvalidated {
                expectedState = .needsRecheck
            } else if needsDeclarationNumber.boolValue {
                expectedState = isTerminal ? .unfinished : .waiting
            } else if allProven {
                expectedState = .verified
            } else if associated.isEmpty {
                expectedState = .waiting
            } else if lifecycle == .running && hasActivePending {
                expectedState = .working
            } else if isTerminal {
                expectedState = .unfinished
            } else {
                expectedState = .waiting
            }
            guard state == expectedState, active == (state == .working),
                  state != .working || (lifecycle == .running && hasActivePending) else { return nil }
            if state == .verified { provenCount += 1 }
            items.append(AgentTaskBatchItem(id: id, inputID: inputID, reference: reference, kind: kind,
                                            state: state, active: active, currentStep: step, outcomes: outcomes))
        }
        guard provenCount == Int(handledCount) else { return nil }
        if !needsDeclarationNumber.boolValue && items.contains(where: { $0.outcomes.isEmpty }) { return nil }
        return AgentTaskBatchProgress(needsDeclaration: needsDeclarationNumber.boolValue,
                                      handledCount: Int(handledCount), items: items)
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

    private static func safeReference(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8_192 && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func safeText(_ value: Any?, maximumBytes: Int) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= maximumBytes,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
}

struct TaskProgressMap: Equatable {
    var originalRequest: String
    var exactInputReferences: [AgentTaskInputReference]
    let generationID: String
    var revision: UInt64
    var lifecycle: AgentTaskProgressLifecycle
    var wholeRequestCoverage: String
    var activeRequirementIDs: [String]
    var requirements: [AgentTaskProgressRequirement]
    var resultObjects: [AgentTaskResultObject]
    var batch: AgentTaskBatchProgress?
    var inputRoles: [String: AgentTaskInputRoleAssignment]

    var stopBoundaries: [StopBoundaryRecord] {
        StopBoundaryPolicy.detect(in: originalRequest, exactInputReferences: exactInputReferences)
    }

    init(request: String, generationID: String, exactInputReferences: [AgentTaskInputReference] = []) {
        originalRequest = request
        self.exactInputReferences = exactInputReferences
        self.generationID = generationID
        revision = 0
        lifecycle = .running
        wholeRequestCoverage = "pending"
        activeRequirementIDs = []
        requirements = []
        resultObjects = []
        batch = nil
        inputRoles = Dictionary(uniqueKeysWithValues: exactInputReferences.compactMap { reference in
            reference.userRole.map { (reference.id, AgentTaskInputRoleAssignment(role: $0, origin: .user)) }
        })
    }

    init(request: String, snapshot: AgentTaskProgressSnapshot,
         exactInputReferences: [AgentTaskInputReference] = []) {
        originalRequest = request
        self.exactInputReferences = exactInputReferences
        generationID = snapshot.generationID
        revision = snapshot.revision
        lifecycle = snapshot.lifecycle
        wholeRequestCoverage = snapshot.wholeRequestCoverage
        activeRequirementIDs = snapshot.activeRequirementIDs
        requirements = snapshot.requirements
        resultObjects = snapshot.resultObjects
        batch = snapshot.batch
        inputRoles = Dictionary(uniqueKeysWithValues: exactInputReferences.compactMap { reference in
            reference.userRole.map { (reference.id, AgentTaskInputRoleAssignment(role: $0, origin: .user)) }
        })
    }
}
