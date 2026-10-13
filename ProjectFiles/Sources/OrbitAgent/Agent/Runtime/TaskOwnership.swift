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
    init(id: String = UUID().uuidString) {
        self.id = id; self.actionReceipts = ActionReceiptStore(generation: id)
    }
    var state: State { lock.lock(); defer { lock.unlock() }; return value }
    var staleWorkCount: Int { lock.lock(); defer { lock.unlock() }; return discarded }
    var suspensionRevision: Int { lock.lock(); defer { lock.unlock() }; return suspensions }
    func pause() { lock.lock(); defer { lock.unlock() }; if value == .running { value = .paused; suspensions += 1 } }
    func resume() { lock.lock(); defer { lock.unlock() }; if value == .paused { value = .running } }
    func revoke() {
        lock.lock()
        if value != .retired { value = .draining }
        let observers = Array(revocationObservers.values); revocationObservers.removeAll()
        lock.unlock()
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
        let observers = Array(revocationObservers.values); revocationObservers.removeAll(); lock.unlock()
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
        guard state == .running || state == .paused else { throw CancellationError() }
    }
    func checkpoint() async throws {
        while state == .paused { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(25)) }
        try check(); try Task.checkCancellation()
    }
    func commit<T>(_ operation: () throws -> T) throws -> T {
        // Native workers may wait through Pause; never block the main run loop.
        while true {
            try Task.checkCancellation()
            lock.lock()
            if value == .paused, !Thread.isMainThread { lock.unlock(); Thread.sleep(forTimeInterval: 0.025); continue }
            defer { lock.unlock() }
            guard value == .running else { discarded += 1; throw CancellationError() }
            return try operation()
        }
    }
}

enum TaskOwnership {
    @TaskLocal static var current: TaskLease?
    @TaskLocal static var actionReceipt: ActionReceiptStore.Token?
    static func check() throws { try current?.check(); try Task.checkCancellation() }
    static func checkpoint() async throws { try await current?.checkpoint(); try Task.checkCancellation() }
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
