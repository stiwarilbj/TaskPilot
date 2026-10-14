import Foundation

// One invocation, confined to its serialized I/O queue. Compare the last
// scheduled value per snapshot channel, including work still on the main
// queue. Never coalesce distinct transitions or suppress event deliveries.
struct RuntimeSnapshotFilter {
    private var status: String?
    private var diagnostics: AgentRequestMetrics?

    mutating func shouldSchedule(_ event: RuntimeEvent) -> Bool {
        switch event {
        case .status(let value):
            guard status != value else { return false }
            status = value
        case .diagnostics(let value):
            guard diagnostics != value else { return false }
            diagnostics = value
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
