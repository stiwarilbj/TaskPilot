import Foundation

/// Background cache eviction and admission hints only: never actions or UI.
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
    private var pressureHandlers: [UUID: (DispatchSource.MemoryPressureEvent, UInt64) -> Void] = [:]
    private var pressure: DispatchSource.MemoryPressureEvent = .normal
    private var pressureRevision: UInt64 = 0
    private var source: DispatchSourceMemoryPressure?

    init(listen: Bool = true) {
        guard listen else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
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
    /// Capture the latest level atomically. Revisions let consumers reject an
    /// older callback racing a new notification. Never call an owner under the
    /// monitor lock: releasing its last reference can remove its registration.
    func registerPressure(_ handler: @escaping (DispatchSource.MemoryPressureEvent, UInt64) -> Void) -> Registration {
        let id = UUID()
        let state = lock.withLock { pressureHandlers[id] = handler; return (pressure, pressureRevision) }
        handler(state.0, state.1)
        return Registration(self, id)
    }
    private func remove(_ id: UUID) {
        lock.withLock { handlers.removeValue(forKey: id); pressureHandlers.removeValue(forKey: id) }
    }

    // Synthetic flags let tests exercise eviction without pressuring macOS.
    func receive(_ flags: DispatchSource.MemoryPressureEvent) {
        guard !flags.intersection([.normal, .warning, .critical]).isEmpty else { return }
        let state = lock.withLock {
            pressure = flags
            pressureRevision &+= 1
            return (Array(pressureHandlers.values), pressureRevision,
                    flags.intersection([.warning, .critical]).isEmpty ? [] : Array(handlers.values))
        }
        for callback in state.0 { callback(flags, state.1) }
        for callback in state.2 { callback() }
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
