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
    init(id: String = UUID().uuidString) {
        self.id = id; self.actionReceipts = ActionReceiptStore(generation: id)
    }
    var state: State { lock.lock(); defer { lock.unlock() }; return value }
    var staleWorkCount: Int { lock.lock(); defer { lock.unlock() }; return discarded }
    var suspensionRevision: Int { lock.lock(); defer { lock.unlock() }; return suspensions }
    // Private counts also let offline tests distinguish parking from polling.
    var pauseWaiterCount: Int { lock.lock(); defer { lock.unlock() }; return pauseWaiters.count }
    var pauseWaitRegistrationCount: Int { lock.lock(); defer { lock.unlock() }; return pauseRegistrations }
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
    static func check() throws { try current?.check(); try Task.checkCancellation() }
    static func checkpoint() async throws { try await current?.checkpoint(); try Task.checkCancellation() }
    static func withCancellationWakeup<T>(_ operation: () async throws -> T) async rethrows -> T {
        let lease = current
        return try await withTaskCancellationHandler(operation: operation, onCancel: { lease?.wakePausedWorkers() })
    }
    static func commit<T>(_ operation: () throws -> T) throws -> T {
        if let current {
            return try current.commit {
                if let actionReceipt {
                    guard actionReceipt.generation == current.id else { throw CancellationError() }
                    // Receipt dispatch and delivery share the lease's atomic
                    // boundary. Failed delivery after this point is uncertain.
                    try actionReceipt.dispatched()
                }
                return try operation()
            }
        }
        return try operation() // Explicit user/manual and teardown paths.
    }
    static func permitted<T>(_ fallback: T, _ operation: () -> T) -> T {
        (try? commit(operation)) ?? fallback
    }
    static func callback(_ lease: TaskLease?, _ operation: () -> Void) {
        if let lease { _ = try? lease.commit { $current.withValue(lease, operation: operation) } } else { operation() }
    }
}
