import Foundation

/// One immutable capability for a task. Revocation is serialized with native
/// commits; cancellation is only a wake-up mechanism, never authorization.
final class TaskLease: @unchecked Sendable {
    enum State { case running, paused, draining, retired }
    let id: String
    private let lock = NSRecursiveLock()
    private var value: State = .running
    private var discarded = 0
    private var artifacts: Set<URL> = []
    init(id: String = UUID().uuidString) { self.id = id }
    var state: State { lock.lock(); defer { lock.unlock() }; return value }
    var staleWorkCount: Int { lock.lock(); defer { lock.unlock() }; return discarded }
    func pause() { lock.lock(); defer { lock.unlock() }; if value == .running { value = .paused } }
    func resume() { lock.lock(); defer { lock.unlock() }; if value == .paused { value = .running } }
    func revoke() { lock.lock(); defer { lock.unlock() }; if value != .retired { value = .draining } }
    func ownArtifact(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard value == .running || value == .paused else { try? FileManager.default.removeItem(at: url); throw CancellationError() }
        artifacts.insert(url)
    }
    func retire() {
        lock.lock(); value = .retired; let files = artifacts; artifacts.removeAll(); lock.unlock()
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
    static func check() throws { try current?.check(); try Task.checkCancellation() }
    static func checkpoint() async throws { try await current?.checkpoint(); try Task.checkCancellation() }
    static func commit<T>(_ operation: () throws -> T) throws -> T {
        if let current { return try current.commit(operation) }
        return try operation() // Explicit user/manual and teardown paths.
    }
    static func permitted<T>(_ fallback: T, _ operation: () -> T) -> T {
        (try? commit(operation)) ?? fallback
    }
    static func callback(_ lease: TaskLease?, _ operation: () -> Void) {
        if let lease { _ = try? lease.commit { $current.withValue(lease, operation: operation) } } else { operation() }
    }
}
