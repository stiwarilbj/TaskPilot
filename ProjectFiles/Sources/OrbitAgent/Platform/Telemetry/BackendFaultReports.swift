import CoreFoundation
import Foundation

/// No free-form fields, payloads or task identifiers. Explicit links alone
/// establish causality; simultaneous faults are never merged by proximity.
final class BackendFaultReports: @unchecked Sendable {
    enum Cause: String, CaseIterable {
        case unknown, transport, configuration, credentials
        case gatewayUnavailable = "gateway_unavailable", providerQuota = "provider_quota"
        case providerCapacity = "provider_capacity", modelUnavailable = "model_unavailable"
        case invalidOutput = "invalid_output", commandTimeout = "command_timeout", nativeProtocol = "native_protocol"
        var route: Route {
            switch self {
            case .unknown: .none
            case .transport: .reconnect
            case .gatewayUnavailable: .gatewayRestart
            case .configuration, .credentials: .attention
            case .providerQuota, .providerCapacity, .modelUnavailable: .providerPolicy
            case .invalidOutput: .formatRepair
            case .commandTimeout, .nativeProtocol: .reconcile
            }
        }
        func permits(_ route: Route) -> Bool {
            route == self.route || self == .gatewayUnavailable && route == .reconnect
        }
    }
    enum Stage: String, CaseIterable {
        case healthCheck = "health_check", connection, modelRequest = "model_request"
        case nativeAction = "native_action", recovery, waiting, draining, terminal
    }
    enum Route: Hashable { case none, reconnect, gatewayRestart, attention, providerPolicy, formatRepair, reconcile }
    fileprivate struct Claim: Hashable { let route: Route; let attempt: Int }
    struct Link: Hashable { fileprivate let id: UUID }
    struct Report {
        let link: Link
        let cause: Cause
        let firstStage: Stage
        let started: TimeInterval
        fileprivate var sequence = 0
        var consequences: [Stage: Int] = [:]
        fileprivate var attempts: Set<Claim> = []
        var suppressedRecoveries = 0
    }
    struct Event {
        let id: UUID
        let sequence: Int
        let cause: Cause
        let stage: Stage
        static func decode(_ value: [String: Any]) -> Event? {
            guard Set(value.keys) == ["version", "fault_id", "sequence", "cause", "stage"],
                  integer(value["version"]) == 1,
                  let sequence = integer(value["sequence"]), (1...16).contains(sequence),
                  let text = value["fault_id"] as? String, text.count == 36,
                  let id = UUID(uuidString: text), id.uuidString.lowercased() == text,
                  let name = value["cause"] as? String, let cause = Cause(rawValue: name),
                  let name = value["stage"] as? String, let stage = Stage(rawValue: name) else { return nil }
            return Event(id: id, sequence: sequence, cause: cause, stage: stage)
        }
        fileprivate static func integer(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  !["d", "f"].contains(String(cString: n.objCType)),
                  n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 16,
                  n.doubleValue.rounded() == n.doubleValue else { return nil }
            return n.intValue
        }
    }
    struct Relation {
        let child: UUID
        let parent: UUID
        static func decode(_ value: [String: Any]) -> Relation? {
            guard Set(value.keys) == ["version", "child_id", "parent_id"], Event.integer(value["version"]) == 1,
                  let c = value["child_id"] as? String, c.count == 36,
                  let p = value["parent_id"] as? String, p.count == 36,
                  let child = UUID(uuidString:c), let parent = UUID(uuidString:p), child != parent,
                  child.uuidString.lowercased() == c, parent.uuidString.lowercased() == p else { return nil }
            return Relation(child:child, parent:parent)
        }
    }
    /// One per invocation/host. A remote token cannot attach to another task's
    /// report, even if that task happens to send the same opaque UUID.
    final class Scope {
        private var imports: [UUID: (Link, Int)] = [:]
        private var order: [UUID] = []
        private let reports: BackendFaultReports
        init(_ reports: BackendFaultReports) { self.reports = reports }
        // Confined to its owner's serial queue.
        @discardableResult func accept(_ event: Event) -> Bool {
            if let (link, last) = imports[event.id] {
                guard event.sequence == last + 1, reports.note(link, event.stage, cause: event.cause) else { return false }
                imports[event.id] = (link, event.sequence)
            } else {
                guard event.sequence == 1 else { return false }
                let link = reports.begin(event.cause, at: event.stage)
                imports[event.id] = (link, 1); order.append(event.id)
                if order.count > 64 { imports.removeValue(forKey: order.removeFirst()) }
            }
            return true
        }
        @discardableResult func accept(_ relation: Relation) -> Bool {
            guard let child = imports[relation.child]?.0, let parent = imports[relation.parent]?.0 else { return false }
            return reports.attach(child, to:parent)
        }
    }
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private let record: @Sendable (Cause, Stage, Bool) -> Void
    private let capacity: Int
    private let ttl: TimeInterval
    private var values: [Report] = []
    private var aliases: [Link: Link] = [:]
    init(capacity: Int = 32, ttl: TimeInterval = 120,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         record: @escaping @Sendable (Cause, Stage, Bool) -> Void = { _, _, _ in }) {
        self.capacity = max(1, min(64, capacity)); self.ttl = max(1, min(120, ttl))
        self.now = now; self.record = record
    }
    private func prune() {
        let time = now(); values.removeAll { !(0..<ttl).contains(time - $0.started) }
        let live = Set(values.map(\.link)); aliases = aliases.filter { live.contains($0.value) }
    }
    private func resolved(_ link: Link) -> Link { aliases[link] ?? link }
    func begin(_ cause: Cause, at stage: Stage) -> Link {
        lock.withLock {
            prune()
            let link = Link(id: UUID())
            values.append(Report(link: link, cause: cause, firstStage: stage, started: now(), sequence: 1))
            if values.count > capacity { values.removeFirst() }
            record(cause, stage, false)
            return link
        }
    }
    @discardableResult func note(_ link: Link, _ stage: Stage, cause: Cause? = nil) -> Bool {
        lock.withLock {
            prune()
            guard let index = values.firstIndex(where: { $0.link == resolved(link) }),
                  cause == nil || cause == values[index].cause || cause == .transport && values[index].cause == .gatewayUnavailable else { return false }
            if values[index].sequence < 16 {
                values[index].sequence += 1
                if values[index].consequences.values.reduce(0, +) < 15 { values[index].consequences[stage, default: 0] += 1 }
                record(values[index].cause, stage, true)
            }
            return true
        }
    }
    /// An attempt is assigned by the existing recovery budget. Diagnostic
    /// correlation cannot allocate attempts or authorize a different route.
    func claim(_ link: Link, route: Route, attempt: Int = 1) -> Bool {
        lock.withLock {
            prune()
            guard let i = values.firstIndex(where: { $0.link == resolved(link) }), route != .none,
                  values[i].cause.permits(route), (1...16).contains(attempt) else { return false }
            guard values[i].attempts.insert(Claim(route:route, attempt:attempt)).inserted else {
                values[i].suppressedRecoveries = min(1_000_000_000, values[i].suppressedRecoveries + 1)
                return false
            }
            return true
        }
    }
    func reports() -> [Report] { lock.withLock { prune(); return values } }
    /// Only a freshly verified host root and its specific interrupted
    /// connection can join. Quota, native IPC and command faults cannot join it.
    @discardableResult func attach(_ child: Link, to parent: Link) -> Bool {
        lock.withLock {
            prune()
            let child = resolved(child), parent = resolved(parent)
            if child == parent { return true }
            guard let c = values.firstIndex(where:{ $0.link == child }),
                  let p = values.firstIndex(where:{ $0.link == parent }),
                  values[c].cause == .transport, values[p].cause == .gatewayUnavailable,
                  aliases.count < 64 else { return false }
            values[p].attempts.formUnion(values[c].attempts)
            values[p].suppressedRecoveries = min(1_000_000_000, values[p].suppressedRecoveries + values[c].suppressedRecoveries)
            var counts = values[c].consequences
            counts[values[c].firstStage, default:0] += 1
            for stage in Stage.allCases {
                let remaining = max(0, 15 - values[p].consequences.values.reduce(0, +))
                values[p].consequences[stage, default:0] += min(remaining, counts[stage] ?? 0)
            }
            aliases[child] = parent
            values.remove(at:c)
            record(.gatewayUnavailable, .connection, true)
            return true
        }
    }
    /// Health metadata carries only an opaque root and fixed enums. It is not
    /// readiness proof; readers must validate the host/descriptor independently.
    func healthEvent(_ link: Link?) -> [String: Any]? {
        lock.withLock {
            prune()
            guard let link, let value = values.first(where: { $0.link == resolved(link) }) else { return nil }
            return ["version": 1, "fault_id": link.id.uuidString.lowercased(), "sequence": 1,
                    "cause": value.cause.rawValue, "stage": value.firstStage.rawValue]
        }
    }
}
