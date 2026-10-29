import Darwin
import Foundation

/// One invocation owns its pipes, queue and lazy spill files. Readers keep
/// draining after retention limits or a storage error; neither stream can
/// block the child while the owning worker handles exit or cancellation.
final class BufferedProcessOutput: @unchecked Sendable {
    static let memoryLimit = 32_768
    // Bound bytes AND syscalls: short reads or repeated EINTR must also yield.
    struct DrainBudget {
        static let byteLimit = 65_536
        static let readLimit = 16
        private(set) var bytes = 0
        private(set) var reads = 0
        var nextReadSize: Int { reads < Self.readLimit ? min(16_384, Self.byteLimit - bytes) : 0 }
        mutating func record(_ count: Int) { reads += 1; bytes += max(0, count) }
    }
    private enum DrainResult { case yielded, idle, closed }

    struct StreamResult {
        let data: Data
        let truncated: Bool
        var text: String {
            guard truncated else { return String(decoding: data, as: UTF8.self) }
            let completeLength = Self.completeUTF8PrefixLength(data)
            return String(decoding: data.prefix(completeLength), as: UTF8.self)
        }

        /// The byte cap can stop in the middle of a valid UTF-8 scalar. Keep
        /// the retained bytes intact for raw consumers, but omit only that
        /// incomplete final scalar from the text projection.
        private static func completeUTF8PrefixLength(_ data: Data) -> Int {
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let count = bytes.count
                guard count > 0, let base = bytes.baseAddress else { return count }

                var start = count - 1
                while start >= 0, base[start] & 0xC0 == 0x80 { start -= 1 }
                guard start >= 0 else { return count }

                let lead = base[start]
                let expectedLength: Int
                switch lead {
                case 0xC2...0xDF: expectedLength = 2
                case 0xE0...0xEF: expectedLength = 3
                case 0xF0...0xF4: expectedLength = 4
                default: return count
                }

                let presentLength = count - start
                guard presentLength < expectedLength else { return count }
                if presentLength > 1 {
                    let second = base[start + 1]
                    // Reject impossible partial encodings (overlong forms,
                    // surrogate scalars, and values beyond U+10FFFF) rather
                    // than disguising malformed output as a truncation edge.
                    switch lead {
                    case 0xE0 where second < 0xA0,
                         0xED where second > 0x9F,
                         0xF0 where second < 0x90,
                         0xF4 where second > 0x8F:
                        return count
                    default:
                        break
                    }
                }
                return start
            }
        }
    }
    struct Result { let stdout: StreamResult; let stderr: StreamResult }
    struct Statistics {
        let drainedBytes: UInt64
        let stdoutDrainedBytes: UInt64
        let stderrDrainedBytes: UInt64
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
        let pipe: Pipe
        var source: DispatchSourceRead?
        var memory = Data()
        var spill: FileHandle?
        var retained = 0
        var drained: UInt64 = 0
        var eof = false
        init() throws { pipe = try SubprocessSupervisor.makePrivatePipe(subsystem: .commandOutput) }
    }

    private let descriptorOwner = TaskOwnership.current?.descriptorOwner
    private let queue = DispatchQueue(label: "com.orbitagent.buffered-process-output", qos: .utility)
    private let cancellations = DispatchGroup()
    private let streams: [Stream]
    private let maximumBytes: Int?
    private let combinedLimit: UInt64?
    private let memoryThreshold: Int
    private let spillRoot: URL
    private let spillReadback: (FileHandle) throws -> Data
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
    private var nextStream = 0

    init(maximumBytes: Int? = nil, combinedLimit: Int? = nil, merged: Bool = false,
         memoryThreshold: Int = BufferedProcessOutput.memoryLimit,
         spillRoot: URL = FileManager.default.temporaryDirectory,
         spillReadback: @escaping (FileHandle) throws -> Data = { handle in
             try handle.seek(toOffset: 0)
             return try handle.readToEnd() ?? Data()
         },
         onInterruption: @escaping @Sendable () -> Void = {}) throws {
        precondition(memoryThreshold >= 0 && maximumBytes.map { $0 >= 0 } != false && combinedLimit.map { $0 >= 0 } != false)
        self.maximumBytes = maximumBytes
        self.combinedLimit = combinedLimit.map(UInt64.init)
        self.memoryThreshold = memoryThreshold
        self.spillRoot = spillRoot
        self.spillReadback = spillReadback
        self.onInterruption = onInterruption
        streams = try (0..<(merged ? 1 : 2)).map { _ in try Stream() }
        do {
            for stream in streams {
                let handle = stream.pipe.fileHandleForReading
                let descriptor = handle.fileDescriptor
                let flags = Darwin.fcntl(descriptor, F_GETFL)
                guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CaptureError.read }
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                stream.source = source
                source.setEventHandler { [weak self, weak stream] in
                    guard let self, let stream, !self.stopped, !stream.eof else { return }
                    // Service both streams even if only stdout's source fires.
                    // Read sources remain armed and re-enqueue unread data after
                    // this bounded round returns to the serial queue.
                    self.drainRound()
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
            Statistics(drainedBytes: drainedBytes, stdoutDrainedBytes: streams[0].drained,
                stderrDrainedBytes: streams.count == 1 ? 0 : streams[1].drained, retainedBytes: streams.reduce(0) { $0 + $1.retained },
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

    @discardableResult
    private func drainRound() -> Bool {
        var yielded = false
        let first = nextStream
        nextStream = (first + 1) % streams.count
        for offset in streams.indices {
            if case .yielded = drain(streams[(first + offset) % streams.count]) { yielded = true }
        }
        return yielded
    }

    private func drain(_ stream: Stream) -> DrainResult {
        guard !stream.eof else { return .closed }
        var budget = DrainBudget()
        while budget.nextReadSize > 0 {
            let count = scratch.withUnsafeMutableBytes {
                Darwin.read(stream.pipe.fileHandleForReading.fileDescriptor, $0.baseAddress, budget.nextReadSize)
            }
            budget.record(count)
            if count == 0 { stream.eof = true; stream.source?.cancel(); return .closed }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return .idle }
                failure = .read; stream.eof = true; stream.source?.cancel(); interrupt(); return .closed
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
        return .yielded
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
        let handle = try FileHandle(forUpdating: path)
        BackendDescriptors.shared.track(handle, subsystem: .commandOutput, owner: descriptorOwner)
        return handle
    }

    /// Called only after the process has exited. Drain remaining readable
    /// bytes before retiring readers. Inherited writers cannot strand teardown;
    /// an unclosed stream is marked incomplete, never exact-output proof.
    func finish(keepDraining: Bool = false) throws -> Result {
        closeWriters()
        // Each barrier is one fair round, allowing queued reads and cleanup
        // between rounds. Normally the owned tree has closed both writers;
        // continue through EOF rather than truncating at a single turn. Keep
        // the abnormal inherited-writer path bounded (at most 1 MiB per stream)
        // and visibly incomplete; persistent services keep their readers armed.
        for _ in 0..<16 {
            let yielded = queue.sync { !stopped && drainRound() }
            if !yielded { break }
        }
        queue.sync {
            guard !stopped else { return }
            if keepDraining {
                discardFurtherOutput = true
                for stream in streams {
                    BackendDescriptors.shared.track(stream.pipe.fileHandleForReading, subsystem: .commandOutput,
                                                     owner: descriptorOwner, retention: .retainedResource)
                    if let spill = stream.spill {
                        BackendDescriptors.shared.track(spill, subsystem: .commandOutput,
                                                         owner: descriptorOwner, retention: .retainedResource)
                    }
                }
            }
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
                        // The producer has exited and this same open handle
                        // owns every completed write. Readback needs visible
                        // writes, not a durable flush for a disposable buffer.
                        bytes = try spillReadback(spill)
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
