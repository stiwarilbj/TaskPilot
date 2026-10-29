import Foundation

/// The single ordered evaluator used at native action delivery boundaries.
/// Policy implementations stay local to their owning subsystem; this type
/// determines their order and gives every failure a stable, private outcome.
enum NativeActionBoundaryPolicy {
    static let version = 1

    enum Stage: String, CaseIterable {
        case ownership
        case instructionRevision = "instruction_revision"
        case workingDocumentRevision = "working_document_revision"
        case stopBefore = "stop_before"
        case targetChoice = "target_choice"
        case documentBinding = "document_binding"
        case selectionScope = "selection_scope"
        case destinationIdentity = "destination_identity"
        case resolvedTarget = "resolved_target"
    }

    enum Disposition: String {
        case allow
        case reject
        case refreshEvidence = "refresh_evidence"
    }

    enum Reason: String {
        case none
        case taskRevoked = "task_revoked"
        case instructionSuperseded = "instruction_superseded"
        case workingDocumentChanged = "working_document_changed"
        case stopBoundaryRejected = "stop_boundary_rejected"
        case stopBoundaryUncertain = "stop_boundary_uncertain"
        case targetChoiceStale = "target_choice_stale"
        case targetChoiceConflict = "target_choice_conflict"
        case selectionScopeChanged = "selection_scope_changed"
        case destinationIdentityChanged = "destination_identity_changed"
        case staleTarget = "stale_target"
        case ambiguousTarget = "ambiguous_target"
        case actionPolicyRejected = "action_policy_rejected"
        case policyProtocolError = "policy_protocol_error"
    }

    struct Decision: Equatable {
        let disposition: Disposition
        let reason: Reason
        static let allow = Decision(disposition: .allow, reason: .none)
    }

    /// Only task-scoped policy inputs are included. Values are consumed in
    /// memory and are never added to prompts, receipts, or diagnostics.
    struct Constraints {
        let generationID: String?
        let instructionRevision: UInt64?
        let workingDocumentRevision: UInt64?
        let targetBindingRevision: UInt64?
        let stopBoundaries: [StopBoundaryRecord]
        let targetBindings: [[String: Any]]
        let allowWorkingSelectionSaveExport: Bool
        let alreadyDispatched: Bool
    }

    struct ResolvedTarget {
        enum Kind: String { case accessibility, coordinate, file, command, application, unresolved }
        let kind: Kind
        let processID: Int32?
        let role: String?
        let identity: String?
        let reliable: Bool
        let ambiguous: Bool
    }

    struct Context {
        let action: [String: Any]?
        let constraints: Constraints
        var resolvedTarget: ResolvedTarget?
    }

    struct Check {
        let stage: Stage
        let run: (inout Context) throws -> Void
        init(_ stage: Stage, _ run: @escaping (inout Context) throws -> Void) {
            self.stage = stage
            self.run = run
        }
    }

    struct Evaluation {
        let decision: Decision
        let failure: Error?
    }

    struct Probe: Decodable {
        let stage: String
        let disposition: String
        let reason: String

        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let allowed: Set<String> = ["stage", "disposition", "reason"]
            guard Set(container.allKeys.map(\.stringValue)) == allowed else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Policy probe has missing or unknown fields"))
            }
            stage = try container.decode(String.self, forKey: Key(stringValue: "stage")!)
            disposition = try container.decode(String.self, forKey: Key(stringValue: "disposition")!)
            reason = try container.decode(String.self, forKey: Key(stringValue: "reason")!)
        }
    }

    static let stageOrder = Stage.allCases.map(\.rawValue)

    static func evaluate(_ checks: [Check], context initial: Context) -> Evaluation {
        guard checks.count <= 64 else {
            return Evaluation(decision: Decision(disposition: .reject, reason: .policyProtocolError), failure: nil)
        }
        let ordered = checks.enumerated().sorted { lhs, rhs in
            let left = Stage.allCases.firstIndex(of: lhs.element.stage) ?? Int.max
            let right = Stage.allCases.firstIndex(of: rhs.element.stage) ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        var context = initial
        for (_, check) in ordered {
            do { try check.run(&context) }
            catch { return Evaluation(decision: decision(for: error, at: check.stage), failure: error) }
        }
        if context.resolvedTarget?.ambiguous == true {
            let error = AccessibilityActionError.ambiguousTarget
            return Evaluation(decision: decision(for: error, at: .resolvedTarget), failure: error)
        }
        return Evaluation(decision: .allow, failure: nil)
    }

    /// Shared-fixture entry point. Unknown or malformed values fail closed.
    static func decision(for probes: [Probe]) -> Decision {
        guard probes.count <= 64, probes.allSatisfy({ probe in
            guard stageOrder.contains(probe.stage),
                  let disposition = Disposition(rawValue: probe.disposition),
                  let reason = Reason(rawValue: probe.reason) else { return false }
            return (disposition == .allow) == (reason == .none)
        }) else { return Decision(disposition: .reject, reason: .policyProtocolError) }
        let indexed = probes.enumerated().sorted { lhs, rhs in
            let li = stageOrder.firstIndex(of: lhs.element.stage)!
            let ri = stageOrder.firstIndex(of: rhs.element.stage)!
            return li == ri ? lhs.offset < rhs.offset : li < ri
        }
        for (_, probe) in indexed {
            let disposition = Disposition(rawValue: probe.disposition)!
            let reason = Reason(rawValue: probe.reason)!
            if disposition != .allow { return Decision(disposition: disposition, reason: reason) }
        }
        return .allow
    }

    static func decision(for error: Error, at stage: Stage) -> Decision {
        if error is CancellationError { return Decision(disposition: .reject, reason: .taskRevoked) }
        if let error = error as? TaskInstructionCorrectionError, case .superseded = error {
            return Decision(disposition: .refreshEvidence, reason: .instructionSuperseded)
        }
        if let error = error as? WorkingDocumentUpdateError, case .superseded = error {
            return Decision(disposition: .refreshEvidence, reason: .workingDocumentChanged)
        }
        if let error = error as? StopBoundaryViolation {
            switch error {
            case .rejected: return Decision(disposition: .reject, reason: .stopBoundaryRejected)
            case .uncertain: return Decision(disposition: .refreshEvidence, reason: .stopBoundaryUncertain)
            }
        }
        if let error = error as? TargetChoiceError {
            switch error {
            case .stale: return Decision(disposition: .refreshEvidence, reason: .targetChoiceStale)
            case .superseded: return Decision(disposition: .refreshEvidence, reason: .instructionSuperseded)
            case .conflict, .opaqueCommand: return Decision(disposition: .reject, reason: .targetChoiceConflict)
            }
        }
        if let error = error as? AccessibilityActionError {
            switch error {
            case .staleObservation, .elementUnavailable: return Decision(disposition: .refreshEvidence, reason: .staleTarget)
            case .ambiguousTarget: return Decision(disposition: .refreshEvidence, reason: .ambiguousTarget)
            case .workingDocumentLost, .workingDocumentTargetMismatch:
                return Decision(disposition: .refreshEvidence, reason: .workingDocumentChanged)
            case .workingSelectionLost, .workingSelectionTargetMismatch:
                return Decision(disposition: .refreshEvidence, reason: .selectionScopeChanged)
            default: break
            }
        }
        if error is BoundFileOperation.Conflict {
            return Decision(disposition: .refreshEvidence, reason: .destinationIdentityChanged)
        }
        let reason: Reason = switch stage {
        case .instructionRevision: .instructionSuperseded
        case .workingDocumentRevision, .documentBinding: .workingDocumentChanged
        case .stopBefore: .stopBoundaryUncertain
        case .targetChoice: .targetChoiceStale
        case .selectionScope: .selectionScopeChanged
        case .destinationIdentity: .destinationIdentityChanged
        case .resolvedTarget: .staleTarget
        case .ownership: .taskRevoked
        }
        let refreshReasons: Set<Reason> = [
            .instructionSuperseded, .workingDocumentChanged, .stopBoundaryUncertain,
            .targetChoiceStale, .selectionScopeChanged, .destinationIdentityChanged, .staleTarget
        ]
        return Decision(disposition: refreshReasons.contains(reason) ? .refreshEvidence : .reject, reason: reason)
    }

    static func throwIfRejected(_ evaluation: Evaluation) throws {
        guard evaluation.decision.disposition == .allow else {
            if let failure = evaluation.failure { throw failure }
            throw PolicyFailure(decision: evaluation.decision)
        }
    }

    struct PolicyFailure: LocalizedError {
        let decision: Decision
        var code: String { decision.reason.rawValue }
        var errorDescription: String? { "The native action was held by the task safety policy." }
    }
}
