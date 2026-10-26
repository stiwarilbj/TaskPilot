import Darwin
import Foundation

/// Confined to the invocation's I/O queue. No pipe write can block Stop.
final class RuntimePipeWriter {
    private struct Frame {
        let data: Data
        var offset = 0
        let completion: (Bool) -> Void
        let waitTicket: BackendTelemetry.QueueTicket
    }
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let failure: (String) -> Void
    private let telemetry: BackendTelemetry
    private var frames: [Frame] = []
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
         reserve: Int = 8 * 1024 * 1024, timeout: TimeInterval = 5, telemetry: BackendTelemetry = .current,
         failure: @escaping (String) -> Void) {
        descriptor = handle.fileDescriptor; self.queue = queue; self.failure = failure; self.telemetry = telemetry
        self.byteLimit = byteLimit; self.reserve = reserve; self.timeout = timeout
        let flags = fcntl(descriptor, F_GETFL)
        // Darwin.write otherwise raises SIGPIPE before it can return EPIPE.
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            closed = true; failure("transport_configuration"); return
        }
    }

    func enqueue(_ data: Data, priority: Bool = false, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !data.isEmpty else { completion(!closed); return }
        let waitTicket = telemetry.beginQueueWait(.pipeFirstWrite)
        guard !closed else { waitTicket.discard(.rejected); completion(false); return }
        guard data.count <= RuntimeLineBuffer.maximumFrameBytes + 1 else {
            waitTicket.discard(.rejected)
            completion(false); fail("transport_frame_limit"); return
        }
        guard bytes + data.count <= byteLimit - (priority ? 0 : reserve), pendingFrameCount < (priority ? 1056 : 1024) else {
            waitTicket.discard(.rejected)
            completion(false); fail("transport_buffer_limit"); return
        }
        frames.append(Frame(data: data, completion: completion, waitTicket: waitTicket)); bytes += data.count
        if source == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.pump() }
            self.source = source; source.resume()
            armDeadline()
        }
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
        while frameHead < frames.count && allowance > 0 && !closed {
            frames[frameHead].waitTicket.start()
            let written = frames[frameHead].data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: frames[frameHead].offset),
                             min(allowance, buffer.count - frames[frameHead].offset))
            }
            if written < 0 {
                if errno == EAGAIN || errno == EINTR { return }
                fail("transport_closed"); return
            }
            guard written > 0 else { return }
            frames[frameHead].offset += written; allowance -= written
            if frames[frameHead].offset == frames[frameHead].data.count {
                let frame = frames[frameHead]
                frameHead += 1
                bytes -= frame.data.count
                compactConsumedPrefixIfNeeded()
                frame.completion(true)
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
        let pending = Array(frames[frameHead...])
        frames.removeAll(keepingCapacity: true); frameHead = 0; bytes = 0
        for frame in pending {
            frame.waitTicket.discard(.cancelled)
            frame.completion(false)
        }
    }

    private func fail(_ code: String) { cancel(); failure(code) }
    deinit { source?.cancel(); deadline?.cancel() }
}
