import Foundation
import ProcessSupport

/// Advisory accounting for descriptors opened by instrumented TaskPilot code.
/// Contains no paths, descriptor numbers, process IDs or task identifiers.
final class BackendDescriptors: @unchecked Sendable {
    static let shared = BackendDescriptors()
    enum Subsystem: CaseIterable { case subprocess, runtimeReadPipe, runtimeWritePipe, commandOutput, capture, magnifier }
    enum Lifecycle: CaseIterable { case active, draining, retired }
    enum Retention { case work, retainedResource }
    final class Owner: @unchecked Sendable {
        fileprivate var lifecycle: Lifecycle = .active // confined to registry lock
        fileprivate var lastDrain: DrainReport?
    }
    struct Counts {
        let subsystem: Subsystem
        let lifecycle: Lifecycle
        var open = 0
        var retained = 0
        var unowned = 0
    }
    struct DrainReport {
        let workRemaining: Int
        let retainedResources: Int
        var returnedToBaseline: Bool { workRemaining == 0 && retainedResources == 0 }
    }
    private final class Entry {
        let owner: Owner?
        var subsystem: Subsystem
        var retention: Retention
        weak var handle: FileHandle?
        let observesHandle: Bool
        init(owner: Owner?, subsystem: Subsystem, retention: Retention, handle: FileHandle? = nil) {
            self.owner = owner; self.subsystem = subsystem; self.retention = retention
            self.handle = handle; observesHandle = handle != nil
        }
    }
    /// Raw descriptors use a ticket paired with their actual close operation.
    /// Tickets never close descriptors or extend resource ownership.
    final class Ticket: @unchecked Sendable {
        private let registry: BackendDescriptors
        private let id: UUID
        fileprivate init(_ registry: BackendDescriptors, _ id: UUID) { self.registry = registry; self.id = id }
        func finish() { registry.remove(id) }
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var drainChecks = 0
    private var drainsWithOutstandingWork = 0

    func opened(_ subsystem: Subsystem, owner: Owner? = TaskOwnership.current?.descriptorOwner,
                retention: Retention = .work) -> Ticket {
        lock.withLock {
            reapHandles()
            let id = UUID(); entries[id] = Entry(owner: owner, subsystem: subsystem, retention: retention)
            return Ticket(self, id)
        }
    }
    /// FileHandle owns closure. Observe it weakly so accounting cannot keep a
    /// pipe open. Re-registration (writer borrowing a pipe) changes its category,
    /// never counts the same handle twice or adopts another owner's handle.
    func track(_ handle: FileHandle, subsystem: Subsystem,
               owner: Owner? = TaskOwnership.current?.descriptorOwner, retention: Retention = .work) {
        lock.withLock {
            reapHandles()
            guard Self.isOpen(handle) else { return }
            if let entry = entries.values.first(where: { $0.handle === handle }) {
                if entry.owner === owner { entry.subsystem = subsystem; entry.retention = retention }
                return
            }
            entries[UUID()] = Entry(owner: owner, subsystem: subsystem, retention: retention, handle: handle)
        }
    }
    private static func isOpen(_ handle: FileHandle) -> Bool {
        tp_file_handle_descriptor(Unmanaged.passUnretained(handle).toOpaque()) >= 0
    }
    private func reapHandles() {
        entries = entries.filter { _, entry in
            !entry.observesHandle || (entry.handle.map { Self.isOpen($0) } ?? false)
        }
    }
    private func remove(_ id: UUID) { lock.withLock { _ = entries.removeValue(forKey: id) } }
    func transition(_ owner: Owner, to lifecycle: Lifecycle) {
        lock.withLock {
            if owner.lifecycle != .retired { owner.lifecycle = lifecycle }
            reapHandles()
        }
    }
    func snapshot(owner: Owner? = nil) -> [Counts] {
        lock.withLock {
            reapHandles()
            return Subsystem.allCases.flatMap { subsystem in
                Lifecycle.allCases.map { lifecycle in
                    var counts = Counts(subsystem: subsystem, lifecycle: lifecycle)
                    for entry in entries.values where entry.subsystem == subsystem &&
                        (entry.owner?.lifecycle ?? .active) == lifecycle && (owner == nil || entry.owner === owner) {
                        counts.open += 1
                        if entry.owner == nil { counts.unowned += 1 }
                        if entry.retention == .retainedResource { counts.retained += 1 }
                    }
                    return counts
                }
            }
        }
    }
    @discardableResult func checkDrain(_ owner: Owner) -> DrainReport {
        lock.withLock {
            reapHandles()
            let owned = entries.values.filter { $0.owner === owner }
            let retained = owned.filter { $0.retention == .retainedResource }.count
            let report = DrainReport(workRemaining: owned.count - retained, retainedResources: retained)
            // Retirement can be requested more than once; count one check/run.
            if owner.lastDrain == nil {
                drainChecks += 1
                if report.workRemaining > 0 { drainsWithOutstandingWork += 1 }
            }
            owner.lastDrain = report
            return report
        }
    }
    var drainStatistics: (checks: Int, outstandingWork: Int) {
        lock.withLock { (drainChecks, drainsWithOutstandingWork) }
    }
}
