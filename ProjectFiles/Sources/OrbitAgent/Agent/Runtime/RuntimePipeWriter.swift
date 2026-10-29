import Darwin
import Foundation

/// Confined to the invocation's I/O queue. No pipe write can block Stop.
final class RuntimePipeWriter {
    static let maximumWriteAttemptsPerPump = 64
    typealias WriteOperation = (Int32, UnsafeRawPointer, Int) -> Int

    private struct Frame {
        let data: Data
        var offset = 0
        let completion: (Bool) -> Void
        let waitTicket: BackendTelemetry.QueueTicket
        let budget: LocalOperationBudget?
        let workload: LocalWorkloadGovernor.Reservation
    }
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let failure: (String) -> Void
    private let telemetry: BackendTelemetry
    private let governor: LocalWorkloadGovernor
    // Injectable only so tests can force partial POSIX writes; production uses Darwin.write.
    private let writeOperation: WriteOperation
    // A consumed slot is cleared as soon as its completion callback is taken.
    // The head index still avoids shifting live frames on every write.
    private var frames: [Frame?] = []
    private var frameHead = 0
    private var bytes = 0
    private var source: DispatchSourceWrite?
    private var deadline: DispatchSourceTimer?
    private var closed = false
    private let byteLimit: Int
    private let reserve: Int
    private let timeout: TimeInterval
    var pendingBytes: Int { bytes }
    private var pendingFrameCount: Int { frames.count - frameHead }

    init(handle: FileHandle, queue: DispatchQueue, byteLimit: Int = 32 * 1024 * 1024,
         reserve: Int = 8 * 1024 * 1024, timeout: TimeInterval = 5,
         descriptorOwner: BackendDescriptors.Owner? = TaskOwnership.current?.descriptorOwner, telemetry: BackendTelemetry = .current,
         governor: LocalWorkloadGovernor = .shared,
         writeOperation: @escaping WriteOperation = { descriptor, bytes, count in Darwin.write(descriptor, bytes, count) },
         failure: @escaping (String) -> Void) {
        BackendDescriptors.shared.track(handle, subsystem: .runtimeWritePipe, owner: descriptorOwner)
        descriptor = handle.fileDescriptor; self.queue = queue; self.failure = failure; self.telemetry = telemetry
        self.writeOperation = writeOperation
        self.governor = governor
        self.byteLimit = byteLimit; self.reserve = reserve; self.timeout = timeout
        let flags = fcntl(descriptor, F_GETFL)
        // Darwin.write otherwise raises SIGPIPE before it can return EPIPE.
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            closed = true; failure("transport_configuration"); return
        }
    }

    // Defer payload construction/copying until admission. Task-local budgets
    // must be captured explicitly when crossing a DispatchQueue boundary.
    func enqueue(_ payload: @autoclosure () -> Data, priority: Bool = false,
                 budget: LocalOperationBudget? = LocalOperationBudget.current,
                 completion: @escaping (Bool) -> Void = { _ in }) {
        let waitTicket = telemetry.beginQueueWait(.pipeFirstWrite)
        guard !closed else { waitTicket.discard(.rejected); completion(false); return }
        do { try budget?.check(phase: "pipe_queue") }
        catch { rejectExpired(waitTicket, completion: completion, error: error); return }
        let workload: LocalWorkloadGovernor.Reservation
        do { workload = try governor.reserve(priority ? .terminalIPC : .ipc, budget: budget) }
        catch {
            waitTicket.discard(.rejected); completion(false); fail("transport_local_resource"); return
        }
        var transferred = false
        defer { if !transferred { workload.finish() } }
        let data = payload()
        do { try budget?.check(phase: "pipe_queue") }
        catch { rejectExpired(waitTicket, completion: completion, error: error); return }
        guard !data.isEmpty else { waitTicket.discard(.abandoned); completion(true); return }
        guard data.count <= RuntimeLineBuffer.maximumFrameBytes + 1 else {
            waitTicket.discard(.rejected)
            completion(false); fail("transport_frame_limit"); return
        }
        guard bytes + data.count <= byteLimit - (priority ? 0 : reserve), pendingFrameCount < (priority ? 1056 : 1024) else {
            waitTicket.discard(.rejected)
            completion(false); fail("transport_buffer_limit"); return
        }
        do { try workload.update(.init(memoryBytes: data.count)) }
        catch {
            waitTicket.discard(.rejected); completion(false); fail("transport_local_resource"); return
        }
        frames.append(Frame(data: data, completion: completion, waitTicket: waitTicket, budget: budget, workload: workload))
        transferred = true; bytes += data.count
        if source == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.pump() }
            self.source = source; source.resume()
            armDeadline()
        }
    }

    private func rejectExpired(_ ticket: BackendTelemetry.QueueTicket,
                               completion: (Bool) -> Void, error: Error) {
        ticket.discard(error is CancellationError ? .cancelled : .rejected)
        completion(false)
        failure(error is CancellationError ? "transport_local_cancelled" : "transport_local_deadline")
    }

    private func armDeadline() {
        deadline?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.fail("transport_write_timeout") }
        deadline = timer; timer.resume()
    }

    private func pump() {
        var allowance = 64 * 1024
        var attempts = 0
        while frameHead < frames.count && allowance > 0 && attempts < Self.maximumWriteAttemptsPerPump && !closed {
            // Once any bytes are dispatched, finish the frame under the
            // existing transport timeout. Dropping its suffix corrupts framing
            // and cannot establish that an associated action failed.
            if frames[frameHead]!.offset == 0 {
                do {
                    try frames[frameHead]!.budget?.check(phase: "pipe_queue")
                    try frames[frameHead]!.workload.start()
                }
                catch {
                    let index = frameHead
                    let frameBytes = frames[index]!.data.count
                    let ticket = frames[index]!.waitTicket
                    let completion = frames[index]!.completion
                    frames[index]!.workload.finish()
                    frameHead += 1; bytes -= frameBytes
                    frames[index] = nil
                    compactConsumedPrefixIfNeeded()
                    rejectExpired(ticket, completion: completion, error: error)
                    continue
                }
            }
            frames[frameHead]!.waitTicket.start()
            attempts += 1
            let written = frames[frameHead]!.data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                writeOperation(descriptor, buffer.baseAddress!.advanced(by: frames[frameHead]!.offset),
                               min(allowance, buffer.count - frames[frameHead]!.offset))
            }
            if written < 0 {
                if errno == EAGAIN || errno == EINTR { return }
                fail("transport_closed"); return
            }
            guard written > 0 else { return }
            frames[frameHead]!.offset += written; allowance -= written
            if frames[frameHead]!.offset == frames[frameHead]!.data.count {
                let index = frameHead
                let frameBytes = frames[index]!.data.count
                let completion = frames[index]!.completion
                frames[index]!.workload.finish()
                frameHead += 1
                bytes -= frameBytes
                frames[index] = nil
                compactConsumedPrefixIfNeeded()
                completion(true)
                if pendingFrameCount > 0 { armDeadline() }
            }
        }
        if pendingFrameCount == 0 {
            source?.cancel(); source = nil
            deadline?.cancel(); deadline = nil
        }
    }

    /// Keep steady-state writes O(1); compact only after a meaningful prefix
    /// has been consumed, or reset the head when the queue drains completely.
    private func compactConsumedPrefixIfNeeded() {
        guard frameHead > 0 else { return }
        if frameHead == frames.count {
            frames.removeAll(keepingCapacity: true)
            frameHead = 0
        } else if frameHead >= 64 && frameHead * 2 >= frames.count {
            frames.removeFirst(frameHead)
            frameHead = 0
        }
    }

    func cancel() {
        guard !closed else { return }
        closed = true; source?.cancel(); source = nil; deadline?.cancel(); deadline = nil
        let pending = frames[frameHead...].compactMap { $0 }
        frames.removeAll(keepingCapacity: true); frameHead = 0; bytes = 0
        for frame in pending {
            frame.waitTicket.discard(.cancelled)
            frame.workload.finish()
            frame.completion(false)
        }
    }

    private func fail(_ code: String) { cancel(); failure(code) }
    deinit { source?.cancel(); deadline?.cancel() }
}
