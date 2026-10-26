import Foundation

/// Virtual monotonic time used by lifecycle race tests. Ticks are logical time,
/// not wall-clock sleeps, so a seed recreates the same event ordering.
final class FakeLifecycleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var now: UInt64 { lock.withLock { value } }

    func advance(to tick: UInt64) {
        lock.withLock { value = max(value, tick) }
    }
}

/// Serially runs test events. Equal-tick events are selected with a stable
/// xorshift generator; event bodies may await real lifecycle acknowledgements
/// before the next scheduled race participant is released.
final class SeededLifecycleScheduler: @unchecked Sendable {
    private struct Event {
        let tick: UInt64
        let name: String
        let action: () async -> Void
    }

    let clock = FakeLifecycleClock()
    private let lock = NSLock()
    private var seed: UInt64
    private var events: [Event] = []
    private var executed: [String] = []

    init(seed: UInt64) { self.seed = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    var trace: [String] { lock.withLock { executed } }
    var pendingCount: Int { lock.withLock { events.count } }

    func schedule(at tick: UInt64, name: String, action: @escaping () async -> Void) {
        lock.withLock {
            events.append(Event(tick: tick, name: name, action: action))
        }
    }

    func schedule(after ticks: UInt64, name: String, action: @escaping () async -> Void) {
        schedule(at: clock.now &+ ticks, name: name, action: action)
    }

    @discardableResult
    func runNext() async -> Bool {
        let event = lock.withLock { () -> Event? in
            guard let earliest = events.map(\.tick).min() else { return nil }
            let candidates = events.indices.filter { events[$0].tick == earliest }
            let selected = candidates[Int(nextRandom() % UInt64(candidates.count))]
            let event = events.remove(at: selected)
            executed.append(event.name)
            return event
        }
        guard let event else { return false }
        clock.advance(to: event.tick)
        await event.action()
        return true
    }

    func runAll(limit: Int = 10_000) async {
        for _ in 0..<limit {
            guard await runNext() else { return }
        }
        precondition(pendingCount == 0, "Seeded schedule exceeded its event limit")
    }

    private func nextRandom() -> UInt64 {
        seed ^= seed &<< 13
        seed ^= seed >> 7
        seed ^= seed &<< 17
        return seed
    }
}

/// One-shot async barrier used to hold a seeded schedule until an actual
/// process/runtime/pipe callback has reached its lifecycle boundary.
final class DeterministicAsyncLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !signalled else { return [] }
            signalled = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if signalled { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

func waitForSeededLifecycleCondition(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}
