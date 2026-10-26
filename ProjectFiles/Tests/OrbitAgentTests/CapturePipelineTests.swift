import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import OrbitAgent

final class CapturePipelineTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        func now() -> TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }
    private var display: DisplayDescriptor { .init(id: 777, name: "fixture", x: -20, y: 10, width: 100, height: 80, isMain: false) }
    private func image(_ red: CGFloat, _ green: CGFloat = 0, _ blue: CGFloat = 0) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try XCTUnwrap(context.makeImage())
    }
    private func pixel(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 4))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-pipeline-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func eventually(_ check: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await check()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        let passed = await check(); XCTAssertTrue(passed, file: file, line: line)
    }
    private func cancelled<T>(_ task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
    }
    private final class BlockedWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let started: XCTestExpectation
        let release = DispatchSemaphore(value: 0)
        var count: Int { lock.withLock { calls } }
        init(_ started: XCTestExpectation) { self.started = started }
        func write(_ image: CGImage, to url: URL) throws {
            let first = lock.withLock { calls += 1; return calls == 1 }
            if first {
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw ScreenCaptureError.couldNotWriteImage }
            }
            try ScreenCaptureService.writePNG(image, to: url)
        }
    }
    private final class FailOnceWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var first = true
        func write(_ image: CGImage, to url: URL) throws {
            if lock.withLock({ let fail = first; first = false; return fail }) {
                try Data([1, 2, 3]).write(to: url); throw ScreenCaptureError.couldNotWriteImage
            }
            try ScreenCaptureService.writePNG(image, to: url)
        }
    }
    private actor Counter { var value = 0; func increment() { value += 1 } }
    private actor Images {
        var frames: [CGImage]
        var calls: [Bool] = []
        init(_ frames: [CGImage]) { self.frames = frames }
        func acquire(preview: Bool) throws -> CGImage {
            calls.append(preview)
            guard !frames.isEmpty else { throw ScreenCaptureError.displayUnavailable }
            return frames.removeFirst()
        }
    }
    private final class WeakFrame: @unchecked Sendable {
        private let lock = NSLock()
        private weak var value: CapturedFrame?
        func set(_ frame: CapturedFrame) { lock.withLock { value = frame } }
        var released: Bool { lock.withLock { value == nil } }
    }

    func testExpiredAcquisitionDoesNotReservePixelsOrReplacePreview() async throws {
        let queue = CaptureAcquisitionQueue(), clock = Clock()
        var blocker: CaptureAcquisitionQueue.Reservation? = try await queue.acquire(.evidence)
        let preview = Task { try await queue.acquire(.preview) }
        await eventually { await queue.statistics.waitingPreview == 1 }
        let budget = LocalOperationBudget(seconds: 1, phase: "preflight", now: { clock.now() })
        clock.advance(1)
        do {
            _ = try await LocalOperationBudget.$current.withValue(budget) { try await queue.acquire(.preview) }
            XCTFail("Expired request acquired pixels")
        } catch { XCTAssertTrue(error is LocalOperationBudget.Exhausted) }
        let stats = await queue.statistics
        XCTAssertEqual(stats.waitingPreview, 1); XCTAssertEqual(stats.previewFrames, 0)
        await queue.acquired(blocker!); blocker = nil
        let accepted = try await preview.value; try accepted.check(); await queue.acquired(accepted)
    }

    func testExpiredEncodingNeverCreatesScratchOrStartsCompression() async throws {
        let clock = Clock(), budget = LocalOperationBudget(seconds: 1, phase: "preflight", now: { clock.now() })
        let telemetry = BackendTelemetry(now: { clock.now() }), ticket = telemetry.beginQueueWait(.pngCompression)
        let root = try directory().appendingPathComponent("not-created")
        let encoder = CapturePNGEncoder(directory: root, writer: { _, _ in XCTFail("Expired compression invoked") })
        let pixels = try image(1), service = ScreenCaptureService(acquirer: { _, _, _ in pixels })
        let frame = try await service.acquire(display: display)
        clock.advance(1)
        do {
            _ = try await LocalOperationBudget.$current.withValue(budget) {
                try await encoder.encode(frame, telemetry: telemetry, waitTicket: ticket)
            }
            XCTFail("Expired compression accepted")
        } catch { XCTAssertTrue(error is LocalOperationBudget.Exhausted) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let active = await encoder.activeCount, pending = await encoder.pendingCount
        XCTAssertEqual(active, 0); XCTAssertEqual(pending, 0)
        let histogram = telemetry.queueWaitHistograms().first { $0.queue == .pngCompression }
        XCTAssertEqual(histogram?.countsByDisposition[.rejected]?.reduce(0, +), 1)
        XCTAssertNil(histogram?.countsByDisposition[.started])
        try frame.check() // Expiry does not cancel a separately owned accepted frame.
    }

    func testQueuedEncodingExpiresBeforeWorkerAllocationAndCanBeRetriedFresh() async throws {
        let started = expectation(description: "First encode running"), writer = BlockedWriter(started)
        defer { writer.release.signal() }
        let root = try directory(), encoder = CapturePNGEncoder(directory: root, writer: { try writer.write($0, to: $1) })
        let pixels = try image(1), service = ScreenCaptureService(acquirer: { _, _, _ in pixels })
        let first = try await service.acquire(display: display), second = try await service.acquire(display: display)
        let running = Task { try await encoder.encode(first) }
        await fulfillment(of: [started], timeout: 2)
        let clock = Clock(), budget = LocalOperationBudget(seconds: 1, phase: "preflight", now: { clock.now() })
        let telemetry = BackendTelemetry(now: { clock.now() }), ticket = telemetry.beginQueueWait(.pngCompression)
        let queued = Task {
            try await LocalOperationBudget.$current.withValue(budget) {
                try await encoder.encode(second, telemetry: telemetry, waitTicket: ticket)
            }
        }
        await eventually { await encoder.pendingCount == 1 }
        clock.advance(1); writer.release.signal(); _ = try await running.value
        do { _ = try await queued.value; XCTFail("Expired compression ran") }
        catch { XCTAssertTrue(error is LocalOperationBudget.Exhausted) }
        XCTAssertEqual(writer.count, 1)
        XCTAssertEqual(telemetry.queueWaitHistograms().first { $0.queue == .pngCompression }?.countsByDisposition[.rejected]?.reduce(0, +), 1)
        _ = try await encoder.encode(second)
        XCTAssertEqual(writer.count, 2)
    }

    func testEvidencePrecedesLatestPreviewAndOldPreviewsAreCoalesced() async throws {
        let queue = CaptureAcquisitionQueue()
        var blocker: CaptureAcquisitionQueue.Reservation? = try await queue.acquire(.preview)
        let old = Task { try await queue.acquire(.preview) }
        await eventually { await queue.statistics.waitingPreview == 1 }
        let evidence = Task { try await queue.acquire(.evidence) }
        await eventually { await queue.statistics.waitingEvidence == 1 }
        let latest = Task { try await queue.acquire(.preview) }
        await cancelled(old)
        await queue.acquired(blocker!); blocker = nil
        let taskFrame = try await evidence.value
        let stats = await queue.statistics
        XCTAssertTrue(stats.acquiring); XCTAssertEqual(stats.evidenceFrames, 1); XCTAssertEqual(stats.waitingPreview, 1)
        await queue.acquired(taskFrame)
        let preview = try await latest.value; try preview.check()
        await queue.acquired(preview)
    }
    func testCaptureQueueMeasuresWaitAndPreviewCoalescing() async throws {
        let clock = Clock(), telemetry = BackendTelemetry(now: { clock.now() }), queue = CaptureAcquisitionQueue()
        let blockerTicket = telemetry.beginQueueWait(.capturePreview)
        var blocker: CaptureAcquisitionQueue.Reservation? = try await queue.acquire(.preview, waitTicket: blockerTicket)
        let oldTicket = telemetry.beginQueueWait(.capturePreview)
        let old = Task { try await queue.acquire(.preview, waitTicket: oldTicket) }
        await eventually { await queue.statistics.waitingPreview == 1 }
        clock.advance(0.020)
        let latestTicket = telemetry.beginQueueWait(.capturePreview)
        let latest = Task { try await queue.acquire(.preview, waitTicket: latestTicket) }
        await cancelled(old)
        await eventually { await queue.statistics.waitingPreview == 1 }
        let coalesced = telemetry.queueWaitHistograms().first { $0.queue == .capturePreview }
        XCTAssertEqual(coalesced?.countsByDisposition[.coalesced]?.reduce(0, +), 1)
        clock.advance(0.020)
        XCTAssertNotNil(blocker)
        blocker = nil
        let reservation = try await latest.value
        let histogram = try XCTUnwrap(telemetry.queueWaitHistograms().first { $0.queue == .capturePreview })
        XCTAssertEqual(histogram.countsByDisposition[.started]?.reduce(0, +), 2)
        XCTAssertEqual(histogram.countsByDisposition[.coalesced]?.reduce(0, +), 1)
        XCTAssertEqual(histogram.countsByDisposition[.started]?[4], 1) // 20 ms admission wait
        await queue.acquired(reservation)
    }
    func testPreviewFloodRetainsOnlyOnePendingRequest() async throws {
        let queue = CaptureAcquisitionQueue(), counter = Counter()
        var blocker: CaptureAcquisitionQueue.Reservation? = try await queue.acquire(.preview)
        let requests = (0..<100).map { _ in Task {
            do { return try await queue.acquire(.preview) }
            catch { await counter.increment(); throw error }
        } }
        await eventually { await counter.value == 99 }
        let stats = await queue.statistics
        XCTAssertEqual(stats.waitingPreview, 1); XCTAssertEqual(stats.previewFrames, 1)
        await queue.acquired(blocker!); blocker = nil
        var successes = 0
        for request in requests {
            do { let frame = try await request.value; successes += 1; await queue.acquired(frame) }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(successes, 1)
    }
    func testWaitingEvidenceIsBoundedAndCancellationRemovesQueueEntries() async throws {
        let queue = CaptureAcquisitionQueue(maximumWaitingEvidence: 2)
        let active = try await queue.acquire(.evidence)
        let first = Task { try await queue.acquire(.evidence) }
        let second = Task { try await queue.acquire(.evidence) }
        await eventually { await queue.statistics.waitingEvidence == 2 }
        do { _ = try await queue.acquire(.evidence); XCTFail("Unbounded waiting queue") }
        catch { guard case ScreenCaptureError.pipelineBusy = error else { return XCTFail("\(error)") } }
        first.cancel(); second.cancel(); await cancelled(first); await cancelled(second)
        let stats = await queue.statistics; XCTAssertEqual(stats.waitingEvidence, 0); XCTAssertEqual(stats.evidenceFrames, 1)
        await queue.acquired(active)
    }
    func testRawEvidenceLimitStillAllowsPreviewAndPreservesOwnedFrames() async throws {
        let queue = CaptureAcquisitionQueue()
        var first: CaptureAcquisitionQueue.Reservation? = try await queue.acquire(.evidence)
        await queue.acquired(first!)
        let second = try await queue.acquire(.evidence); await queue.acquired(second)
        let third = Task { try await queue.acquire(.evidence) }
        await eventually { await queue.statistics.waitingEvidence == 1 }
        let preview = try await queue.acquire(.preview); await queue.acquired(preview)
        let stats = await queue.statistics
        XCTAssertEqual(stats.evidenceFrames, 2); XCTAssertEqual(stats.previewFrames, 1)
        try second.check() // A third request cannot evict already-owned evidence.
        first = nil
        let next = try await third.value; await queue.acquired(next)
        let nextStats = await queue.statistics; XCTAssertEqual(nextStats.evidenceFrames, 2)
    }
    func testRevocationRemovesQueuedWorkBeforeAnyAcquisition() async throws {
        let queue = CaptureAcquisitionQueue(), lease = TaskLease()
        let active = try await queue.acquire(.preview)
        let waiting = Task { try await queue.acquire(.evidence, owner: lease) }
        await eventually { await queue.statistics.waitingEvidence == 1 }
        lease.revoke(); await cancelled(waiting)
        let stats = await queue.statistics; XCTAssertEqual(stats.waitingEvidence, 0); XCTAssertEqual(stats.evidenceFrames, 0)
        await queue.acquired(active)
        let newLease = TaskLease()
        let next = try await queue.acquire(.evidence, owner: newLease)
        XCTAssertNotEqual(next.owner?.id, lease.id); XCTAssertTrue(next.owner === newLease)
        await queue.acquired(next)
    }
    func testSlowEncodingDoesNotBlockAcquisitionOrPreviewAndUsesExactPixels() async throws {
        let started = expectation(description: "Compression running"), writer = BlockedWriter(started)
        defer { writer.release.signal() }
        let root = try directory(), queue = CaptureAcquisitionQueue()
        let encoder = CapturePNGEncoder(directory: root, writer: { try writer.write($0, to: $1) })
        let images = Images([try image(1), try image(0, 0, 1), try image(0, 1)])
        let capture = ScreenCaptureService(acquisitionQueue: queue, encoder: encoder, acquirer: { _, _, preview in try await images.acquire(preview: preview) })
        let telemetry = BackendTelemetry()
        let accepted = try await BackendTelemetry.$current.withValue(telemetry) { try await capture.acquire(display: display) }
        let compression = Task {
            try await BackendTelemetry.$current.withValue(telemetry) { try await capture.encode(accepted) }
        }
        await fulfillment(of: [started], timeout: 2)
        let queueWait = telemetry.queueWaitHistograms().first { $0.queue == .pngCompression }
        XCTAssertEqual(queueWait?.countsByDisposition[.started]?.reduce(0, +), 1)
        XCTAssertEqual(telemetry.queueWaitHistograms().first { $0.queue == .captureEvidence }?.countsByDisposition[.started]?.reduce(0, +), 1)
        let newer = try await capture.acquire(display: display)
        let preview = try await capture.capturePreview(display: display)
        XCTAssertEqual(try pixel(newer.image), [0, 0, 255, 255]); XCTAssertEqual(try pixel(preview), [0, 255, 0, 255])
        let calls = await images.calls; XCTAssertEqual(calls, [false, false, true])
        XCTAssertEqual(writer.count, 1)
        writer.release.signal()
        let encoded = try await compression.value
        XCTAssertEqual(encoded.frameID, accepted.id); XCTAssertEqual(encoded.coordinates, accepted.coordinates)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(encoded.url as CFURL, nil))
        XCTAssertEqual(try pixel(XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))), [255, 0, 0, 255])
    }
    func testCancelledQueuedCompressionReleasesItsBufferWhileFirstEncodeIsBlocked() async throws {
        let started = expectation(description: "First encode running"), writer = BlockedWriter(started)
        defer { writer.release.signal() }
        let root = try directory(), queue = CaptureAcquisitionQueue(), weakFrame = WeakFrame()
        let encoder = CapturePNGEncoder(directory: root, writer: { try writer.write($0, to: $1) })
        let pixels = try image(1)
        let service = ScreenCaptureService(acquisitionQueue: queue, encoder: encoder, acquirer: { _, _, _ in pixels })
        let first = try await service.acquire(display: display)
        let running = Task { try await service.encode(first) }
        await fulfillment(of: [started], timeout: 2)
        let target = display
        let queued = Task { () throws -> URL in
            let frame = try await service.acquire(display: target); weakFrame.set(frame)
            return try await service.encode(frame).url
        }
        await eventually { await encoder.pendingCount == 1 }
        queued.cancel(); await cancelled(queued)
        await eventually { weakFrame.released }
        await eventually { await queue.statistics.evidenceFrames == 1 }
        XCTAssertEqual(writer.count, 1)
        let replacement = try await service.acquire(display: display); try replacement.check()
        writer.release.signal(); _ = try await running.value
    }
    func testStoppedEncodingDrainsBeforeNextJobAndRemovesLateArtifact() async throws {
        let started = expectation(description: "Old encode running"), writer = BlockedWriter(started)
        defer { writer.release.signal() }
        let encoder = CapturePNGEncoder(directory: try directory(), writer: { try writer.write($0, to: $1) })
        let pixels = try image(1), lease = TaskLease()
        let service = ScreenCaptureService(encoder: encoder, acquirer: { _, _, _ in pixels })
        let frame = try await TaskOwnership.$current.withValue(lease) { try await service.acquire(display: display) }
        let old = Task { try await service.encode(frame) }
        await fulfillment(of: [started], timeout: 2)
        lease.revoke(); old.cancel()
        let nextFrame = try await service.acquire(display: display)
        let next = Task { try await service.encode(nextFrame) }
        await eventually { await encoder.pendingCount == 1 }
        let active = await encoder.activeCount; XCTAssertEqual(active, 1); XCTAssertEqual(writer.count, 1)
        writer.release.signal(); await cancelled(old)
        let encoded = try await next.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: encoded.url.path))
        let files = try FileManager.default.contentsOfDirectory(at: encoded.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map { $0.resolvingSymlinksInPath() }, [encoded.url.resolvingSymlinksInPath()]); XCTAssertEqual(writer.count, 2)
    }
    func testFailedWriterRemovesPartialFileAndNextEncodingSucceeds() async throws {
        let root = try directory(), pixels = try image(1), writer = FailOnceWriter()
        let encoder = CapturePNGEncoder(directory: root, writer: { try writer.write($0, to: $1) })
        let service = ScreenCaptureService(encoder: encoder, acquirer: { _, _, _ in pixels })
        let frame = try await service.acquire(display: display)
        do { _ = try await service.encode(frame); XCTFail("Failed writer accepted") }
        catch { XCTAssertTrue(error is ScreenCaptureError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let active = await encoder.activeCount, pending = await encoder.pendingCount
        XCTAssertEqual(active, 0); XCTAssertEqual(pending, 0)
        let result = try await encoder.encode(frame); XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
    }
    func testDuplicateCompressionAndOverflowAreRejectedWithoutMoreWorkers() async throws {
        let started = expectation(description: "Encode running"), writer = BlockedWriter(started)
        defer { writer.release.signal() }
        let encoder = CapturePNGEncoder(directory: try directory(), writer: { try writer.write($0, to: $1) })
        let pixels = try image(1), service = ScreenCaptureService(acquirer: { _, _, _ in pixels })
        let first = try await service.acquire(display: display), second = try await service.acquire(display: display)
        let clock = Clock(), telemetry = BackendTelemetry(now: { clock.now() })
        let firstTicket = telemetry.beginQueueWait(.pngCompression)
        let running = Task { try await encoder.encode(first, telemetry: telemetry, waitTicket: firstTicket) }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await encoder.encode(first); XCTFail("Duplicate compression queued") }
        catch { guard case ScreenCaptureError.pipelineBusy = error else { return XCTFail("\(error)") } }
        let queuedTicket = telemetry.beginQueueWait(.pngCompression)
        let queued = Task { try await encoder.encode(second, telemetry: telemetry, waitTicket: queuedTicket) }
        await eventually { await encoder.pendingCount == 1 }
        clock.advance(0.020)
        let otherService = ScreenCaptureService(acquirer: { _, _, _ in pixels })
        let third = try await otherService.acquire(display: display)
        let rejectedTicket = telemetry.beginQueueWait(.pngCompression)
        do { _ = try await encoder.encode(third, telemetry: telemetry, waitTicket: rejectedTicket); XCTFail("Compression queue overflowed") }
        catch { guard case ScreenCaptureError.pipelineBusy = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(writer.count, 1)
        writer.release.signal(); _ = try await running.value; _ = try await queued.value
        XCTAssertEqual(writer.count, 2)
        let histogram = try XCTUnwrap(telemetry.queueWaitHistograms().first { $0.queue == .pngCompression })
        XCTAssertEqual(histogram.countsByDisposition[.started]?.reduce(0, +), 2)
        XCTAssertEqual(histogram.countsByDisposition[.started]?[4], 1) // Backlog through worker start.
        XCTAssertEqual(histogram.countsByDisposition[.rejected]?.reduce(0, +), 1)
    }
    func testConsistencyRejectsUnpairedFramesBeforeEncodingAndFreezesAcceptedPair() async throws {
        var stages = 0, captures = 0, discarded: [Int] = [], encoded: [Int] = [], published: [Int] = []
        var scene = 1, time: Double = 1
        let pair = try await ObservationConsistency.collect(now: { time }, checkpoint: {}, scene: { scene },
            stage: { _ in stages += 1; return stages == 1 ? "old" : "stable" },
            signature: { $0 }, capture: { _ in captures += 1; return captures }, discard: { discarded.append($0) },
            prepare: { controls, frame, pairedScene in
                XCTAssertEqual(controls, "stable"); XCTAssertEqual(frame, 2); XCTAssertEqual(pairedScene, 1)
                // A later preview/screen change must not replace this frame or
                // make the paired controls describe its newer pixels.
                scene = 2; encoded.append(frame)
            }, publish: { _ in published.append(encoded.last!) }, sleep: { time += $0 })
        XCTAssertEqual(pair.1, 2); XCTAssertEqual(captures, 2); XCTAssertEqual(discarded, [1])
        XCTAssertEqual(encoded, [2]); XCTAssertEqual(published, [2])
    }
    func testCancellationAfterPairingDiscardsFrameAndDoesNotPublish() async throws {
        var cancelled = false, discarded: [Int] = [], published = 0
        do {
            _ = try await ObservationConsistency.collect(checkpoint: { if cancelled { throw CancellationError() } }, scene: { 1 },
                stage: { _ in 1 }, signature: { String($0) }, capture: { _ in 7 }, discard: { discarded.append($0) },
                prepare: { _, _, _ in cancelled = true }, publish: { _ in published += 1 })
            XCTFail("Cancelled pair published")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(discarded, [7]); XCTAssertEqual(published, 0)
    }
}
