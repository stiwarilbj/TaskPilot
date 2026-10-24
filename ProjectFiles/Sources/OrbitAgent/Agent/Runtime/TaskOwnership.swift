import Foundation

/// One immutable capability for a task. Revocation is serialized with native
/// commits; cancellation is only a wake-up mechanism, never authorization.
final class TaskLease: @unchecked Sendable {
    enum State { case running, paused, draining, retired }
    let id: String
    let actionReceipts: ActionReceiptStore
    private let lock = NSRecursiveLock()
    private var value: State = .running
    private var discarded = 0
    private var suspensions = 0
    private var artifacts: Set<URL> = []
    private var screenText: (revision: String, suspension: Int, snapshot: ScreenTextSnapshot)?
    private var revocationObservers: [UUID: @Sendable () -> Void] = [:]
    private var pauseWaiters: [UUID: @Sendable () -> Void] = [:]
    private var pauseRegistrations = 0
    private var instructionRevision: UInt64 = 0
    private var pendingCorrection: (id: String, revision: UInt64)?
    private var appliedCorrections: [String: UInt64] = [:]
    private var completionClaimed = false
    let permitsPersistentProcesses: Bool
    private var closePersistentProcesses: Bool
    private var persistentProcesses: [SubprocessSupervisor] = []
    private var processCleanupStarted = false
    init(id: String = UUID().uuidString, taskRequest: String = "", closePersistentProcesses: Bool = true,
         recoveryJournal: ActionRecoveryJournal? = nil, recoveryTask: UUID? = nil) {
        self.id = id; self.actionReceipts = ActionReceiptStore(generation: id, journal: recoveryJournal, recoveryTask: recoveryTask)
        self.closePersistentProcesses = closePersistentProcesses
        // Conservative authorization from the original user request, never a
        // model response or command's background operator alone.
        let text = taskRequest.lowercased()
        permitsPersistentProcesses = text.range(of: "do not|don't|never|^(explain|describe|how|what|show me how)\\b", options: .regularExpression) == nil &&
            text.range(of: #"\b(start|launch|run)\b[^.!?\n]*\b(in (the )?background|background service)\b|\bkeep\b[^.!?\n]*\b(server|service|process)\b[^.!?\n]*\b(running|alive)\b|\b(start|launch|run)\b[^.!?\n]*\b(server|service)\b[^.!?\n]*\bkeep (it )?running\b"#, options: .regularExpression) != nil
    }
    func setProcessCleanup(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !processCleanupStarted { closePersistentProcesses = enabled }
    }
    func ownPersistentProcess(_ process: SubprocessSupervisor) throws {
        try commit {
            guard permitsPersistentProcesses, !processCleanupStarted else { throw CancellationError() }
            persistentProcesses.append(process)
        }
    }
    /// Called before task handoff; retained services are exempt only from the
    /// cleanup the user disabled, never accidentally forgotten at shell exit.
    func drainPersistentProcesses() -> Bool {
        lock.lock()
        let processes = persistentProcesses
        let close = closePersistentProcesses
        let start = !processCleanupStarted; processCleanupStarted = true
        if !close { persistentProcesses.removeAll() }
        lock.unlock()
        if start {
            for process in processes {
                if close { process.beginTeardown() }
                else { PersistentProcessResources.shared.retain(process) }
            }
        }
        return !close || processes.allSatisfy { $0.snapshot.treeFinished }
    }
    var state: State { lock.lock(); defer { lock.unlock() }; return value }
    var staleWorkCount: Int { lock.lock(); defer { lock.unlock() }; return discarded }
    var suspensionRevision: Int { lock.lock(); defer { lock.unlock() }; return suspensions }
    // Private counts also let offline tests distinguish parking from polling.
    var pauseWaiterCount: Int { lock.lock(); defer { lock.unlock() }; return pauseWaiters.count }
    var pauseWaitRegistrationCount: Int { lock.lock(); defer { lock.unlock() }; return pauseRegistrations }
    var currentInstructionRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return instructionRevision }
    var hasPendingInstructionCorrection: Bool { lock.lock(); defer { lock.unlock() }; return pendingCorrection != nil }

    func beginInstructionCorrection(id: String, revision: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard (value == .running || value == .paused), pendingCorrection == nil,
              !completionClaimed, revision == instructionRevision + 1, UUID(uuidString: id) != nil else {
            throw TaskInstructionCorrectionError.stale
        }
        pendingCorrection = (id.lowercased(), revision)
    }

    func cancelInstructionCorrection(id: String) {
        lock.lock(); defer { lock.unlock() }
        guard pendingCorrection?.id == id.lowercased() else { return }
        pendingCorrection = nil
    }

    func applyInstructionCorrection(id: String, revision: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        let normalizedID = id.lowercased()
        if appliedCorrections[normalizedID] == revision { return }
        guard (value == .running || value == .paused),
              pendingCorrection?.id == normalizedID, pendingCorrection?.revision == revision,
              revision == instructionRevision + 1 else { throw TaskInstructionCorrectionError.stale }
        instructionRevision = revision
        pendingCorrection = nil
        appliedCorrections[normalizedID] = revision
    }

    func validateInstructionRevision(_ revision: UInt64, allowDispatchedReceipt: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard value == .running || value == .paused else { throw CancellationError() }
        if completionClaimed && !(allowDispatchedReceipt && revision == instructionRevision) {
            throw TaskInstructionCorrectionError.superseded
        }
        // Once an operation crossed the dispatched receipt boundary it owns
        // its original revision through terminal reconciliation, even after
        // the correction has been acknowledged and the barrier is lifted.
        if allowDispatchedReceipt, revision <= instructionRevision { return }
        guard pendingCorrection == nil, revision == instructionRevision else {
            throw TaskInstructionCorrectionError.superseded
        }
    }

    func claimCompletion(instructionRevision revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if completionClaimed { return revision == instructionRevision }
        guard (value == .running || value == .paused), pendingCorrection == nil,
              revision == instructionRevision, !completionClaimed else { return false }
        completionClaimed = true
        return true
    }

    /// Completion and correction acceptance share one lock. Returning the
    /// pending state from this same critical section prevents a rollback from
    /// being mistaken for a permanently rejected completion.
    func claimCompletionGate(instructionRevision revision: UInt64) -> (accepted: Bool, pendingCorrection: Bool) {
        lock.lock(); defer { lock.unlock() }
        if completionClaimed { return (revision == instructionRevision, false) }
        guard value == .running || value == .paused else { return (false, false) }
        if pendingCorrection != nil { return (false, true) }
        guard revision == instructionRevision else { return (false, false) }
        completionClaimed = true
        return (true, false)
    }
    func pause() { lock.lock(); defer { lock.unlock() }; if value == .running { value = .paused; suspensions += 1 } }
    func resume() {
        lock.lock()
        guard value == .paused else { lock.unlock(); return }
        value = .running
        let waiters = Array(pauseWaiters.values); pauseWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter() }
    }
    func revoke() {
        lock.lock()
        if value != .retired { value = .draining }
        let observers = Array(revocationObservers.values); revocationObservers.removeAll()
        let waiters = Array(pauseWaiters.values); pauseWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter() }
        for observer in observers { observer() }
    }
    func observeRevocation(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        let revoked = value == .draining || value == .retired
        if !revoked { revocationObservers[token] = observer }
        lock.unlock()
        if revoked { observer() }
        return token
    }
    func removeRevocationObserver(_ token: UUID) {
        lock.lock(); revocationObservers.removeValue(forKey: token); lock.unlock()
    }
    func ownArtifact(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard value == .running || value == .paused else { try? FileManager.default.removeItem(at: url); throw CancellationError() }
        artifacts.insert(url)
    }
    func discardArtifact(_ url: URL) {
        lock.lock(); artifacts.remove(url); lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }
    func bindScreenText(_ snapshot: ScreenTextSnapshot?, revision: String = "") throws {
        try commit { screenText = snapshot.map { (revision, suspensions, $0) } }
    }
    func screenTextSnapshot(revision: String) throws -> ScreenTextSnapshot? {
        lock.lock(); defer { lock.unlock() }
        try check()
        guard screenText?.revision == revision else { return nil }
        guard screenText?.suspension == suspensions else { throw AccessibilityActionError.staleObservation }
        return screenText?.snapshot
    }
    func retire() {
        lock.lock(); value = .retired; let files = artifacts; artifacts.removeAll(); screenText = nil
        let observers = Array(revocationObservers.values); revocationObservers.removeAll()
        let waiters = Array(pauseWaiters.values); pauseWaiters.removeAll(); lock.unlock()
        for waiter in waiters { waiter() }
        for observer in observers { observer() }
        _ = drainPersistentProcesses()
        lock.lock(); persistentProcesses.removeAll(); lock.unlock()
        actionReceipts.discard()
        for url in files { try? FileManager.default.removeItem(at: url) }
    }
    func accepts(_ id: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let allowed = id == self.id && (value == .running || value == .paused)
        if !allowed { discarded += 1 }
        return allowed
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard value == .running || value == .paused else { throw CancellationError() }
    }
    func checkpoint() async throws {
        while state == .paused {
            try Task.checkCancellation()
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    // Registration and state changes share the ownership lock.
                    // Cancellation before registration must not strand a wait.
                    if value == .paused, !Task.isCancelled {
                        pauseWaiters[id] = { continuation.resume() }
                        pauseRegistrations += 1
                        lock.unlock()
                    } else {
                        lock.unlock(); continuation.resume()
                    }
                }
            } onCancel: { self.wakePauseWaiter(id) }
        }
        try check(); try Task.checkCancellation()
    }

    private func wakePauseWaiter(_ id: UUID) {
        lock.lock(); let waiter = pauseWaiters.removeValue(forKey: id); lock.unlock()
        waiter?()
    }

    /// Async entry points install a cancellation handler for synchronous native
    /// commits. Waking a wait never grants authority: every worker rechecks its
    /// own cancellation and the lease under the commit lock.
    func wakePausedWorkers() {
        lock.lock(); let waiters = Array(pauseWaiters.values); pauseWaiters.removeAll(); lock.unlock()
        for waiter in waiters { waiter() }
    }

    func commit<T>(_ operation: () throws -> T) throws -> T {
        // Native workers may wait through Pause; never block the main run loop.
        while true {
            try Task.checkCancellation()
            lock.lock()
            if value == .paused, !Thread.isMainThread {
                if Task.isCancelled { lock.unlock(); throw CancellationError() }
                let wake = DispatchSemaphore(value: 0)
                pauseWaiters[UUID()] = { wake.signal() }
                pauseRegistrations += 1
                lock.unlock()
                wake.wait()
                continue
            }
            defer { lock.unlock() }
            guard value == .running else { discarded += 1; throw CancellationError() }
            try Task.checkCancellation()
            return try operation()
        }
    }
}

enum TaskOwnership {
    @TaskLocal static var current: TaskLease?
    @TaskLocal static var actionReceipt: ActionReceiptStore.Token?
    @TaskLocal static var instructionRevision: UInt64?
    static func check() throws { try current?.check(); try LocalOperationBudget.check(); try Task.checkCancellation() }
    static func checkpoint() async throws {
        try LocalOperationBudget.check(); try await current?.checkpoint(); try LocalOperationBudget.check()
    }
    static func withCancellationWakeup<T>(_ operation: () async throws -> T) async rethrows -> T {
        let lease = current
        return try await withTaskCancellationHandler(operation: operation, onCancel: { lease?.wakePausedWorkers() })
    }
    static func commit<T>(_ operation: () throws -> T) throws -> T {
        if let current {
            return try current.commit {
                try LocalOperationBudget.check()
                if let actionReceipt {
                    guard actionReceipt.generation == current.id else { throw CancellationError() }
                    if let revision = instructionRevision {
                        try current.validateInstructionRevision(revision,
                            allowDispatchedReceipt: actionReceipt.receipt["state"] as? String == "dispatched")
                    }
                    // Receipt dispatch and delivery share the lease's atomic
                    // boundary. Failed delivery after this point is uncertain.
                    try actionReceipt.dispatched()
                }
                return try operation()
            }
        }
        try LocalOperationBudget.check()
        return try operation() // Explicit user/manual and teardown paths.
    }
    static func permitted<T>(_ fallback: T, _ operation: () -> T) -> T {
        (try? commit(operation)) ?? fallback
    }
    static func callback(_ lease: TaskLease?, _ operation: () -> Void) {
        if let lease { _ = try? lease.commit { $current.withValue(lease, operation: operation) } } else { operation() }
    }
}

enum TaskInstructionCorrectionError: LocalizedError {
    case stale
    case superseded
    var errorDescription: String? {
        switch self {
        case .stale: "This correction is no longer current."
        case .superseded: "This action was planned before the latest instruction update."
        }
    }
}

/// A local operation owns one monotonic allowance. Child bounds may shorten it,
/// never renew it. Expiry revokes additional work, not already-delivered effects.
final class LocalOperationBudget: @unchecked Sendable {
    struct Exhausted: LocalizedError {
        let phase: String
        var errorDescription: String? { "The local operation budget was consumed during \(phase); any delivered effect still requires reconciliation" }
    }
    @TaskLocal static var current: LocalOperationBudget?
    let deadline: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var phase: String
    init(seconds: TimeInterval, phase: String, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now; self.deadline = now() + max(0, seconds); self.phase = phase
    }
    var remaining: TimeInterval { max(0, deadline - now()) }
    func check(phase next: String? = nil) throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard now() < deadline else { throw Exhausted(phase: phase) }
            if let next { phase = next }
        }
    }
    static func check(_ phase: String? = nil) throws { try current?.check(phase: phase); try Task.checkCancellation() }
    static func allowance(_ seconds: TimeInterval) -> TimeInterval { min(max(0, seconds), current?.remaining ?? max(0, seconds)) }
    static func sleep(_ seconds: TimeInterval, phase: String) async throws {
        try TaskOwnership.check(); try check(phase)
        try await Task.sleep(for: .seconds(allowance(seconds)))
        try TaskOwnership.check()
    }
    /// Queue waits are cancellable. In-flight native work must still drain;
    /// this timer never releases its slot or declares a mutation unsuccessful.
    static func bounded<T: Sendable>(phase: String, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let budget = current else { return try await operation() }
        try budget.check(phase: phase)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(budget.remaining))
                try budget.check()
                throw Exhausted(phase: phase)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
