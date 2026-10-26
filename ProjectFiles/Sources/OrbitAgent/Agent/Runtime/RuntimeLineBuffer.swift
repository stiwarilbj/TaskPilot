import Darwin
import Foundation

/// Invocation-local framing for the runtime's newline-delimited byte stream.
/// Offsets are relative to the storage's bytes, including after byte-storage compaction.
struct RuntimeLineBuffer {
    static let compactionThreshold = 64 * 1024
    static let maximumFrameBytes = 8 * 1024 * 1024
    static let maximumBatchBytes = 32 * 1024 * 1024
    private let frameLimit: Int
    private let batchLimit: Int
    private(set) var failureCode: String?
    private var discarding = false

    // Retain explicit, inspectable capacity across complete small frames.
    // Returned frames still copy bytes and cannot alias this scratch.
    private var storage: [UInt8] = []
    private var readCursor = 0
    private var scanCursor = 0

    var pendingByteCount: Int { storage.count - readCursor }
    var retainedByteCount: Int { storage.count }
    var scratchCapacity: Int { storage.capacity }

    init(frameLimit: Int = Self.maximumFrameBytes, batchLimit: Int = Self.maximumBatchBytes) {
        precondition(frameLimit > 0 && batchLimit > 0)
        self.frameLimit = frameLimit; self.batchLimit = batchLimit
    }

    mutating func append(_ data: Data, flush: Bool = false) -> [Data] {
        var lines: [Data] = []
        var offset = 0, batchBytes = 0
        while offset < data.count {
            if discarding {
                let next = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
                    guard let base = bytes.baseAddress,
                          let newline = memchr(base.advanced(by: offset), 0x0A, bytes.count - offset) else { return nil }
                    return base.distance(to: UnsafeRawPointer(newline)) + 1
                }
                guard let next else { break }
                offset = next; discarding = false
            }
            // Never copy an unbounded input chunk into retained storage. The
            // extra byte detects a frame exceeding its limit immediately.
            let count = min(64 * 1024, data.count - offset, frameLimit - pendingByteCount + 1)
            if count == 0 { continue }
            if storage.capacity == 0 { storage.reserveCapacity(min(4096, frameLimit)) }
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                storage.append(contentsOf: bytes[offset..<offset + count])
            }
            offset += count
            for line in extract(flush: false) {
                if batchBytes + line.count <= batchLimit && lines.count < 65536 {
                    lines.append(line); batchBytes += line.count
                } else { failureCode = failureCode ?? "transport_buffer_limit" }
            }
            if pendingByteCount > frameLimit {
                failureCode = failureCode ?? "transport_frame_limit"
                storage = []; readCursor = 0; scanCursor = 0; discarding = true
            }
        }
        if flush {
            for line in extract(flush: true) {
                if batchBytes + line.count <= batchLimit && lines.count < 65536 { lines.append(line); batchBytes += line.count }
                else { failureCode = failureCode ?? "transport_buffer_limit" }
            }
            discarding = false
        }
        return lines
    }

    private mutating func extract(flush: Bool) -> [Data] {
        var lines: [Data] = []
        var lineStart = readCursor
        storage.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var search = scanCursor
            // Native byte search also avoids per-byte Swift checks in debug builds.
            while search < bytes.count, let newline = memchr(base.advanced(by: search), 0x0A, bytes.count - search) {
                let offset = base.distance(to: UnsafeRawPointer(newline))
                if offset - lineStart > frameLimit {
                    failureCode = failureCode ?? "transport_frame_limit"
                } else if offset > lineStart {
                    lines.append(Data(bytes: base.advanced(by: lineStart), count: offset - lineStart))
                }
                lineStart = offset + 1
                search = lineStart
            }
            // Process termination may leave a complete final message without LF.
            if flush, lineStart < bytes.count {
                lines.append(Data(bytes: base.advanced(by: lineStart), count: bytes.count - lineStart))
                lineStart = bytes.count
            }
        }
        readCursor = lineStart
        scanCursor = storage.count

        if readCursor == storage.count {
            // A large frame must not pin its peak allocation across small
            // future bursts. Flush is the invocation's existing release boundary.
            storage.removeAll(keepingCapacity: !flush && storage.capacity <= Self.compactionThreshold)
            readCursor = 0
            scanCursor = 0
        } else if readCursor >= Self.compactionThreshold, readCursor >= pendingByteCount {
            storage.removeFirst(readCursor)
            scanCursor -= readCursor
            readCursor = 0
        }
        return lines
    }
}
