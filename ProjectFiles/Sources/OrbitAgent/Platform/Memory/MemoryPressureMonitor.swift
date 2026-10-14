import Foundation

/// Background eviction only: registrations must never deliver actions or UI.
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()
    final class Registration {
        private weak var monitor: MemoryPressureMonitor?
        private let id: UUID
        init(_ monitor: MemoryPressureMonitor, _ id: UUID) { self.monitor = monitor; self.id = id }
        deinit { monitor?.remove(id) }
    }
    private let lock = NSLock()
    private var handlers: [UUID: () -> Void] = [:]
    private var source: DispatchSourceMemoryPressure?

    init(listen: Bool = true) {
        guard listen else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
            queue: DispatchQueue(label: "com.orbitagent.memory-pressure", qos: .utility))
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.receive(self.source?.data ?? [])
        }
        source.resume()
    }
    deinit { source?.cancel() }

    func register(_ handler: @escaping () -> Void) -> Registration {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return Registration(self, id)
    }
    private func remove(_ id: UUID) { _ = lock.withLock { handlers.removeValue(forKey: id) } }

    // Synthetic flags let tests exercise eviction without pressuring macOS.
    func receive(_ flags: DispatchSource.MemoryPressureEvent) {
        guard !flags.intersection([.warning, .critical]).isEmpty else { return }
        let callbacks = lock.withLock { Array(handlers.values) }
        for callback in callbacks { callback() }
    }
}

/// Keeps cache eviction independent of an actor's pending asynchronous work.
/// Epoch checks prevent an old build from refilling a cache after eviction.
final class PressureSensitiveCache<Value> {
    private let lock = NSLock()
    private var value: Value?
    private var epoch: UInt64 = 0
    private var registration: MemoryPressureMonitor.Registration?
    init(monitor: MemoryPressureMonitor = .shared) {
        registration = monitor.register { [weak self] in self?.evict() }
    }
    func snapshot() -> (value: Value?, epoch: UInt64) { lock.withLock { (value, epoch) } }
    func store(_ value: Value, epoch: UInt64) {
        lock.withLock { if self.epoch == epoch { self.value = value } }
    }
    func evict() { lock.withLock { epoch &+= 1; value = nil } }
}
