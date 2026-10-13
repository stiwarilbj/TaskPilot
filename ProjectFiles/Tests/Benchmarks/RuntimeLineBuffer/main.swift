import Foundation
import Dispatch

// Standalone, synthetic benchmark: no runtime launch, provider, or desktop calls.
// Keep the baseline identical to the parser replaced by this change.
struct PrefixRemovingBuffer {
    var storage = Data()
    mutating func append(_ bytes: Data, flush: Bool = false) -> [Data] {
        storage.append(bytes)
        var lines: [Data] = []
        while let newline = storage.firstIndex(of: 0x0A) {
            let line = Data(storage[..<newline])
            storage.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        if flush, !storage.isEmpty { lines.append(storage); storage.removeAll() }
        return lines
    }
}

struct Fixture {
    let name: String
    let chunks: [Data]
    let iterations: Int
    var byteCount: Int { chunks.reduce(0) { $0 + $1.count } }

    init(_ name: String, bytes: Data, chunkSize: Int, iterations: Int) {
        self.name = name; self.iterations = iterations
        self.chunks = stride(from: 0, to: bytes.count, by: chunkSize).map {
            Data(bytes[$0..<min($0 + chunkSize, bytes.count)])
        }
    }
}

func stream(_ count: Int) -> Data {
    var bytes = Data()
    for index in 0..<count {
        bytes.append(Data("{\"kind\":\"status\",\"message\":\"\(index): ☃ 🧭 \(String(repeating: "x", count: 120))\"}\n".utf8))
    }
    bytes.append(Data("{\"kind\":\"complete\",\"message\":\"synthetic tail\"}".utf8))
    return bytes
}

let burst = stream(10_000)
let fixtures = [
    Fixture("single decision", bytes: stream(1), chunkSize: 4096, iterations: 1000),
    Fixture("streamed burst / 64 KiB chunks", bytes: burst, chunkSize: 65_536, iterations: 3),
    Fixture("streamed burst / single chunk", bytes: burst, chunkSize: burst.count, iterations: 3),
    Fixture("fragmented messages / 317 B chunks", bytes: stream(1000), chunkSize: 317, iterations: 3),
    Fixture("incomplete 64 KiB line / 32 B chunks", bytes: Data(repeating: 0x78, count: 65_536), chunkSize: 32, iterations: 1)
]

func legacy(_ fixture: Fixture) -> [Data] {
    var buffer = PrefixRemovingBuffer(), lines: [Data] = []
    for chunk in fixture.chunks { lines += buffer.append(chunk) }
    lines += buffer.append(Data(), flush: true)
    return lines
}

func cursor(_ fixture: Fixture) -> [Data] {
    var buffer = RuntimeLineBuffer(), lines: [Data] = []
    for chunk in fixture.chunks { lines += buffer.append(chunk) }
    lines += buffer.append(Data(), flush: true)
    precondition(buffer.pendingByteCount == 0 && buffer.retainedByteCount == 0)
    return lines
}

func milliseconds(_ fixture: Fixture, _ operation: (Fixture) -> [Data]) -> (Double, Int) {
    let started = DispatchTime.now().uptimeNanoseconds
    var checksum = 0
    for _ in 0..<fixture.iterations {
        let lines = operation(fixture)
        checksum &+= lines.count
        for line in lines { checksum &+= line.count &+ Int(line.first ?? 0) &+ Int(line.last ?? 0) }
    }
    return (Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 / Double(fixture.iterations), checksum)
}

print("Swift line framing; five alternating timed samples after byte-for-byte parity and warmup.")
print("Fixture\tBytes\tChunks\tPrefix median ms\tCursor median ms\tSpeedup")
for fixture in fixtures {
    precondition(legacy(fixture) == cursor(fixture), "Framing changed: \(fixture.name)")
    _ = milliseconds(fixture, legacy); _ = milliseconds(fixture, cursor)
    var oldTimes: [Double] = [], newTimes: [Double] = []
    for sample in 0..<5 {
        let old, new: (Double, Int)
        if sample.isMultiple(of: 2) {
            old = milliseconds(fixture, legacy); new = milliseconds(fixture, cursor)
        } else {
            new = milliseconds(fixture, cursor); old = milliseconds(fixture, legacy)
        }
        precondition(old.1 == new.1)
        oldTimes.append(old.0); newTimes.append(new.0)
    }
    let old = oldTimes.sorted()[2], new = newTimes.sorted()[2]
    print("\(fixture.name)\t\(fixture.byteCount)\t\(fixture.chunks.count)\t\(String(format: "%.4f", old))\t\(String(format: "%.4f", new))\t\(String(format: "%.2fx", old / new))")
}
