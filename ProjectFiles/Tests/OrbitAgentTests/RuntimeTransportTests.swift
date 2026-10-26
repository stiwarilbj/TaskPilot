import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class RuntimeTransportTests: XCTestCase {
    private struct PartialWriteState {
        var calls = 0
        var bytesWritten = 0
        var blocked = false
    }

    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        func now() -> TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }
    func testExpiredAdmissionNeverBuildsPayloadAndSettlesOnce() {
        let queue = DispatchQueue(label: "fixture.expired-admission"), pipe = Pipe(), clock = FakeClock()
        let telemetry = BackendTelemetry(now: { clock.now() })
        let budget = LocalOperationBudget(seconds: 1, phase: "preflight", now: { clock.now() })
        var builds = 0, callbacks = 0, failures: [String] = []
        func payload() -> Data { builds += 1; return Data(repeating: 1, count: 100_000) }
        clock.advance(1)
        queue.sync {
            let writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue, telemetry: telemetry) { failures.append($0) }
            writer.enqueue(payload(), budget: budget) { success in XCTAssertFalse(success); callbacks += 1 }
            XCTAssertEqual(writer.pendingBytes, 0); writer.cancel()
        }
        XCTAssertEqual(builds, 0); XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(failures, ["transport_local_deadline"])
        let histogram = telemetry.queueWaitHistograms().first { $0.queue == .pipeFirstWrite }
        XCTAssertEqual(histogram?.countsByDisposition[.rejected]?.reduce(0, +), 1)
        XCTAssertNil(histogram?.countsByDisposition[.started])
    }

    func testExpiryDuringPayloadConstructionCannotEnqueueOrWrite() {
        let queue = DispatchQueue(label: "fixture.payload-expiry"), pipe = Pipe(), clock = FakeClock()
        let budget = LocalOperationBudget(seconds: 1, phase: "preflight", now: { clock.now() })
        var callbacks = 0
        func payload() -> Data { clock.advance(1); return Data([1]) }
        queue.sync {
            let writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue,
                writeOperation: { _, _, _ in XCTFail("Expired frame written"); return 0 }) {
                    XCTAssertEqual($0, "transport_local_deadline")
                }
            writer.enqueue(payload(), budget: budget) { XCTAssertFalse($0); callbacks += 1 }
            XCTAssertEqual(writer.pendingBytes, 0); writer.cancel()
        }
        XCTAssertEqual(callbacks, 1)
    }

    func testExpiredQueuedFrameIsDroppedBeforeWriteButNextFrameCompletes() throws {
        let queue = DispatchQueue(label: "fixture.queued-expiry"), pipe = Pipe(), clock = FakeClock()
        let budget = LocalOperationBudget(seconds: 1, phase: "preflight", now: { clock.now() })
        let settled = expectation(description: "Both settled"); settled.expectedFulfillmentCount = 2
        var writer: RuntimePipeWriter!, failures: [String] = []
        queue.sync {
            writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue) { failures.append($0) }
            writer.enqueue(Data("expired".utf8), budget: budget) { XCTAssertFalse($0); settled.fulfill() }
            writer.enqueue(Data("next".utf8)) { XCTAssertTrue($0); settled.fulfill() }
            clock.advance(1) // The queue is held until after expiry.
        }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(try pipe.fileHandleForReading.read(upToCount: 4), Data("next".utf8))
        queue.sync { XCTAssertEqual(writer.pendingBytes, 0); XCTAssertEqual(failures, ["transport_local_deadline"]); writer.cancel() }
    }

    func testPartialFrameFinishesAfterLocalDeadlineWithoutTruncation() {
        let queue = DispatchQueue(label: "fixture.partial-expiry"), pipe = Pipe(), clock = FakeClock()
        let budget = LocalOperationBudget(seconds: 1, phase: "preflight", now: { clock.now() })
        let settled = expectation(description: "Frame completed")
        var writer: RuntimePipeWriter!, bytes = Data(), calls = 0
        queue.sync {
            writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue, writeOperation: { _, pointer, count in
                calls += 1
                let length = calls == 1 ? 1 : count
                bytes.append(pointer.assumingMemoryBound(to: UInt8.self), count: length)
                clock.advance(2)
                return length
            }) { XCTFail($0) }
            writer.enqueue(Data("complete-frame".utf8), budget: budget) { XCTAssertTrue($0); settled.fulfill() }
        }
        wait(for: [settled], timeout: 2)
        queue.sync { XCTAssertEqual(bytes, Data("complete-frame".utf8)); XCTAssertEqual(calls, 2); writer.cancel() }
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

    func testSeededPartialWritesRaceReaderDrainAgainstCancellation() async throws {
        var observedOrders = Set<String>()
        var replayBySeed: [UInt64: (raceOrder: String, callback: Bool)] = [:]
        for seed: UInt64 in [1, 2, 1, 2] {
            let queue = DispatchQueue(label: "fixture.seeded-writer.\(seed)")
            let pipe = Pipe()
            let readFD = pipe.fileHandleForReading.fileDescriptor
            let oldFlags = fcntl(readFD, F_GETFL)
            XCTAssertGreaterThanOrEqual(oldFlags, 0)
            XCTAssertNotEqual(fcntl(readFD, F_SETFL, oldFlags | O_NONBLOCK), -1)
            let payload = Data((0..<2 * 1024 * 1024).map { UInt8($0 % 251) })
            let writeState = LockedTestValue(PartialWriteState())
            let callbacks = LockedTestValue<[Bool]>([])
            let cancelled = LockedTestValue(false)
            let readerReleased = LockedTestValue(false)
            let completion = DeterministicAsyncLatch()
            let scheduler = SeededLifecycleScheduler(seed: seed)
            var writer: RuntimePipeWriter!

            queue.sync {
                writer = RuntimePipeWriter(handle: pipe.fileHandleForWriting, queue: queue, timeout: 5,
                    writeOperation: { descriptor, pointer, requested in
                        if !readerReleased.read() && writeState.read().bytesWritten >= 32 * 1024 {
                            writeState.update { $0.blocked = true }
                            errno = EAGAIN
                            return -1
                        }
                        let result = Darwin.write(descriptor, pointer, min(requested, 4096))
                        if result > 0 {
                            writeState.update { $0.calls += 1; $0.bytesWritten += result }
                        } else if result < 0 {
                            let savedErrno = errno
                            writeState.update { $0.blocked = savedErrno == EAGAIN || savedErrno == EWOULDBLOCK }
                            errno = savedErrno
                        }
                        return result
                    }, failure: { XCTFail("seed=\(seed): \($0)") })
                writer.enqueue(payload) { success in
                    callbacks.update { $0.append(success) }
                    completion.signal()
                }
            }

            let writeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !writeState.read().blocked && ContinuousClock.now < writeDeadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(writeState.read().blocked, "writer should reach EAGAIN before the seeded race; seed=\(seed)")
            XCTAssertGreaterThan(writeState.read().calls, 1, "write injection must force partial writes; seed=\(seed)")
            XCTAssertLessThan(writeState.read().bytesWritten, payload.count)

            scheduler.schedule(at: 10, name: "drain-reader") {
                readerReleased.update { $0 = true }
                let target = cancelled.read() ? writeState.read().bytesWritten : payload.count
                var received = Data(); received.reserveCapacity(target)
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while received.count < target {
                    let amount = Darwin.read(readFD, &buffer, buffer.count)
                    if amount > 0 {
                        received.append(contentsOf: buffer.prefix(amount))
                    } else if amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                        try? await Task.sleep(for: .milliseconds(1))
                    } else {
                        XCTFail("unexpected pipe read result \(amount); seed=\(seed)")
                        return
                    }
                }
                if !cancelled.read() { await completion.wait() }
                let expected = cancelled.read() ? Data(payload.prefix(target)) : payload
                XCTAssertEqual(received, expected, "FIFO bytes changed during partial writes; seed=\(seed)")
            }
            scheduler.schedule(at: 10, name: "cancel-writer") {
                queue.sync {
                    cancelled.update { $0 = true }
                    writer.cancel()
                }
                await completion.wait()
            }
            await scheduler.runAll()

            let raceOrder = scheduler.trace.filter { $0 == "drain-reader" || $0 == "cancel-writer" }
            XCTAssertEqual(raceOrder.count, 2, "seed=\(seed)")
            observedOrders.insert(raceOrder.joined(separator: ","))
            XCTAssertEqual(callbacks.read(), [raceOrder.first == "drain-reader"], "completion must occur once; seed=\(seed)")
            XCTAssertGreaterThanOrEqual(scheduler.clock.now, 10)
            let current = (raceOrder: raceOrder.joined(separator: ","), callback: callbacks.read().first ?? false)
            if let previous = replayBySeed[seed] {
                XCTAssertEqual(current.raceOrder, previous.raceOrder, "same seed changed write race order; seed=\(seed)")
                XCTAssertEqual(current.callback, previous.callback, "same seed changed completion result; seed=\(seed)")
            }
            replayBySeed[seed] = current
            queue.sync { writer.cancel() }
            try pipe.fileHandleForReading.close()
            try pipe.fileHandleForWriting.close()
        }
        XCTAssertEqual(observedOrders, ["drain-reader,cancel-writer", "cancel-writer,drain-reader"])
    }

    @MainActor
    func testSeededRuntimeStopAndTerminalCallbackRaceIsReproducible() async throws {
        var observedOutcomes = Set<String>()
        var replayBySeed: [UInt64: (raceOrder: String, outcome: String)] = [:]
        for seed: UInt64 in [1, 2, 1, 2] {
            let gate = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-runtime-gate-\(UUID().uuidString)")
            let executable = try helper("""
            import os
            gate = \(String(reflecting: gate.path))
            while not os.path.exists(gate): time.sleep(0.002)
            emit('complete', message='finished')
            """)
            let scheduler = SeededLifecycleScheduler(seed: seed)
            let callbackQueued = DeterministicAsyncLatch()
            let terminalDelivered = DeterministicAsyncLatch()
            let terminalResult = LockedTestValue<[String]>([])
            let runtime = AgentRuntimeProcess(bridge: bridge())
            runtime.onEvent = { event in
                let value: String
                switch event {
                case .completed: value = "completed"
                case .stopped: value = "stopped"
                case .failed(let message): value = "failed:\(message)"
                default: return
                }
                scheduler.schedule(after: 5, name: "deliver-runtime-terminal-callback") {
                    terminalResult.update { $0.append(value) }
                    terminalDelivered.signal()
                }
                callbackQueued.signal()
            }
            try runtime.start(task: "seeded fixture", display: display, runtimeURL: executable,
                              openClawURL: executable, geminiAPIKey: "")
            scheduler.schedule(at: 5, name: "helper-terminal") {
                FileManager.default.createFile(atPath: gate.path, contents: Data())
                await callbackQueued.wait()
            }
            scheduler.schedule(at: 5, name: "stop-runtime") {
                runtime.stop()
                await callbackQueued.wait()
            }
            await scheduler.runAll()
            await terminalDelivered.wait()
            try await Task.sleep(for: .milliseconds(50))

            let raceOrder = scheduler.trace.filter { $0 == "helper-terminal" || $0 == "stop-runtime" }
            XCTAssertEqual(raceOrder.count, 2, "seed=\(seed)")
            let expected = raceOrder.first == "helper-terminal" ? "completed" : "stopped"
            XCTAssertEqual(terminalResult.read(), [expected], "terminal event must be delivered once; seed=\(seed)")
            observedOutcomes.insert(expected)
            XCTAssertGreaterThanOrEqual(scheduler.clock.now, 5)
            let current = (raceOrder: raceOrder.joined(separator: ","), outcome: expected)
            if let previous = replayBySeed[seed] {
                XCTAssertEqual(current.raceOrder, previous.raceOrder, "same seed changed runtime event order; seed=\(seed)")
                XCTAssertEqual(current.outcome, previous.outcome, "same seed changed terminal outcome; seed=\(seed)")
            }
            replayBySeed[seed] = current
        }
        XCTAssertEqual(observedOutcomes, ["completed", "stopped"])
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

    @MainActor func testRuntimeLaunchClosesUnrelatedDescriptorsAndDrainsFinalCompletion() async throws {
        let source = open("/dev/null", O_RDONLY)
        guard source >= 0 else { return XCTFail("Cannot open sentinel") }
        defer { close(source) }
        let unrelated = fcntl(source, F_DUPFD, 256)
        guard unrelated >= 0 else { return XCTFail("Cannot duplicate sentinel") }
        defer { close(unrelated) }
        let executable = try helper("""
        import os, errno
        try: os.fstat(\(unrelated))
        except OSError as error: assert error.errno == errno.EBADF
        else: raise AssertionError('unrelated descriptor inherited')
        emit('bridge_request', request_id='gate', method='completion_gate', params={})
        response = json.loads(sys.stdin.readline())
        assert response.get('ok') and response.get('result', {}).get('accepted') is True
        frame = dict(kind='complete', message='isolated and drained',
                     task_generation_id=config['task_generation_id'], instruction_revision=0,
                     working_document_revision=0)
        sys.stdout.write(json.dumps(frame))
        sys.stderr.write('final diagnostic')
        """)
        let terminal = expectation(description: "Final completion drained")
        var terminalCount = 0
        let runtime = AgentRuntimeProcess(bridge: bridge()) { request in
            XCTAssertEqual(request["method"] as? String, "completion_gate")
            let owner = TaskOwnership.current!
            return ["kind": "bridge_response", "task_generation_id": owner.id,
                    "request_id": request["request_id"]!, "ok": true,
                    "result": ["accepted": owner.claimCompletion(instructionRevision: 0)]]
        }
        runtime.onEvent = { event in
            if case .completed(let message) = event {
                XCTAssertEqual(message, "isolated and drained"); terminalCount += 1; terminal.fulfill()
            }
            if case .failed(let message) = event { XCTFail(message); terminal.fulfill() }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: executable, openClawURL: executable, geminiAPIKey: "")
        await fulfillment(of: [terminal], timeout: 5)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(fcntl(unrelated, F_GETFD), 0)
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
