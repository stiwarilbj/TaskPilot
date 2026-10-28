import Foundation

/// Keep ranks identical to AgentRuntime/lock_order.py.
enum BackendLockCategory: Int, CaseIterable {
    case singleFlight = 10, configuration = 20, installation = 30, state = 40
}

enum BackendLockOrderError: String, LocalizedError {
    case violation = "internal_lock_order"
    var errorDescription: String? { rawValue }
}

/// Synchronous callers share their thread's context. An async operation that
/// retains leases across suspension binds `operation` for its complete lifetime.
final class BackendLockOrder {
    @TaskLocal static var operation: BackendLockOrder?
    private static let threadKey = "com.orbitagent.backend-lock-order"
    static var current: BackendLockOrder {
        if let operation { return operation }
        if let context = Thread.current.threadDictionary[threadKey] as? BackendLockOrder { return context }
        let context = BackendLockOrder()
        Thread.current.threadDictionary[threadKey] = context
        return context
    }

    struct WaitSample {
        let category: BackendLockCategory
        let waitMilliseconds: Double
    }
    private static let samplesLock = NSLock()
    private static var samples: [WaitSample] = []
    static var waitSamples: [WaitSample] { samplesLock.withLock { samples } }
    private static func record(_ category: BackendLockCategory, duration: TimeInterval) {
        samplesLock.withLock {
            if samples.count == 128 { samples.removeFirst() }
            samples.append(WaitSample(category: category,
                waitMilliseconds: duration.isFinite ? max(0, duration) * 1_000 : 0))
        }
    }

    private let lock = NSLock()
    private var held: [UUID: BackendLockCategory] = [:]
    private let clock: () -> TimeInterval
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    func reserve(_ category: BackendLockCategory) throws -> Reservation {
        try lock.withLock {
            guard !held.values.contains(where: { $0.rawValue > category.rawValue }) else {
                throw BackendLockOrderError.violation
            }
            let id = UUID()
            held[id] = category
            return Reservation(context: self, id: id, category: category)
        }
    }

    final class Reservation {
        private let context: BackendLockOrder
        private let id: UUID
        private let category: BackendLockCategory
        fileprivate init(context: BackendLockOrder, id: UUID, category: BackendLockCategory) {
            self.context = context; self.id = id; self.category = category
        }
        func measureWait<T>(_ body: () throws -> T) rethrows -> T {
            let started = context.clock()
            defer { BackendLockOrder.record(category, duration: context.clock() - started) }
            return try body()
        }
        func release() { context.lock.withLock { _ = context.held.removeValue(forKey: id) } }
        deinit { release() }
    }
}
