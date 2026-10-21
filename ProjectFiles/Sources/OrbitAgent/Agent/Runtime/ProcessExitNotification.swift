import Foundation

/// One process invocation owns this signal. Install it before launch so even
/// immediate exits are retained; callbacks never reach another invocation.
final class ProcessExitNotification: @unchecked Sendable {
    enum Result { case exited(Int32), interrupted, timedOut }
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private let ended = DispatchSemaphore(value: 0)
    private var status: Int32?
    private var interrupted = false

    init(_ process: Process) {
        process.terminationHandler = { [self] in record($0.terminationStatus) }
    }
    init(_ process: SubprocessSupervisor) {
        process.terminationHandler = { [self] in record($0.terminationStatus) }
    }
    private func record(_ code: Int32) {
        lock.lock()
        guard status == nil else { lock.unlock(); return }
        status = code
        lock.unlock()
        ended.signal(); changed.signal()
    }

    /// Cancellation and output-limit notifications wake the owning worker.
    /// Signal delivery and cleanup stay in that worker, outside this callback.
    func interrupt() {
        lock.lock()
        let wake = !interrupted
        if wake { interrupted = true }
        lock.unlock()
        if wake { changed.signal() }
    }

    private var result: Result? {
        lock.withLock {
            if let status { return .exited(status) }
            return interrupted ? .interrupted : nil
        }
    }

    func wait(until deadline: DispatchTime) -> Result {
        if let result { return result }
        _ = changed.wait(timeout: deadline)
        // Recheck after the deadline as well: an exit racing it must not be
        // mistaken for silence. Each waiter has exactly one owning worker.
        return result ?? .timedOut
    }

    /// Shutdown ignores interrupts and waits for the actual exit callback.
    func waitForExit(until deadline: DispatchTime = .distantFuture) -> Int32? {
        if let status = lock.withLock({ status }) { return status }
        guard ended.wait(timeout: deadline) == .success else { return nil }
        return lock.withLock { status }
    }
}
