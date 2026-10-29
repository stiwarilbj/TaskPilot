import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class LocalWorkloadGovernorTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value = 0.0
        func now() -> Double { lock.withLock { value } }
        func advance() { lock.withLock { value += 1 } }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    private final class BlockedWriter: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        let calls = Counter()
        func write(_ image: CGImage, _ url: URL) throws {
            calls.increment()
            guard gate.wait(timeout: .now() + 5) == .success else { throw ScreenCaptureError.couldNotWriteImage }
            try Data([1]).write(to: url)
        }
    }
    private func governor(bytes: Int = 1024 * 1024, reserve: Int = 128,
                          queue: Int = 16, work: Int = 64,
                          monitor: MemoryPressureMonitor? = nil,
                          descriptors: @escaping () -> UInt64? = { 1024 }) -> LocalWorkloadGovernor {
        LocalWorkloadGovernor(limits: .init(memoryBytes: bytes, essentialReserveBytes: reserve,
            disposableQueueDepth: queue, requiredWorkCount: work), monitor: monitor, descriptorHeadroom: descriptors)
    }
    private func refused(_ reason: LocalWorkloadGovernor.Reason, deferred: Bool = false,
                         _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            guard let error = $0 as? LocalWorkloadGovernor.Refused else { return XCTFail("Wrong error: \($0)", file: file, line: line) }
            XCTAssertEqual(error.reason, reason, file: file, line: line)
            XCTAssertEqual(error.deferred, deferred, file: file, line: line)
        }
    }
    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic work did not settle")
    }
    private func image() throws -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return try XCTUnwrap(context.makeImage())
    }
    private var display: DisplayDescriptor {
        .init(id: 777, name: "Synthetic", x: -20, y: 10, width: 100, height: 80, isMain: false)
    }

    func testSharedMemoryAndQueuePressurePreserveRequiredAndTerminalCapacity() throws {
        let g = governor(bytes: 100, reserve: 30, queue: 2)
        let ipc = try g.reserve(.ipc, demand: .init(memoryBytes: 40))
        refused(.memoryCapacity, deferred: true) { _ = try g.reserve(.previewCapture, demand: .init(memoryBytes: 31)) }
        let evidence = try g.reserve(.evidenceCapture, demand: .init(memoryBytes: 60))
        refused(.queueCapacity, deferred: true) { _ = try g.reserve(.maintenance) }
        refused(.memoryCapacity) { _ = try g.reserve(.accessibility, demand: .init(memoryBytes: 1)) }
        let terminal = try g.reserve(.terminalIPC, demand: .init(memoryBytes: 20))
        try terminal.start()
        // Accepted evidence is not revoked when terminal traffic uses reserve.
        try evidence.start()
        XCTAssertEqual(g.snapshot.memoryBytes, 120)
        XCTAssertEqual(g.snapshot.active, 2)
        terminal.finish(); evidence.finish(); ipc.finish()
        XCTAssertEqual(g.snapshot.reservations, 0)
        XCTAssertEqual(g.snapshot.memoryBytes, 0)
    }

    func testPressureIsRecheckedBeforeOptionalWorkAndNormalEventRestoresAdmission() throws {
        let monitor = MemoryPressureMonitor(listen: false)
        // A newly registered governor also sees an existing warning.
        monitor.receive(.warning)
        let observed = governor(monitor: monitor)
        refused(.memoryPressure, deferred: true) { _ = try observed.reserve(.previewCapture) }
        monitor.receive(.normal)
        let preview = try observed.reserve(.previewCapture), audit = try observed.reserve(.maintenance)
        monitor.receive(.critical)
        refused(.memoryPressure, deferred: true) { try preview.start() }
        refused(.memoryPressure, deferred: true) { try audit.start() }
        let evidence = try observed.reserve(.evidenceCapture), ipc = try observed.reserve(.terminalIPC)
        try evidence.start(); try ipc.start()
        preview.finish(); audit.finish(); evidence.finish(); ipc.finish()
        monitor.receive(.normal)
        let next = try observed.reserve(.previewCapture); try next.start(); next.finish()
        XCTAssertEqual(observed.snapshot.reservations, 0)
    }

    func testDescriptorAndSameVolumeDiskReservationsCombineAcrossComponents() throws {
        let g = governor(descriptors: { 3 }), disk = LocalWorkloadGovernor.DiskSpace(device: 1, available: 100)
        let capture = try g.reserve(.evidenceEncoding,
            demand: .init(descriptors: 2, diskBytes: 60, disk: disk))
        refused(.descriptors) { _ = try g.reserve(.helper, demand: .init(descriptors: 2)) }
        let helper = try g.reserve(.helper, demand: .init(descriptors: 1))
        refused(.diskSpace) { _ = try g.reserve(.evidenceEncoding, demand: .init(diskBytes: 41, disk: disk)) }
        let otherVolume = try g.reserve(.evidenceEncoding,
            demand: .init(diskBytes: 80, disk: .init(device: 2, available: 100)))
        // A wait followed by reduced free space must be checked again.
        refused(.diskSpace) { try capture.update(.init(descriptors: 2, diskBytes: 60, disk: .init(device: 1, available: 59))) }
        XCTAssertEqual(g.snapshot.diskBytes, 140)
        XCTAssertEqual(g.snapshot.descriptors, 3)
        capture.finish(); helper.finish(); otherVolume.finish()
        XCTAssertEqual(g.snapshot.diskBytes, 0); XCTAssertEqual(g.snapshot.descriptors, 0)
    }

    func testDeadlineExpiryAndExactlyOnceConcurrentRelease() throws {
        let clock = Clock(), g = governor()
        let budget = LocalOperationBudget(seconds: 1, phase: "fixture", now: { clock.now() })
        let ticket = try g.reserve(.evidenceCapture, demand: .init(memoryBytes: 10), budget: budget)
        clock.advance()
        XCTAssertThrowsError(try ticket.start()) { XCTAssertTrue($0 is LocalOperationBudget.Exhausted) }
        XCTAssertThrowsError(try g.reserve(.helper, budget: budget))
        // Expiry alone does not release the capacity of work that may be in flight.
        XCTAssertEqual(g.snapshot.reservations, 1)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in ticket.finish() }
        XCTAssertEqual(g.snapshot.reservations, 0)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            do {
                let ticket = try g.reserve(.ipc, demand: .init(memoryBytes: 1))
                try ticket.start(); ticket.finish(); ticket.finish()
            } catch { XCTFail("Healthy concurrent accounting: \(error)") }
        }
        XCTAssertEqual(g.snapshot.memoryBytes, 0); XCTAssertEqual(g.snapshot.reservations, 0)
    }

    func testRejectionAndDeinitializationLeaveNoReservation() throws {
        let g = governor(bytes: 100)
        refused(.memoryCapacity) { _ = try g.reserve(.helper, demand: .init(memoryBytes: Int.max)) }
        do {
            let ticket = try g.reserve(.ipc, demand: .init(memoryBytes: 80))
            refused(.memoryCapacity) { try ticket.update(.init(memoryBytes: 101)) }
            XCTAssertEqual(g.snapshot.memoryBytes, 80)
        }
        XCTAssertEqual(g.snapshot.reservations, 0)
        XCTAssertEqual(g.snapshot.refused[.memoryCapacity], 2)
    }

    func testCancelledTaskCanStillReserveCancellationTraffic() async throws {
        let g = governor(bytes: 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let terminal = try g.reserve(.terminalIPC, demand: .init(memoryBytes: 10))
            try terminal.start(); terminal.finish()
            XCTAssertThrowsError(try g.reserve(.helper)) { XCTAssertTrue($0 is CancellationError) }
        }
        try await task.value
        XCTAssertEqual(g.snapshot.reservations, 0)
    }

    func testQueuedPreviewRechecksPressureWithoutAcquiringPixels() async throws {
        let monitor = MemoryPressureMonitor(listen: false)
        let observed = governor(monitor: monitor), queue = CaptureAcquisitionQueue(governor: observed)
        var active: CaptureAcquisitionQueue.Reservation? = try await queue.acquire(.evidence)
        let pending = Task { try await queue.acquire(.preview) }
        try await eventually { await queue.statistics.waitingPreview == 1 }
        monitor.receive(.warning)
        await queue.acquired(active!)
        do { _ = try await pending.value; XCTFail("Queued preview granted under pressure") }
        catch let error as LocalWorkloadGovernor.Refused { XCTAssertTrue(error.deferred) }
        XCTAssertEqual(observed.snapshot.reservations, 1)
        active = nil
        try await eventually { observed.snapshot.reservations == 0 }
    }

    func testCaptureDefersBeforeAcquisitionButEvidenceUsesExistingPixelsWithoutExtraCaptures() async throws {
        let monitor = MemoryPressureMonitor(listen: false)
        let pressured = governor(bytes: 32 * 1024 * 1024, monitor: monitor)
        let calls = Counter(), pixels = try image()
        let service = ScreenCaptureService(acquirer: { _, _, _ in calls.increment(); return pixels }, governor: pressured)
        monitor.receive(.warning)
        do { _ = try await service.capturePreview(display: display); XCTFail("Preview should defer") }
        catch let error as LocalWorkloadGovernor.Refused { XCTAssertTrue(error.deferred) }
        XCTAssertEqual(calls.value, 0)
        var frame: CapturedFrame? = try await service.acquire(display: display)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(pressured.snapshot.memoryBytes, frame?.imageStorageBytes)
        monitor.receive(.critical)
        try frame?.check() // Active evidence is retained, not evicted.
        frame = nil
        try await eventually { pressured.snapshot.reservations == 0 }
    }

    func testCaptureCoalescingAndQueuedCancellationReleaseBeforeConsumersResume() async throws {
        let g = governor(queue: 4), queue = CaptureAcquisitionQueue(governor: g)
        var active: CaptureAcquisitionQueue.Reservation? = try await queue.acquire(.preview)
        var tasks = [Task<CaptureAcquisitionQueue.Reservation, Error>]()
        for _ in 0..<40 {
            tasks.append(Task { try await queue.acquire(.preview) })
            try await eventually { await queue.statistics.waitingPreview == 1 }
            XCTAssertLessThanOrEqual(g.snapshot.reservations, 3)
        }
        for task in tasks { task.cancel() }
        for task in tasks {
            do { _ = try await task.value; XCTFail("Pending preview delivered") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(g.snapshot.reservations, 1)
        if let active { await queue.acquired(active) }
        active = nil
        try await eventually { g.snapshot.reservations == 0 }
    }

    func testEncodingFailureReleasesOnlyEncoderReservationAndDeletesPartialOutput() async throws {
        let g = governor(), queue = CaptureAcquisitionQueue(governor: g)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = CapturePNGEncoder(directory: root, governor: g, writer: { _, url in
            try Data([1, 2]).write(to: url)
            throw ScreenCaptureError.couldNotWriteImage
        })
        var reservation: CaptureAcquisitionQueue.Reservation? = try await queue.acquire(.evidence)
        var frame: CapturedFrame? = try CapturedFrame(image: image(), coordinates: .init(displayID: display.id,
            displayBounds: display.frame, imageSize: CGSize(width: 4, height: 4)), reservation: reservation!)
        await queue.acquired(reservation!)
        do { _ = try await encoder.encode(frame!); XCTFail("Writer did not fail") } catch {}
        XCTAssertEqual(g.snapshot.reservations, 1); XCTAssertEqual(g.snapshot.diskBytes, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        frame = nil; reservation = nil
        try await eventually { g.snapshot.reservations == 0 }
    }

    func testCancelledActiveEncodingKeepsCapacityUntilWorkerDrains() async throws {
        let g = governor(), queue = CaptureAcquisitionQueue(governor: g), blocked = BlockedWriter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { blocked.gate.signal(); try? FileManager.default.removeItem(at: root) }
        let encoder = CapturePNGEncoder(directory: root, governor: g, writer: { try blocked.write($0, $1) })
        var reservation: CaptureAcquisitionQueue.Reservation? = try await queue.acquire(.evidence)
        var frame: CapturedFrame? = try CapturedFrame(image: image(), coordinates: .init(displayID: display.id,
            displayBounds: display.frame, imageSize: CGSize(width: 4, height: 4)), reservation: reservation!)
        await queue.acquired(reservation!)
        let pending = Task { [pixels = frame!] in try await encoder.encode(pixels) }
        try await eventually { blocked.calls.value == 1 }
        XCTAssertEqual(g.snapshot.reservations, 2)
        pending.cancel()
        // A cancelled compression call has not stopped synchronous ImageIO.
        XCTAssertEqual(g.snapshot.reservations, 2)
        XCTAssertGreaterThan(g.snapshot.diskBytes, 0)
        blocked.gate.signal()
        do { _ = try await pending.value; XCTFail("Cancelled encode published") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(g.snapshot.diskBytes, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        frame = nil; reservation = nil
        try await eventually { g.snapshot.reservations == 0 }
    }

    func testEncodingRechecksSharedDiskSnapshotBeforeWriterStarts() async throws {
        let g = governor(), queue = CaptureAcquisitionQueue(governor: g), snapshots = Counter(), writes = Counter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = CapturePNGEncoder(directory: root, spaceCheck: { _, _, _ in }, governor: g,
            diskSnapshot: { _ in
                snapshots.increment()
                return .init(device: 1, available: snapshots.value == 1 ? .max : 0)
            }, writer: { _, _ in writes.increment() })
        var reservation: CaptureAcquisitionQueue.Reservation? = try await queue.acquire(.evidence)
        var frame: CapturedFrame? = try CapturedFrame(image: image(), coordinates: .init(displayID: display.id,
            displayBounds: display.frame, imageSize: CGSize(width: 4, height: 4)), reservation: reservation!)
        await queue.acquired(reservation!)
        do { _ = try await encoder.encode(frame!); XCTFail("Disk headroom changed") }
        catch let error as LocalWorkloadGovernor.Refused { XCTAssertEqual(error.reason, .diskSpace) }
        XCTAssertEqual(snapshots.value, 2); XCTAssertEqual(writes.value, 0)
        XCTAssertEqual(g.snapshot.reservations, 1); XCTAssertEqual(g.snapshot.diskBytes, 0)
        frame = nil; reservation = nil
        try await eventually { g.snapshot.reservations == 0 }
    }

    func testAccessibilityAdmissionFailsBeforeReadingAndAlwaysReleasesTraversal() throws {
        let g = governor(bytes: 100), collection = ObservationCollection<Int>(budget: 1, governor: g)
        var reads = 0
        refused(.memoryCapacity) {
            try collection.collect(roots: [.init(node: 0, scope: .init(pid: 42))], revision: "fixture", check: {}, equal: ==,
                inspect: { _, _ in reads += 1; return .init() }, children: { _, _, _ in .init(nodes: [], total: 0) })
        }
        XCTAssertEqual(reads, 0); XCTAssertEqual(g.snapshot.reservations, 0)
        let healthy = governor(bytes: 2 * 1024 * 1024), traversal = ObservationCollection<Int>(budget: 1, governor: healthy)
        XCTAssertThrowsError(try traversal.collect(roots: [.init(node: 0, scope: .init(pid: 42))], revision: "fixture",
            check: {}, equal: ==, inspect: { _, _ in throw CancellationError() }, children: { _, _, _ in .init(nodes: [], total: 0) }))
        XCTAssertEqual(healthy.snapshot.reservations, 0)
    }

    func testPipeKeepsTerminalCapacityAndReleasesAfterPartialDeliveryAndCancel() async throws {
        let g = governor(bytes: 4), queue = DispatchQueue(label: "fixture.governed-pipe"), pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let delivered = expectation(description: "Terminal frame delivered")
        var writer: RuntimePipeWriter!, output = Data(), callbacks = 0
        queue.sync {
            writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue, governor: g,
                writeOperation: { _, pointer, _ in output.append(pointer.assumingMemoryBound(to: UInt8.self).pointee); return 1 },
                failure: { XCTFail($0) })
            writer.enqueue(Data("terminal".utf8), priority: true) { success in
                XCTAssertTrue(success); callbacks += 1
                XCTAssertEqual(g.snapshot.reservations, 0); delivered.fulfill()
            }
        }
        await fulfillment(of: [delivered], timeout: 2)
        queue.sync { writer.cancel(); XCTAssertEqual(output, Data("terminal".utf8)); XCTAssertEqual(callbacks, 1) }
        XCTAssertEqual(g.snapshot.reservations, 0)
        queue.sync {
            writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue, governor: g,
                writeOperation: { _, _, _ in errno = EAGAIN; return -1 }, failure: { XCTFail($0) })
            writer.enqueue(Data([1])) { success in XCTAssertFalse(success); callbacks += 1 }
            XCTAssertEqual(g.snapshot.reservations, 1)
            writer.cancel(); writer.cancel()
            XCTAssertEqual(callbacks, 2); XCTAssertEqual(g.snapshot.reservations, 0)
        }
    }

    func testPipeAdmissionFailureSettlesOnceWithoutAnyWrite() {
        let g = governor(bytes: 0), pipe = Pipe(), queue = DispatchQueue(label: "fixture.pipe-reject")
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        var completions = 0, failures = [String]()
        queue.sync {
            let writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue, governor: g,
                writeOperation: { _, _, _ in XCTFail("Rejected frame written"); return -1 }, failure: { failures.append($0) })
            writer.enqueue(Data([1])) { XCTAssertFalse($0); completions += 1 }
            writer.cancel()
        }
        XCTAssertEqual(completions, 1); XCTAssertEqual(failures, ["transport_local_resource"])
        XCTAssertEqual(g.snapshot.reservations, 0)
    }

    func testSupervisorRejectionFailedLaunchAndTreeExitReleaseReservations() async throws {
        let rejected = governor(work: 0), process = SubprocessSupervisor(governor: rejected)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        refused(.queueCapacity) { try process.run() }
        XCTAssertEqual(process.processIdentifier, 0); XCTAssertEqual(rejected.snapshot.reservations, 0)
        let g = governor(), missing = SubprocessSupervisor(governor: g)
        missing.executableURL = URL(fileURLWithPath: "/nonexistent-synthetic-executable")
        XCTAssertThrowsError(try missing.run()); XCTAssertEqual(g.snapshot.reservations, 0)
        let live = SubprocessSupervisor(governor: g)
        live.executableURL = URL(fileURLWithPath: "/bin/sleep"); live.arguments = ["30"]
        try live.run()
        XCTAssertEqual(g.snapshot.active, 1)
        live.beginTeardown(grace: 0.01)
        guard case .finished = live.waitForTree(until: .now() + 3, ignoreInterrupt: true) else { return XCTFail("Owned fixture did not drain") }
        try await eventually { g.snapshot.reservations == 0 }
        XCTAssertEqual(g.snapshot.descriptors, 0)
    }
}
