import Darwin
import Foundation

/// Process-local admission accounting, not an executor. Component limits and
/// task ownership remain authoritative. No payloads, paths or task IDs live here.
final class LocalWorkloadGovernor: @unchecked Sendable {
    static let shared = LocalWorkloadGovernor(monitor: .shared)

    enum Kind: CaseIterable {
        case evidenceCapture, previewCapture, evidenceEncoding, previewEncoding
        case accessibility, ipc, terminalIPC, helper, maintenance
        var disposable: Bool { self == .previewCapture || self == .previewEncoding || self == .maintenance }
        var transport: Bool { self == .ipc || self == .terminalIPC }
    }
    enum Reason: String, CaseIterable { case memoryPressure, memoryCapacity, queueCapacity, descriptors, diskSpace }
    struct Refused: LocalizedError {
        let reason: Reason
        let deferred: Bool
        var errorDescription: String? {
            "local_workload_\(deferred ? "deferred" : "exhausted"):\(reason.rawValue)"
        }
    }
    struct Limits {
        // Estimated owned memory, not a claim about total process RSS. Keep
        // room for evidence/IPC when optional work has filled its soft share.
        var memoryBytes = Int(min(UInt64(268_435_456), max(UInt64(67_108_864), ProcessInfo.processInfo.physicalMemory / 32)))
        var essentialReserveBytes = 32 * 1024 * 1024
        var disposableQueueDepth = 16
        var requiredWorkCount = 64
    }
    struct DiskSpace {
        let device: UInt64
        let available: UInt64

        /// The nearest existing directory supplies volume identity and space
        /// from the same no-follow descriptor. Does not create any directory.
        static func read(directory: URL) throws -> Self {
            guard directory.isFileURL else { throw CaptureDiskHeadroom.Failure.unavailable }
            var current = directory.standardizedFileURL
            while true {
                let fd = open(current.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 {
                    let ticket = BackendDescriptors.shared.opened(.capture)
                    defer { close(fd); ticket.finish() }
                    var status = stat()
                    guard fstat(fd, &status) == 0 else { throw CaptureDiskHeadroom.Failure.unavailable }
                    return try Self(device: UInt64(bitPattern: Int64(status.st_dev)),
                                    available: CaptureDiskHeadroom.availableBytes(descriptor: fd))
                }
                guard errno == ENOENT else { throw CaptureDiskHeadroom.Failure.unavailable }
                let parent = current.deletingLastPathComponent()
                guard parent != current else { throw CaptureDiskHeadroom.Failure.unavailable }
                current = parent
            }
        }
    }
    struct Demand {
        var memoryBytes = 0
        var descriptors: UInt64 = 0
        var diskBytes: UInt64 = 0
        var disk: DiskSpace?
    }
    struct Snapshot {
        let queued: Int
        let active: Int
        let memoryBytes: Int
        let descriptors: UInt64
        let diskBytes: UInt64
        let refused: [Reason: UInt64]
        var reservations: Int { queued + active }
    }
    final class Reservation: @unchecked Sendable {
        private let governor: LocalWorkloadGovernor
        private let id: UUID
        private let budget: LocalOperationBudget?
        fileprivate init(governor: LocalWorkloadGovernor, id: UUID, budget: LocalOperationBudget?) {
            self.governor = governor; self.id = id; self.budget = budget
        }
        /// Recheck at the costly execution boundary after a queue wait.
        func start() throws {
            try budget?.checkDeadline(phase: "local_workload")
            try governor.update(id, demand: nil, starting: true)
        }
        func update(_ demand: Demand) throws {
            try budget?.checkDeadline(phase: "local_workload")
            try governor.update(id, demand: demand, starting: false)
        }
        func finish() { governor.release(id) }
        deinit { finish() }
    }
    private struct Entry { let kind: Kind; var demand: Demand; var started = false }
    private let lock = NSLock()
    private let limits: Limits
    private let descriptorHeadroom: () -> UInt64?
    private var entries: [UUID: Entry] = [:]
    private var queued = 0
    private var active = 0
    private var memoryBytes = 0
    private var descriptors: UInt64 = 0
    private var diskBytes: UInt64 = 0
    private var diskByDevice: [UInt64: UInt64] = [:]
    private var nonTransport = 0
    private var pressure: DispatchSource.MemoryPressureEvent = .normal
    private var pressureRevision: UInt64 = 0
    private var refusals: [Reason: UInt64] = [:]
    private var registration: MemoryPressureMonitor.Registration?

    init(limits: Limits = .init(), monitor: MemoryPressureMonitor? = nil,
         descriptorHeadroom: @escaping () -> UInt64? = { SubprocessSupervisor.DescriptorHeadroom.read()?.available }) {
        self.limits = limits; self.descriptorHeadroom = descriptorHeadroom
        registration = monitor?.registerPressure { [weak self] flags, revision in
            guard let self else { return }
            self.lock.withLock {
                if revision >= self.pressureRevision { self.pressure = flags; self.pressureRevision = revision }
            }
        }
    }

    func reserve(_ kind: Kind, demand: Demand = .init(),
                 budget: LocalOperationBudget? = LocalOperationBudget.current) throws -> Reservation {
        if kind != .terminalIPC { try Task.checkCancellation() }
        try budget?.checkDeadline(phase: "local_workload")
        let available = demand.descriptors > 0 ? descriptorHeadroom() : nil
        return try lock.withLock {
            let id = UUID(), entry = Entry(kind: kind, demand: demand)
            try validate(entry, replacing: nil, availableDescriptors: available)
            entries[id] = entry; account(entry, adding: true)
            return Reservation(governor: self, id: id, budget: budget)
        }
    }

    private func update(_ id: UUID, demand: Demand?, starting: Bool) throws {
        // Sampling does not hold the accounting lock or schedule any work.
        let descriptorCount = lock.withLock { demand?.descriptors ?? entries[id]?.demand.descriptors ?? 0 }
        let available = descriptorCount > 0 ? descriptorHeadroom() : nil
        try lock.withLock {
            guard let old = entries[id] else { throw CancellationError() }
            if starting && old.started && demand == nil { return }
            var entry = old
            if let demand { entry.demand = demand }
            if let available, entry.demand.descriptors > 0 {
                let needed = (descriptors - old.demand.descriptors).addingReportingOverflow(entry.demand.descriptors)
                if needed.overflow || needed.partialValue > available { try refuse(.descriptors, kind: entry.kind) }
            }
            // Required work already admitted is not revoked by later pressure.
            // Only a larger allocation needs additional admission. Optional
            // work also checks pressure after waiting, before it starts.
            if entry.kind.disposable || entry.demand.memoryBytes > old.demand.memoryBytes ||
                entry.demand.descriptors > old.demand.descriptors || entry.demand.diskBytes > old.demand.diskBytes ||
                entry.demand.disk?.device != old.demand.disk?.device {
                try validate(entry, replacing: id, availableDescriptors: available)
            } else if let disk = entry.demand.disk, entry.demand.diskBytes > 0 {
                let needed = diskByDevice[disk.device, default: 0] - old.demand.diskBytes + entry.demand.diskBytes
                if needed > disk.available { try refuse(.diskSpace, kind: entry.kind) }
            }
            if starting { entry.started = true }
            account(old, adding: false); entries[id] = entry; account(entry, adding: true)
        }
    }
    private func refuse(_ reason: Reason, kind: Kind) throws {
        refusals[reason, default: 0] &+= 1
        throw Refused(reason: reason, deferred: kind.disposable)
    }
    private func validate(_ candidate: Entry, replacing id: UUID?, availableDescriptors: UInt64?) throws {
        let old = id.flatMap { entries[$0] }
        let demand = candidate.demand
        let memory = (memoryBytes - max(0, old?.demand.memoryBytes ?? 0)).addingReportingOverflow(max(0, demand.memoryBytes))
        if memory.overflow { try refuse(.memoryCapacity, kind: candidate.kind) }
        if (descriptors - (old?.demand.descriptors ?? 0)).addingReportingOverflow(demand.descriptors).overflow {
            try refuse(.descriptors, kind: candidate.kind)
        }
        if (diskBytes - (old?.demand.diskBytes ?? 0)).addingReportingOverflow(demand.diskBytes).overflow {
            try refuse(.diskSpace, kind: candidate.kind)
        }
        // Terminal and cancellation traffic bypass shared pressure gates. Its
        // writer's byte/frame caps and priority reserve are still hard limits.
        if candidate.kind == .terminalIPC { return }
        if candidate.kind.disposable {
            if !pressure.intersection([.warning, .critical]).isEmpty { try refuse(.memoryPressure, kind: candidate.kind) }
            if queued - (old != nil && old?.started == false ? 1 : 0) >= limits.disposableQueueDepth {
                try refuse(.queueCapacity, kind: candidate.kind)
            }
        } else if !candidate.kind.transport && nonTransport - (old != nil && old?.kind.transport == false ? 1 : 0) >= limits.requiredWorkCount {
            try refuse(.queueCapacity, kind: candidate.kind)
        }
        let capacity = candidate.kind.disposable ? max(0, limits.memoryBytes - limits.essentialReserveBytes) : limits.memoryBytes
        if memory.partialValue > capacity { try refuse(.memoryCapacity, kind: candidate.kind) }
        if let availableDescriptors {
            let needed = (descriptors - (old?.demand.descriptors ?? 0)).addingReportingOverflow(demand.descriptors)
            if needed.overflow || needed.partialValue > availableDescriptors { try refuse(.descriptors, kind: candidate.kind) }
        }
        if demand.diskBytes > 0 {
            guard let disk = demand.disk else { try refuse(.diskSpace, kind: candidate.kind); return }
            let previous = old?.demand.disk?.device == disk.device ? old?.demand.diskBytes ?? 0 : 0
            let needed = (diskByDevice[disk.device, default: 0] - previous).addingReportingOverflow(demand.diskBytes)
            if needed.overflow || needed.partialValue > disk.available { try refuse(.diskSpace, kind: candidate.kind) }
        }
    }
    /// All totals change with the entry under one short lock. IPC admission
    /// never walks the queue or builds a temporary array of other reservations.
    private func account(_ entry: Entry, adding: Bool) {
        let delta = adding ? 1 : -1
        if entry.started { active += delta } else { queued += delta }
        if !entry.kind.transport { nonTransport += delta }
        memoryBytes += delta * max(0, entry.demand.memoryBytes)
        if adding {
            descriptors += entry.demand.descriptors; diskBytes += entry.demand.diskBytes
        } else {
            descriptors -= entry.demand.descriptors; diskBytes -= entry.demand.diskBytes
        }
        if let device = entry.demand.disk?.device, entry.demand.diskBytes > 0 {
            let old = diskByDevice[device, default: 0]
            let next = adding ? old + entry.demand.diskBytes : old - entry.demand.diskBytes
            if next == 0 { diskByDevice.removeValue(forKey: device) } else { diskByDevice[device] = next }
        }
    }
    private func release(_ id: UUID) {
        lock.withLock { if let entry = entries.removeValue(forKey: id) { account(entry, adding: false) } }
    }
    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(queued: queued, active: active, memoryBytes: memoryBytes,
                     descriptors: descriptors, diskBytes: diskBytes, refused: refusals)
        }
    }
}
