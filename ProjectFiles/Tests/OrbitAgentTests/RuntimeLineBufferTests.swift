import Foundation
import XCTest
@testable import OrbitAgent

final class RuntimeLineBufferTests: XCTestCase {
    private func legacyLines(_ data: Data, chunks: [Int], flush: Bool = true) -> [Data] {
        var buffer = Data(), result: [Data] = [], offset = 0
        for count in chunks {
            buffer.append(data[offset..<offset + count])
            offset += count
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { result.append(line) }
            }
        }
        if flush, !buffer.isEmpty { result.append(buffer) }
        return result
    }

    func testEmptyInputAndRepeatedFlushReturnNoLines() {
        var buffer = RuntimeLineBuffer()
        for flush in [false, true, true] {
            XCTAssertTrue(buffer.append(Data(), flush: flush).isEmpty)
            XCTAssertEqual(buffer.pendingByteCount, 0)
            XCTAssertEqual(buffer.retainedByteCount, 0)
        }
    }

    func testLineOrderingEmptyLinesAndCarriageReturnsMatchExistingFraming() {
        var buffer = RuntimeLineBuffer()
        let bytes = Data("\nfirst\n\nsecond\r\n \n\nlast".utf8)
        XCTAssertEqual(buffer.append(bytes), [Data("first".utf8), Data("second\r".utf8), Data(" ".utf8)])
        XCTAssertEqual(buffer.pendingByteCount, 4)
        XCTAssertEqual(buffer.append(Data(), flush: true), [Data("last".utf8)])
        XCTAssertEqual(buffer.retainedByteCount, 0)
    }

    func testEveryByteBoundaryPreservesSplitUTF8AndTerminalMessage() {
        let messages = [Data("{\"message\":\"☃ café 🧭\"}".utf8), Data("{\"kind\":\"complete\"}".utf8)]
        var bytes = messages[0]; bytes.append(0x0A); bytes.append(messages[1])
        for split in 0...bytes.count {
            var buffer = RuntimeLineBuffer()
            var actual = buffer.append(Data(bytes.prefix(split)))
            actual += buffer.append(Data(bytes.dropFirst(split)))
            actual += buffer.append(Data(), flush: true)
            XCTAssertEqual(actual, messages, "Split at byte \(split)")
            XCTAssertEqual(buffer.retainedByteCount, 0)
        }
    }

    func testIncompleteLineWaitsAcrossOneByteAppends() {
        var buffer = RuntimeLineBuffer()
        let message = Data(String(repeating: "x", count: 20_000).utf8)
        for byte in message {
            XCTAssertTrue(buffer.append(Data([byte])).isEmpty)
        }
        XCTAssertEqual(buffer.pendingByteCount, message.count)
        XCTAssertEqual(buffer.append(Data([0x0A])), [message])
        XCTAssertEqual(buffer.retainedByteCount, 0)
    }

    func testSmallConsumedPrefixIsRetainedUntilMoreDataArrives() {
        var buffer = RuntimeLineBuffer()
        let first = Data("one\ntw".utf8)
        XCTAssertEqual(buffer.append(first), [Data("one".utf8)])
        XCTAssertEqual(buffer.pendingByteCount, 2)
        XCTAssertEqual(buffer.retainedByteCount, first.count)
        XCTAssertEqual(buffer.append(Data("o\nthree".utf8)), [Data("two".utf8)])
        XCTAssertEqual(buffer.pendingByteCount, 5)
        XCTAssertEqual(buffer.append(Data(), flush: true), [Data("three".utf8)])
    }

    func testConsumedPrefixCompactsAtThresholdAndPreservesPartialLine() {
        var buffer = RuntimeLineBuffer()
        let line = Data(repeating: 0x61, count: RuntimeLineBuffer.compactionThreshold - 1)
        var bytes = line; bytes.append(0x0A); bytes.append(Data("partial".utf8))
        XCTAssertEqual(buffer.append(bytes), [line])
        XCTAssertEqual(buffer.pendingByteCount, 7)
        XCTAssertEqual(buffer.retainedByteCount, 7)
        XCTAssertEqual(buffer.append(Data(" rest\n".utf8)), [Data("partial rest".utf8)])
        XCTAssertEqual(buffer.retainedByteCount, 0)
    }

    func testLargePendingLineDefersCompactionUntilPrefixIsHalfTheBuffer() {
        var buffer = RuntimeLineBuffer()
        let line = Data(repeating: 0x61, count: RuntimeLineBuffer.compactionThreshold)
        let pending = Data(repeating: 0x62, count: line.count * 2)
        var bytes = line; bytes.append(0x0A); bytes.append(pending)
        XCTAssertEqual(buffer.append(bytes), [line])
        XCTAssertEqual(buffer.pendingByteCount, pending.count)
        XCTAssertEqual(buffer.retainedByteCount, bytes.count)
        XCTAssertEqual(buffer.append(Data([0x0A])), [pending])
        XCTAssertEqual(buffer.retainedByteCount, 0)
    }

    func testRepeatedCompactionAndAppendUseByteOffsetsIndependentOfDataIndices() {
        var buffer = RuntimeLineBuffer()
        let body = Data(repeating: 0x61, count: RuntimeLineBuffer.compactionThreshold)
        var first = body; first.append(0x0A); first.append(0x62)
        XCTAssertEqual(buffer.append(first), [body])
        for _ in 0..<6 {
            var chunk = body; chunk.append(0x0A); chunk.append(0x62)
            var expected = Data([0x62]); expected.append(body)
            XCTAssertEqual(buffer.append(chunk), [expected])
            XCTAssertEqual(buffer.retainedByteCount, 1)
        }
        XCTAssertEqual(buffer.append(Data(), flush: true), [Data([0x62])])
    }

    func testReturnedLinesSurviveBufferReuseAndCompaction() {
        var buffer = RuntimeLineBuffer()
        let old = buffer.append(Data("old\npartial".utf8))
        var burst = Data(repeating: 0x78, count: RuntimeLineBuffer.compactionThreshold)
        burst.append(0x0A); burst.append(0x79)
        _ = buffer.append(burst)
        _ = buffer.append(Data("\nnew\n".utf8), flush: true)
        XCTAssertEqual(old, [Data("old".utf8)])
        XCTAssertEqual(buffer.append(Data("reuse\n".utf8)), [Data("reuse".utf8)])
    }

    func testInvalidUTF8AndMalformedJSONAreFramedWithoutLossOrRepair() {
        var buffer = RuntimeLineBuffer()
        let invalid = Data([0xFF, 0xFE, 0x0D])
        var bytes = invalid; bytes.append(0x0A); bytes.append(Data("{invalid}\n".utf8))
        XCTAssertEqual(buffer.append(bytes), [invalid, Data("{invalid}".utf8)])
    }

    func testInvocationBuffersAndValueCopiesDoNotShareCursors() {
        var first = RuntimeLineBuffer(), second = RuntimeLineBuffer()
        XCTAssertTrue(first.append(Data("first".utf8)).isEmpty)
        XCTAssertTrue(second.append(Data("second".utf8)).isEmpty)
        var copy = first
        XCTAssertEqual(copy.append(Data(" copy\n".utf8)), [Data("first copy".utf8)])
        XCTAssertEqual(first.append(Data([0x0A])), [Data("first".utf8)])
        XCTAssertEqual(second.append(Data(), flush: true), [Data("second".utf8)])
    }

    func testDeterministicBurstsAndFragmentationMatchLegacyBytesExactly() {
        var seed: UInt64 = 0x715A
        func next() -> UInt64 { seed = seed &* 6_364_136_223_846_793_005 &+ 1; return seed }
        var bytes = Data()
        for _ in 0..<2_000 {
            for _ in 0..<Int(next() % 220) { bytes.append(UInt8(truncatingIfNeeded: next() >> 32)) }
            bytes.append(0x0A)
        }
        bytes.append(Data("last without newline 🧭".utf8))
        for maxChunk in [1, 3, 127, 4_096, 65_536, bytes.count] {
            var chunks: [Int] = [], offset = 0
            while offset < bytes.count {
                let count = min(Int(next() % UInt64(maxChunk)) + 1, bytes.count - offset)
                chunks.append(count); offset += count
            }
            var buffer = RuntimeLineBuffer(), actual: [Data] = []
            offset = 0
            for count in chunks {
                actual += buffer.append(Data(bytes[offset..<offset + count]))
                offset += count
            }
            actual += buffer.append(Data(), flush: true)
            XCTAssertEqual(actual, legacyLines(bytes, chunks: chunks), "Maximum chunk \(maxChunk)")
            XCTAssertEqual(buffer.retainedByteCount, 0)
        }
    }
}
