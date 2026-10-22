import CoreGraphics
import Foundation
import XCTest
@testable import OrbitAgent

final class BackendTelemetryTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = 0.0
        func now() -> Double { lock.withLock { time } }
        func advance(_ seconds: Double) { lock.withLock { time += seconds } }
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testNumericMetadataAndFinishAreExactlyOnce() throws {
        let clock = Clock(), telemetry = BackendTelemetry(now: { clock.now() })
        let span = telemetry.begin(.capture, inputBytes: -1, items: 4)
        clock.advance(0.025)
        span.record(outputBytes: 32)
        span.finish(.succeeded)
        clock.advance(4)
        span.record(outputBytes: 900)
        span.finish(.failed)
        let sample = try XCTUnwrap(telemetry.samples().first)
        XCTAssertEqual(telemetry.samples().count, 1)
        XCTAssertEqual(sample.seconds, 0.025, accuracy: 0.000001)
        XCTAssertNil(sample.inputBytes)
        XCTAssertEqual(sample.outputBytes, 32)
        XCTAssertEqual(sample.items, 4)
        XCTAssertEqual(sample.outcome, .succeeded)
    }
    func testFailuresCancellationAndAbandonmentRemainDistinct() throws {
        enum FixtureError: Error { case failed }
        let telemetry = BackendTelemetry()
        XCTAssertThrowsError(try telemetry.measure(.startup) { _ in throw FixtureError.failed }) {
            XCTAssertTrue($0 is FixtureError)
        }
        XCTAssertThrowsError(try telemetry.measure(.capture) { _ in throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
        var abandoned: BackendTelemetry.Span? = telemetry.begin(.ipcBridge)
        XCTAssertNotNil(abandoned)
        abandoned = nil
        XCTAssertEqual(telemetry.samples().map(\.outcome), [.failed, .cancelled, .abandoned])
        XCTAssertTrue(telemetry.summaries().isEmpty)
    }
    func testSuccessfulPercentilesAndPerPhaseRetention() throws {
        let clock = Clock(), telemetry = BackendTelemetry(capacity: 20, now: { clock.now() })
        for value in 1...21 {
            telemetry.measure(.jsonEncoding) { _ in clock.advance(Double(value) / 1000) }
        }
        let failed = telemetry.begin(.jsonEncoding)
        clock.advance(9)
        failed.finish(.failed)
        telemetry.measure(.commandLaunch) { _ in clock.advance(0.003) }
        let summary = try XCTUnwrap(telemetry.summaries().first { $0.phase == .jsonEncoding })
        // Last 20 samples retain successful durations 3...21 and the failure.
        XCTAssertEqual(summary.samples, 19)
        XCTAssertEqual(summary.medianMilliseconds, 12, accuracy: 0.000001)
        XCTAssertEqual(summary.p95Milliseconds, 21, accuracy: 0.000001)
        XCTAssertEqual(telemetry.samples().count, 21)
    }
    func testConcurrentFinishesAreBoundedAndUnique() {
        let telemetry = BackendTelemetry(capacity: 16)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let span = telemetry.begin(.ipcReceive, inputBytes: 12)
            DispatchQueue.concurrentPerform(iterations: 2) { _ in span.finish(.succeeded) }
        }
        XCTAssertEqual(telemetry.samples().count, 16)
        XCTAssertTrue(telemetry.samples().allSatisfy { $0.inputBytes == 12 && $0.outcome == .succeeded })
    }
    func testJSONContentCannotAppearInTelemetrySerialization() throws {
        let telemetry = BackendTelemetry()
        let sentinel = "private-fixture-secret-command-path"
        let data = try telemetry.encodeJSON(["content": sentinel])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: String])?["content"], sentinel)
        let metrics = try JSONEncoder().encode(telemetry.samples())
        XCTAssertFalse(String(decoding: metrics, as: UTF8.self).contains(sentinel))
        let keys = try XCTUnwrap((JSONSerialization.jsonObject(with: metrics) as? [[String: Any]])?.first).keys
        XCTAssertEqual(Set(keys), Set(["phase", "outcome", "seconds", "outputBytes"]))
        XCTAssertEqual(telemetry.samples().first?.outputBytes, data.count)
        let credentialFrame = BackendTelemetry()
        _ = try credentialFrame.encodeJSON(["value": sentinel], recordSize: false)
        XCTAssertNil(credentialFrame.samples().first?.outputBytes)
    }
    func testLedgerMeasurementKeepsRoundTripPermissionsAndFailures() throws {
        let root = try fixture(), telemetry = BackendTelemetry()
        let store = AgentTaskLedgerStore(fileURL: root.appendingPathComponent("ledger.json"))
        try BackendTelemetry.$current.withValue(telemetry) {
            XCTAssertEqual(try store.load(), AgentTaskLedgerSnapshot())
            let queue = [QueuedAgentTask(request: "fixture-only", queuedAt: Date(timeIntervalSince1970: 1_700_000_000))]
            try store.save(queue: queue, history: [])
            XCTAssertEqual(try store.load().queue, queue)
            let size = try Data(contentsOf: store.fileURL).count
            XCTAssertEqual(telemetry.samples().first { $0.phase == .persistenceWrite }?.outputBytes, size)
            XCTAssertEqual(telemetry.samples().filter { $0.phase == .persistenceRead }.last?.inputBytes, size)
            let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o600)
            try Data("malformed".utf8).write(to: store.fileURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(telemetry.samples().filter { $0.phase == .persistenceRead }.last?.outcome, .failed)
            XCTAssertEqual(telemetry.samples().filter { $0.phase == .jsonDecoding }.last?.outcome, .failed)
        }
    }
    func testCollectionCountsAcceptedControlsAndClosesOnCancellation() throws {
        let telemetry = BackendTelemetry()
        try BackendTelemetry.$current.withValue(telemetry) {
            let collection = ObservationCollection<Int>(budget: 1)
            try collection.collect(roots: [.init(node: 0, scope: .init(pid: 42))], revision: "fixture", check: {},
                equal: ==, identityHash: { UInt($0) }, inspect: { _, _ in .init() }, children: { entry, _, _ in
                    .init(nodes: entry.node == 0 ? [1, 2] : [], total: entry.node == 0 ? 2 : 0)
                })
            XCTAssertEqual(telemetry.samples().first?.items, 3)
            XCTAssertThrowsError(try collection.collect(roots: [], revision: "fixture", check: { throw CancellationError() },
                equal: ==, identityHash: { UInt($0) }, inspect: { _, _ in .init() }, children: { _, _, _ in .init(nodes: [], total: 0) }))
            XCTAssertEqual(telemetry.samples().last?.outcome, .cancelled)
        }
    }
    func testCommandLaunchDoesNotIncludeCommandExecution() async throws {
        let telemetry = BackendTelemetry()
        try await BackendTelemetry.$current.withValue(telemetry) {
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": ["/bin/sleep", "0.2"]])
            XCTAssertEqual(result["exit_code"] as? Int, 0)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let launch = try XCTUnwrap(telemetry.samples().first { $0.phase == .commandLaunch })
            XCTAssertEqual(launch.items, 1) // Arguments exclude the executable.
            XCTAssertEqual(launch.outcome, .succeeded)
            XCTAssertGreaterThan(elapsed - launch.seconds, 0.15)
        }
    }
}

/// Offline only: never collects the desktop, contacts a provider, or dispatches GUI input.
final class BackendPhaseFixtureTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func helper(_ root: URL, body: String) throws -> URL {
        let url = root.appendingPathComponent("helper")
        try ("""
        #!/usr/bin/python3
        import json, sys
        config=json.loads(sys.stdin.readline())
        def emit(kind, **fields):
            print(json.dumps(dict(kind=kind, task_generation_id=config['task_generation_id'], **fields)), flush=True)
        """ + "\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func bridge() -> AgentAutomationBridge {
        AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
    }
    private var display: DisplayDescriptor { .init(id: 1, name: "fixture", x: 0, y: 0, width: 10, height: 10, isMain: false) }
    @MainActor private func runHelper(_ helper: URL, telemetry: BackendTelemetry, failing: Bool = false) async throws {
        let ended = expectation(description: "Disposable helper drained")
        let runtime = BackendTelemetry.$current.withValue(telemetry) {
            AgentRuntimeProcess(bridge: bridge(), memoryPressure: MemoryPressureMonitor(listen: false)) { request in
                ["kind": "bridge_response", "task_generation_id": request["task_generation_id"]!,
                 "request_id": request["request_id"]!, "ok": true]
            }
        }
        runtime.onEvent = { event in
            switch event {
            case .completed: XCTAssertFalse(failing); ended.fulfill()
            case .failed: XCTAssertTrue(failing); ended.fulfill()
            default: break
            }
        }
        try runtime.start(task: "synthetic fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "")
        await fulfillment(of: [ended], timeout: 5)
        runtime.stop()
    }
    @MainActor func testRuntimeStartupAndOwnedIPCIntervals() async throws {
        let root = try fixture(), telemetry = BackendTelemetry()
        let url = try helper(root, body: """
        emit('runtime_ready', memory_pressure_version=1)
        emit('bridge_request', request_id='fixture', method='fixture', params={})
        reply=json.loads(sys.stdin.readline())
        assert reply['ok'] and reply['task_generation_id']==config['task_generation_id']
        emit('complete', message='fixture complete')
        """)
        try await runHelper(url, telemetry: telemetry)
        for phase in [BackendTelemetry.Phase.startup, .ipcBridge] {
            let rows = telemetry.samples().filter { $0.phase == phase }
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.outcome, .succeeded)
        }
        XCTAssertEqual(telemetry.samples().filter { $0.phase == .ipcSend }.count, 2)
        XCTAssertEqual(telemetry.samples().filter { $0.phase == .ipcReceive }.count, 3)
        XCTAssertGreaterThan(telemetry.samples().first { $0.phase == .ipcBridge }?.outputBytes ?? 0, 0)
    }
    @MainActor func testStartupFailureAndMissingRuntimeCloseIntervals() async throws {
        let root = try fixture(), telemetry = BackendTelemetry()
        let url = try helper(root, body: "sys.exit(2)")
        try await runHelper(url, telemetry: telemetry, failing: true)
        XCTAssertEqual(telemetry.samples().filter { $0.phase == .startup }.first?.outcome, .failed)
        let runtime = BackendTelemetry.$current.withValue(telemetry) { AgentRuntimeProcess(bridge: bridge()) }
        XCTAssertThrowsError(try runtime.start(task: "fixture", display: display, runtimeURL: root.appendingPathComponent("missing"), openClawURL: url, geminiAPIKey: ""))
        XCTAssertEqual(telemetry.samples().filter { $0.phase == .startup }.count, 2)
        XCTAssertEqual(telemetry.samples().filter { $0.phase == .startup }.last?.outcome, .failed)
    }
    @MainActor func testStopBeforeReadinessClosesStartupOnce() async throws {
        let root = try fixture(), telemetry = BackendTelemetry()
        let url = try helper(root, body: "import time; time.sleep(20)")
        let stopped = expectation(description: "Startup stopped")
        let runtime = BackendTelemetry.$current.withValue(telemetry) { AgentRuntimeProcess(bridge: bridge()) }
        runtime.onEvent = { if case .stopped = $0 { stopped.fulfill() } }
        try runtime.start(task: "fixture", display: display, runtimeURL: url, openClawURL: url, geminiAPIKey: "")
        runtime.stop()
        await fulfillment(of: [stopped], timeout: 5)
        let rows = telemetry.samples().filter { $0.phase == .startup }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.outcome, .cancelled)
    }
    @MainActor func testRevokedBridgeClosesWithoutWritingItsResponse() async throws {
        let root = try fixture(), telemetry = BackendTelemetry()
        let url = try helper(root, body: "emit('bridge_request', request_id='fixture', method='fixture', params={})\nimport time; time.sleep(20)")
        let entered = expectation(description: "Owned bridge entered"), stopped = expectation(description: "Owned bridge drained")
        let runtime = BackendTelemetry.$current.withValue(telemetry) {
            AgentRuntimeProcess(bridge: bridge()) { request in
                entered.fulfill()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return ["kind": "bridge_response", "task_generation_id": request["task_generation_id"]!,
                        "request_id": request["request_id"]!, "ok": true]
            }
        }
        runtime.onEvent = { if case .stopped = $0 { stopped.fulfill() } }
        try runtime.start(task: "fixture", display: display, runtimeURL: url, openClawURL: url, geminiAPIKey: "")
        await fulfillment(of: [entered], timeout: 5)
        runtime.stop()
        await fulfillment(of: [stopped], timeout: 5)
        let rows = telemetry.samples().filter { $0.phase == .ipcBridge }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.outcome, .cancelled)
        XCTAssertEqual(telemetry.samples().filter { $0.phase == .ipcSend }.count, 1) // Startup only.
    }
    @MainActor func testOfflinePhaseBenchmark() async throws {
        guard let destination = ProcessInfo.processInfo.environment["TASKPILOT_PHASE_REPORT"] else {
            throw XCTSkip("Developer benchmark requires an explicit private report path")
        }
        let root = try fixture()
        struct Report: Codable {
            let workload: String
            let summaries: [BackendTelemetry.Summary]
            let maxInputBytes: Int
            let maxOutputBytes: Int
        }
        var reports = [Report]()
        func record(_ workload: String, _ telemetry: BackendTelemetry) {
            XCTAssertTrue(telemetry.samples().allSatisfy { $0.outcome == .succeeded })
            reports.append(Report(workload: workload, summaries: telemetry.summaries(),
                maxInputBytes: telemetry.samples().compactMap(\.inputBytes).max() ?? 0,
                maxOutputBytes: telemetry.samples().compactMap(\.outputBytes).max() ?? 0))
        }
        for count in [80, 1280] {
            let telemetry = BackendTelemetry()
            let payload = ["controls": (0..<count).map { ["id": "fixture:\($0)", "role": "AXButton", "label": "synthetic control", "enabled": true] as [String: Any] }]
            try BackendTelemetry.$current.withValue(telemetry) {
                for _ in 0..<30 {
                    _ = try telemetry.encodeJSON(payload)
                    let collection = ObservationCollection<Int>(budget: 5)
                    try collection.collect(roots: [.init(node: 0, scope: .init(pid: 42))], revision: "fixture", check: {},
                        equal: ==, identityHash: { UInt($0) }, inspect: { _, _ in .init() }, children: { entry, offset, limit in
                            .init(nodes: entry.node == 0 ? Array((1..<count).dropFirst(offset).prefix(limit)) : [], total: entry.node == 0 ? count - 1 : 0)
                        })
                }
            }
            record("controls_\(count)_in_process", telemetry)
        }
        for dimensions in [(640, 360), (2560, 1440)] {
            let telemetry = BackendTelemetry(), (width, height) = dimensions
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try XCTUnwrap(context.makeImage())
            try BackendTelemetry.$current.withValue(telemetry) {
                for _ in 0..<30 { try ScreenCaptureService.writePNG(image, to: root.appendingPathComponent("synthetic.png")) }
            }
            record("png_\(width)x\(height)_solid_fixture", telemetry)
        }
        for count in [10, 1000] {
            let telemetry = BackendTelemetry(), store = AgentTaskLedgerStore(fileURL: root.appendingPathComponent("ledger.json"))
            let queue = (0..<count).map { QueuedAgentTask(request: "synthetic request \($0)", queuedAt: Date(timeIntervalSince1970: 1_700_000_000)) }
            try BackendTelemetry.$current.withValue(telemetry) {
                for _ in 0..<30 { try store.save(queue: queue, history: []); XCTAssertEqual(try store.load().queue, queue) }
            }
            record("ledger_\(count)_synthetic_entries", telemetry)
        }
        let commands = BackendTelemetry()
        try await BackendTelemetry.$current.withValue(commands) {
            let executor = TaskToolExecutor()
            for _ in 0..<30 {
                let result = try await executor.perform(action: ["type": "run_command", "argv": ["/usr/bin/true"]])
                XCTAssertEqual(result["exit_code"] as? Int, 0)
            }
        }
        record("command_short_disposable", commands)
        let runtime = BackendTelemetry()
        let url = try helper(root, body: """
        emit('runtime_ready', memory_pressure_version=1)
        emit('bridge_request', request_id='fixture', method='fixture', params={})
        reply=json.loads(sys.stdin.readline())
        assert reply['ok']
        emit('complete', message='fixture complete')
        """)
        for _ in 0..<30 { try await runHelper(url, telemetry: runtime) }
        record("runtime_python_echo_fixture", runtime)
        let output = URL(fileURLWithPath: destination)
        try JSONEncoder().encode(reports).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
}
