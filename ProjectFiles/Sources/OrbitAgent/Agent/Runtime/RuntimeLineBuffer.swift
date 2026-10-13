import Darwin
import Foundation

/// Invocation-local framing for the runtime's newline-delimited byte stream.
/// Offsets are relative to the storage's bytes, including after Data compaction.
struct RuntimeLineBuffer {
    static let compactionThreshold = 64 * 1024

    private var storage = Data()
    private var readCursor = 0
    private var scanCursor = 0

    var pendingByteCount: Int { storage.count - readCursor }
    var retainedByteCount: Int { storage.count }

    mutating func append(_ data: Data, flush: Bool = false) -> [Data] {
        storage.append(data)
        var lines: [Data] = []
        var lineStart = readCursor
        storage.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var search = scanCursor
            // Native byte search also avoids per-byte Swift checks in debug builds.
            while search < bytes.count, let newline = memchr(base.advanced(by: search), 0x0A, bytes.count - search) {
                let offset = base.distance(to: UnsafeRawPointer(newline))
                if offset > lineStart {
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
            storage.removeAll(keepingCapacity: !flush && storage.count <= Self.compactionThreshold)
            readCursor = 0
            scanCursor = 0
        } else if readCursor >= Self.compactionThreshold, readCursor >= pendingByteCount {
            storage.removeSubrange(storage.startIndex..<storage.index(storage.startIndex, offsetBy: readCursor))
            scanCursor -= readCursor
            readCursor = 0
        }
        return lines
    }
}
