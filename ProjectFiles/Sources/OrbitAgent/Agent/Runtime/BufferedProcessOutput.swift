import Darwin
import Foundation

/// One invocation owns its pipes, queue and lazy spill files. Readers keep
/// draining after retention limits or a storage error; neither stream can
/// block the child while the owning worker handles exit or cancellation.
final class BufferedProcessOutput: @unchecked Sendable {
    static let memoryLimit = 32_768
    struct StreamResult {
        let data: Data
        let truncated: Bool
        var text: String { String(decoding: data, as: UTF8.self) }
    }
    struct Result { let stdout: StreamResult; let stderr: StreamResult }
    struct Statistics {
        let drainedBytes: UInt64
        let retainedBytes: Int
        let memoryBytes: Int
        let spillFiles: Int
        let limitExceeded: Bool
    }
    private enum CaptureError: LocalizedError {
        case read, storage, closed
        var errorDescription: String? {
            switch self {
            case .read: return "Command output could not be drained"
            case .storage: return "Command output could not be buffered"
            case .closed: return "Command output capture is closed"
            }
        }
    }
    private final class Stream {
        let pipe = Pipe()
        var source: DispatchSourceRead?
        var memory = Data()
        var spill: FileHandle?
        var retained = 0
        var drained: UInt64 = 0
        var eof = false
    }

    private let queue = DispatchQueue(label: "com.orbitagent.buffered-process-output", qos: .utility)
    private let cancellations = DispatchGroup()
    private let streams: [Stream]
    private let maximumBytes: Int?
    private let combinedLimit: UInt64?
    private let memoryThreshold: Int
    private let spillRoot: URL
    private let onInterruption: @Sendable () -> Void
    private var scratch = [UInt8](repeating: 0, count: 16_384)
    private var directory: URL?
    private var failure: CaptureError?
    private var exceeded = false
    private var notified = false
    private var writersClosed = false
    private var stopped = false
    private var closed = false
    private var discardFurtherOutput = false

    init(maximumBytes: Int? = nil, combinedLimit: Int? = nil, merged: Bool = false,
         memoryThreshold: Int = BufferedProcessOutput.memoryLimit,
         spillRoot: URL = FileManager.default.temporaryDirectory,
         onInterruption: @escaping @Sendable () -> Void = {}) throws {
        precondition(memoryThreshold >= 0 && maximumBytes.map { $0 >= 0 } != false && combinedLimit.map { $0 >= 0 } != false)
        self.maximumBytes = maximumBytes
        self.combinedLimit = combinedLimit.map(UInt64.init)
        self.memoryThreshold = memoryThreshold
        self.spillRoot = spillRoot
        self.onInterruption = onInterruption
        streams = merged ? [Stream()] : [Stream(), Stream()]
        do {
            for stream in streams {
                let handle = stream.pipe.fileHandleForReading
                let descriptor = handle.fileDescriptor
                let flags = Darwin.fcntl(descriptor, F_GETFL)
                guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CaptureError.read }
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                stream.source = source
                source.setEventHandler { [weak self, weak stream] in
                    guard let self, let stream, !self.stopped else { return }
                    self.drain(stream)
                }
                cancellations.enter()
                source.setCancelHandler { [cancellations] in
                    try? handle.close()
                    cancellations.leave()
                }
                source.resume()
            }
        } catch {
            close()
            throw error
        }
    }

    var stdout: FileHandle { streams[0].pipe.fileHandleForWriting }
    var stderr: FileHandle { streams.last!.pipe.fileHandleForWriting }
    var statistics: Statistics {
        queue.sync {
            Statistics(drainedBytes: drainedBytes, retainedBytes: streams.reduce(0) { $0 + $1.retained },
                memoryBytes: streams.reduce(0) { $0 + $1.memory.count },
                spillFiles: streams.filter { $0.spill != nil }.count, limitExceeded: exceeded)
        }
    }
    private var drainedBytes: UInt64 {
        streams.reduce(0) { total, stream in
            let (sum, overflow) = total.addingReportingOverflow(stream.drained)
            return overflow ? UInt64.max : sum
        }
    }

    /// Close the parent's writer copies immediately after launch (also on
    /// launch failure). The child keeps its own descriptors until actual exit.
    func closeWriters() {
        queue.sync {
            guard !writersClosed else { return }
            writersClosed = true
            for stream in streams { try? stream.pipe.fileHandleForWriting.close() }
        }
    }

    private func interrupt() {
        guard !notified else { return }
        notified = true
        onInterruption()
    }

    private func drain(_ stream: Stream) {
        guard !stream.eof else { return }
        // Bounded batches keep a continuously noisy stdout from starving
        // stderr, cancellation or the final queue barrier.
        for _ in 0..<16 {
            let count = scratch.withUnsafeMutableBytes {
                Darwin.read(stream.pipe.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { stream.eof = true; stream.source?.cancel(); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                failure = .read; stream.eof = true; stream.source?.cancel(); interrupt(); return
            }
            let (total, overflow) = stream.drained.addingReportingOverflow(UInt64(count))
            stream.drained = overflow ? UInt64.max : total
            if let combinedLimit, drainedBytes > combinedLimit {
                exceeded = true; interrupt()
            }
            guard failure == nil, !discardFurtherOutput else { continue }
            let keep = maximumBytes.map { min(count, max(0, $0 - stream.retained)) } ?? count
            guard keep > 0 else { continue }
            let data = scratch.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: keep) }
            do {
                if stream.spill == nil, stream.memory.count + data.count > memoryThreshold {
                    stream.spill = try spillFile()
                    try stream.spill!.write(contentsOf: stream.memory)
                    stream.memory = Data()
                }
                if let spill = stream.spill { try spill.write(contentsOf: data) }
                else { stream.memory.append(data) }
                stream.retained += keep
            } catch { failure = .storage; interrupt() }
        }
    }

    private func spillFile() throws -> FileHandle {
        if directory == nil {
            let candidate = spillRoot.appendingPathComponent("taskpilot-output-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            directory = candidate
        }
        let path = directory!.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CaptureError.storage
        }
        return try FileHandle(forUpdating: path)
    }

    /// Called only after the process has exited. Drain remaining readable
    /// bytes before retiring readers. Inherited writers cannot strand teardown;
    /// an unclosed stream is marked incomplete, never exact-output proof.
    func finish(keepDraining: Bool = false) throws -> Result {
        closeWriters()
        queue.sync {
            guard !stopped else { return }
            for stream in streams { drain(stream) }
            if keepDraining { discardFurtherOutput = true }
            else {
                stopped = true
                for stream in streams { stream.source?.cancel() }
            }
        }
        if !keepDraining { cancellations.wait() }
        return try queue.sync {
            guard !closed else { throw CaptureError.closed }
            if let failure { throw failure }
            func result(_ stream: Stream) throws -> StreamResult {
                let bytes: Data
                if let spill = stream.spill {
                    do {
                        try spill.synchronize()
                        try spill.seek(toOffset: 0)
                        bytes = try spill.readToEnd() ?? Data()
                    } catch { throw CaptureError.storage }
                    guard bytes.count == stream.retained else { throw CaptureError.storage }
                } else { bytes = stream.memory }
                return StreamResult(data: bytes, truncated: stream.drained > UInt64(stream.retained) || !stream.eof)
            }
            return Result(stdout: try result(streams[0]),
                          stderr: streams.count == 1 ? StreamResult(data: Data(), truncated: false) : try result(streams[1]))
        }
    }

    /// Caller-owned cleanup is paired with every initialization, including
    /// preflight rejection, startup failure, cancellation and readback errors.
    func close() {
        closeWriters()
        queue.sync {
            stopped = true
            for stream in streams { stream.source?.cancel() }
        }
        cancellations.wait() // No descriptor reuse before its source retires.
        queue.sync {
            guard !closed else { return }
            closed = true
            for stream in streams {
                try? stream.spill?.close(); stream.spill = nil
                try? stream.pipe.fileHandleForReading.close()
                stream.source = nil; stream.memory = Data()
            }
            if let directory { try? FileManager.default.removeItem(at: directory); self.directory = nil }
        }
    }
}
