import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class RuntimeTransportTests: XCTestCase {
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        func now() -> TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }
    func testUnterminatedFloodNeverRetainsMoreThanOneFrame() {
        var buffer = RuntimeLineBuffer(frameLimit: 64)
        XCTAssertTrue(buffer.append(Data(repeating: 0x78, count: 64)).isEmpty)
        XCTAssertNil(buffer.failureCode)
        for _ in 0..<1000 {
            XCTAssertTrue(buffer.append(Data(repeating: 0x78, count: 4096)).isEmpty)
            XCTAssertLessThanOrEqual(buffer.pendingByteCount, 64)
            XCTAssertLessThanOrEqual(buffer.retainedByteCount, 64)
        }
        XCTAssertEqual(buffer.failureCode, "transport_frame_limit")
        XCTAssertEqual(buffer.append(Data("\ncomplete\n".utf8)), [Data("complete".utf8)])
        XCTAssertEqual(buffer.retainedByteCount, 0)
    }

    func testExactLimitAndOversizedCompleteFramesAtEveryBoundary() {
        for split in 0...42 {
            var buffer = RuntimeLineBuffer(frameLimit: 16)
            let input = Data((String(repeating: "a", count: 16) + "\n" + String(repeating: "b", count: 17) + "\nlast").utf8)
            let offset = min(split, input.count)
            var lines = buffer.append(Data(input.prefix(offset)))
            lines += buffer.append(Data(input.dropFirst(offset)), flush: true)
            XCTAssertEqual(lines, [Data(repeating: 0x61, count: 16), Data("last".utf8)])
            XCTAssertEqual(buffer.failureCode, "transport_frame_limit")
        }
    }

    func testAggregateBatchLimitsDoNotAllocateAnUnboundedLineArray() {
        var buffer = RuntimeLineBuffer(frameLimit: 16, batchLimit: 64)
        let lines = buffer.append(Data(String(repeating: "12345678\n", count: 10000).utf8), flush: true)
        XCTAssertEqual(lines.count, 8)
        XCTAssertEqual(buffer.failureCode, "transport_buffer_limit")
        XCTAssertEqual(buffer.retainedByteCount, 0)
    }

    func testTinyFrameFloodAlsoHasAnObjectCountLimit() {
        var buffer = RuntimeLineBuffer()
        let lines = buffer.append(Data(String(repeating: "x\n", count: 100000).utf8))
        XCTAssertEqual(lines.count, 65536)
        XCTAssertEqual(buffer.failureCode, "transport_buffer_limit")
    }

    func testNonblockingWriterPreservesFrameOrderAndTerminalSlot() throws {
        let queue = DispatchQueue(label: "fixture.writer")
        let pipe = Pipe(); let delivered = expectation(description: "All writes")
        delivered.expectedFulfillmentCount = 3
        var writer: RuntimePipeWriter!
        queue.sync {
            writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue,
                                       byteLimit: 100, reserve: 40) { code in XCTFail(code) }
            writer.enqueue(Data(repeating: 0x61, count: 30)) { success in XCTAssertTrue(success); delivered.fulfill() }
            writer.enqueue(Data(repeating: 0x62, count: 30)) { success in XCTAssertTrue(success); delivered.fulfill() }
            writer.enqueue(Data(repeating: 0x63, count: 40), priority: true) { success in XCTAssertTrue(success); delivered.fulfill() }
            XCTAssertEqual(writer.pendingBytes, 100)
        }
        wait(for: [delivered], timeout: 1)
        let bytes = try pipe.fileHandleForReading.read(upToCount: 100)
        XCTAssertEqual(bytes, Data(repeating: 0x61, count: 30) + Data(repeating: 0x62, count: 30) + Data(repeating: 0x63, count: 40))
        queue.sync { XCTAssertEqual(writer.pendingBytes, 0); writer.cancel() }
    }

    func testWriterCompactsConsumedPrefixWithoutChangingFIFOOrCompletions() throws {
        let queue = DispatchQueue(label: "fixture.writer.compaction"), pipe = Pipe()
        let frameCount = 512, delivered = expectation(description: "Every frame completes in order")
        delivered.expectedFulfillmentCount = frameCount
        var callbacks: [Int] = []
        var writer: RuntimePipeWriter!
        queue.sync {
            writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue,
                                       byteLimit: 1_024, reserve: 128) { code in XCTFail(code) }
            for value in 0..<frameCount {
                writer.enqueue(Data([UInt8(value % 256)])) { success in
                    XCTAssertTrue(success)
                    callbacks.append(value)
                    delivered.fulfill()
                }
            }
            XCTAssertEqual(writer.pendingBytes, frameCount)
        }
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(callbacks, Array(0..<frameCount))
        let bytes = try pipe.fileHandleForReading.read(upToCount: frameCount)
        XCTAssertEqual(bytes, Data((0..<frameCount).map { UInt8($0 % 256) }))
        queue.sync { XCTAssertEqual(writer.pendingBytes, 0); writer.cancel() }
    }

    func testWriterQueueWaitEndsAtFirstWriteAndSeparatesPendingCancellation() {
        let queue = DispatchQueue(label: "fixture.writer.queue-wait"), pipe = Pipe()
        let clock = FakeClock(), telemetry = BackendTelemetry(now: { clock.now() })
        let delivered = expectation(description: "First frame delivered")
        var writer: RuntimePipeWriter!
        queue.sync {
            writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue, telemetry: telemetry) { XCTFail($0) }
            writer.enqueue(Data("first".utf8)) { success in XCTAssertTrue(success); delivered.fulfill() }
            clock.advance(0.004) // Hold the serial queue before the write source can run.
        }
        wait(for: [delivered], timeout: 1)
        queue.sync {
            writer.enqueue(Data("cancelled".utf8)) { success in XCTAssertFalse(success) }
            clock.advance(0.002)
            writer.cancel() // Cancellation wins before the queued write callback.
        }
        let histogram = telemetry.queueWaitHistograms().first { $0.queue == .pipeFirstWrite }
        XCTAssertEqual(histogram?.countsByDisposition[.started]?[2], 1)
        XCTAssertEqual(histogram?.countsByDisposition[.cancelled]?[2], 1)
        queue.sync { writer.cancel() }
    }

    func testBlockedWriterHasBoundedDeadlineWithoutBlockingOwningQueue() {
        let queue = DispatchQueue(label: "fixture.blocked.writer"), pipe = Pipe()
        let failed = expectation(description: "Write deadline"), responsive = expectation(description: "Queue remains responsive")
        var writer: RuntimePipeWriter!
        queue.sync {
            writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue, timeout: 0.05) { code in
                XCTAssertEqual(code, "transport_write_timeout"); failed.fulfill()
            }
            writer.enqueue(Data(repeating: 0x61, count: 1024 * 1024))
        }
        queue.async { responsive.fulfill() }
        wait(for: [responsive, failed], timeout: 1)
        queue.sync { XCTAssertEqual(writer.pendingBytes, 0) }
    }

    func testWriterOverflowRejectsAllPendingFramesExactlyOnce() {
        let queue = DispatchQueue(label: "fixture.writer.overflow"), pipe = Pipe()
        let telemetry = BackendTelemetry()
        var outcomes: [Bool] = [], failures: [String] = []
        queue.sync {
            let writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue, byteLimit: 100, reserve: 40,
                telemetry: telemetry) { failures.append($0) }
            writer.enqueue(Data(repeating: 0x61, count: 60)) { outcomes.append($0) }
            writer.enqueue(Data(repeating: 0x62, count: 1)) { outcomes.append($0) }
            writer.cancel()
            XCTAssertEqual(writer.pendingBytes, 0)
        }
        XCTAssertEqual(outcomes, [false, false]); XCTAssertEqual(failures, ["transport_buffer_limit"])
        let histogram = telemetry.queueWaitHistograms().first { $0.queue == .pipeFirstWrite }
        XCTAssertEqual(histogram?.countsByDisposition[.rejected]?.reduce(0, +), 1)
        XCTAssertEqual(histogram?.countsByDisposition[.cancelled]?.reduce(0, +), 1)
    }

    func testCancellationWakesWriterWithoutWaitingForItsDeadline() {
        let queue = DispatchQueue(label: "fixture.writer.stop"), pipe = Pipe()
        let cancelled = expectation(description: "Cancelled write")
        queue.sync {
            let writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue) { XCTFail($0) }
            writer.enqueue(Data(repeating: 0x61, count: 1024 * 1024)) { delivered in
                XCTAssertFalse(delivered); cancelled.fulfill()
            }
            writer.cancel(); writer.cancel()
        }
        wait(for: [cancelled], timeout: 1)
    }

    func testClosedReadPipeReportsFailureInsteadOfRaisingSIGPIPE() throws {
        let queue = DispatchQueue(label: "fixture.closed.pipe"), pipe = Pipe()
        try pipe.fileHandleForReading.close()
        let failed = expectation(description: "Broken pipe classified")
        var writer: RuntimePipeWriter!
        queue.sync {
            writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue) { code in
                XCTAssertEqual(code, "transport_closed"); failed.fulfill()
            }
            writer.enqueue(Data("frame\n".utf8))
        }
        wait(for: [failed], timeout: 1)
        queue.sync { writer.cancel() }
    }

    private var display: DisplayDescriptor { DisplayDescriptor(id: 1, name: "fixture", x: 0, y: 0, width: 10, height: 10, isMain: false) }
    private func bridge() -> AgentAutomationBridge {
        AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
    }
    private func helper(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime")
        let boundaryVersion = StopBoundaryPolicy.version
        try ("""
        #!/usr/bin/python3
        import json, sys, time, signal
        config = json.loads(sys.stdin.readline())
        assert config.get('stop_boundary_policy_version') == \(boundaryVersion)
        def emit(kind, **fields):
            print(json.dumps(dict(kind=kind, task_generation_id=config['task_generation_id'],
                instruction_revision=fields.pop('instruction_revision', 0),
                working_document_revision=0, **fields)), flush=True)
        """ + "\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @MainActor func testOversizedUnterminatedHelperOutputFailsWithoutAnAction() async throws {
        let executable = try helper("sys.stdout.write('x' * (8*1024*1024+1)); sys.stdout.flush(); time.sleep(20)")
        let failed = expectation(description: "Classified framing failure")
        var actions = 0, terminalCount = 0
        let runtime = AgentRuntimeProcess(bridge: bridge(), bridgeHandler: { _ in actions += 1; return [:] })
        runtime.onEvent = { event in
            if case .failed(let message) = event {
                XCTAssertTrue(message.contains("transport_frame_limit")); terminalCount += 1; failed.fulfill()
            }
            if case .completed = event { XCTFail("Oversized output completed") }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: executable, openClawURL: executable, geminiAPIKey: "")
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(actions, 0); XCTAssertEqual(terminalCount, 1)
    }

    @MainActor func testRepeatedStatusFloodCannotHideCompletion() async throws {
        let executable = try helper("for _ in range(20000): emit('status', message='same')\nemit('complete', message='finished')")
        let completed = expectation(description: "Terminal survives status flood")
        var statuses = 0, terminalCount = 0
        let runtime = AgentRuntimeProcess(bridge: bridge())
        runtime.onEvent = { event in
            if case .status = event { statuses += 1 }
            if case .completed(let message) = event { XCTAssertEqual(message, "finished"); terminalCount += 1; completed.fulfill() }
            if case .failed(let message) = event { XCTFail(message) }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: executable, openClawURL: executable, geminiAPIKey: "")
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(statuses, 1); XCTAssertEqual(terminalCount, 1)
    }

    @MainActor func testStopIsResponsiveWhenHelperDoesNotReadNativeReplies() async throws {
        let executable = try helper("emit('bridge_request', request_id='large', method='fixture', params={})\ntime.sleep(20)")
        let dispatched = expectation(description: "Response queued"), stopped = expectation(description: "Stop delivered")
        let runtime = AgentRuntimeProcess(bridge: bridge(), bridgeHandler: { request in
            dispatched.fulfill()
            return ["kind": "bridge_response", "task_generation_id": request["task_generation_id"]!,
                    "request_id": request["request_id"]!, "result": String(repeating: "x", count: 1024 * 1024)]
        })
        runtime.onEvent = { if case .stopped = $0 { stopped.fulfill() } }
        try runtime.start(task: "fixture", display: display, runtimeURL: executable, openClawURL: executable, geminiAPIKey: "")
        await fulfillment(of: [dispatched], timeout: 3)
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = ContinuousClock.now
        runtime.stop()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(0.5))
        await fulfillment(of: [stopped], timeout: 3)
    }

    @MainActor func testTransportFailureReconcilesDispatchedReceiptWithoutRepeatingIt() async throws {
        let id = UUID().uuidString.lowercased(), lease = TaskLease()
        let executable = try helper("emit('bridge_request', request_id='action', method='act', params={'action_id':'\(id)'})\ntime.sleep(20)")
        let failed = expectation(description: "Receipt inspected after failure")
        var actions = 0
        let runtime = AgentRuntimeProcess(bridge: bridge(), bridgeHandler: { _ in
            actions += 1
            let claim = try! lease.actionReceipts.begin(id: id, payload: ["type": "press", "element_id": "fixture:button"])
            if case .new(let token) = claim {
                try! token.dispatched()
                token.fail(CancellationError(), code: "cancelled")
            }
            return ["kind": "bridge_response", "task_generation_id": lease.id,
                    "result": String(repeating: "x", count: 8 * 1024 * 1024 + 1)]
        })
        runtime.onEvent = { event in
            if case .failed(let message) = event {
                XCTAssertTrue(message.contains("transport_frame_limit")); XCTAssertTrue(message.contains("could not be confirmed")); failed.fulfill()
            }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: executable, openClawURL: executable, geminiAPIKey: "", lease: lease)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(actions, 1)
    }

    @MainActor func testStopEscalatesIfMalformedHelperIgnoresTermination() async throws {
        let executable = try helper("signal.signal(signal.SIGTERM, signal.SIG_IGN)\nemit('status', message='ready')\nwhile True: time.sleep(1)")
        let ready = expectation(description: "Helper ready"), stopped = expectation(description: "Escalated Stop")
        let runtime = AgentRuntimeProcess(bridge: bridge())
        runtime.onEvent = { event in
            if case .status(let message) = event, message == "ready" { ready.fulfill() }
            if case .stopped = event { stopped.fulfill() }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: executable, openClawURL: executable, geminiAPIKey: "")
        await fulfillment(of: [ready], timeout: 3)
        runtime.stop()
        await fulfillment(of: [stopped], timeout: 4)
    }
}
