import Foundation

// One invocation, confined to its serialized I/O queue. Compare the last
// scheduled value per snapshot channel, including work still on the main
// queue. Never coalesce distinct transitions or suppress event deliveries.
struct RuntimeSnapshotFilter {
    private var status: String?
    private var diagnostics: AgentRequestMetrics?
    private var taskWait: AgentTaskWaitSnapshot?

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
