import Foundation

// One invocation, confined to its serialized I/O queue. Compare the last
// scheduled value per snapshot channel, including work still on the main
// queue. Never coalesce distinct transitions or suppress event deliveries.
struct RuntimeSnapshotFilter {
    private var status: String?
    private var diagnostics: AgentRequestMetrics?
    private var taskWait: AgentTaskWaitSnapshot?
    private var taskDestination: AgentTaskDestinationSnapshot?
    private var taskInputRoles: AgentTaskInputRolesSnapshot?
    private var continuationCheckpoint: (generationID: String, revision: UInt64, fingerprint: String)?

    #if DEBUG
    private var sizeAuditCountdown = 0
    /// Called only after normal filtering/admission. Samples 1, 65, 129, ...
    /// among events with an exact serialized source; never retains the source.
    mutating func auditSerializedSize(estimatedBytes: Int, serializedBytes: Int?, telemetry: BackendTelemetry) {
        guard let serializedBytes, serializedBytes >= 0, estimatedBytes >= 0 else { return }
        if sizeAuditCountdown == 0 {
            telemetry.recordSnapshotSizeEstimate(estimatedBytes: estimatedBytes, serializedBytes: serializedBytes)
            sizeAuditCountdown = 63
        } else { sizeAuditCountdown -= 1 }
    }
    #endif

    /// Accounts for a runtime event that has passed snapshot filtering and is
    /// about to be retained by the main-queue delivery closure. The ticket
    /// contains numeric size metadata only and releases on every exit path.
    func beginInFlightSnapshot(byteCount: Int, telemetry: BackendTelemetry) -> BackendTelemetry.MemoryTicket {
        telemetry.beginMemory(.inFlightSnapshots, bytes: max(0, byteCount))
    }

    mutating func shouldSchedule(_ event: RuntimeEvent) -> Bool {
        switch event {
        case .status(let value):
            guard status != value else { return false }
            status = value
        case .diagnostics(let value):
            guard diagnostics != value else { return false }
            diagnostics = value
        case .taskWait(let value):
            if let current = taskWait,
               current.disclosureIdentity == value.disclosureIdentity,
               current.phase == value.phase,
               current.lastConfirmed == value.lastConfirmed,
               current.waitingFor == value.waitingFor,
               current.attention == value.attention {
                return false
            }
            taskWait = value
        case .taskDestination(let value):
            if let current = taskDestination,
               current.generationID == value.generationID,
               current.instructionRevision == value.instructionRevision,
               current.operationID == value.operationID,
               current.state == value.state,
               current.plannedPath == value.plannedPath,
               current.actualPath == value.actualPath,
               current.requestedFilename == value.requestedFilename,
               current.selectedFilename == value.selectedFilename,
               current.destinationExists == value.destinationExists,
               current.instruction == value.instruction,
               current.observationRevision == value.observationRevision {
                return false
            }
            taskDestination = value
        case .taskInputRoles(let value):
            if let current = taskInputRoles,
               current.generationID == value.generationID,
               current.instructionRevision == value.instructionRevision,
               current.assignments == value.assignments { return false }
            taskInputRoles = value
        case .taskContinuationCheckpoint(let value):
            let fingerprint = value.taskSHA256 + ":" + String(value.isEligible) + ":" +
                String(value.priorVerifiedRequirementCount) + ":" + String(value.unresolvedReceiptCount)
            if continuationCheckpoint?.generationID == value.generationID,
               continuationCheckpoint?.revision == value.revision,
               continuationCheckpoint?.fingerprint == fingerprint {
                return false
            }
            continuationCheckpoint = (value.generationID, value.revision, fingerprint)
        case .userInputRequired:
            // The input handoff changes status outside the runtime channel.
            invalidateStatus()
        default:
            break
        }
        return true
    }

    // Pause/Resume and credential replies change the coordinator's status.
    // An identical subsequent runtime status must be publishable again.
    mutating func invalidateStatus() { status = nil }
}
