import Foundation
import XCTest
@testable import OrbitAgent

final class LocalChangeNotificationTests: XCTestCase {
    private final class FakeSource: LocalChangeSource {
        var supported = true
        var refreshes = 0
        var closes = 0
        func refresh() async { refreshes += 1 }
        func close() async { closes += 1 }
    }
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testAlreadySatisfiedConditionChecksOnceAndNeverWaits() async throws {
        let source = FakeSource()
        let result = try await LocalChangeWait.run(signal: LocalChangeSignal(lease: nil), source: source, deadline: 2,
            check: { true }, now: { 0 }, wake: { _ in XCTFail("Healthy readback must not wait"); return .poll })
        XCTAssertEqual(result.candidate, true); XCTAssertEqual(result.checks, 1)
        XCTAssertEqual(source.closes, 1); XCTAssertEqual(source.refreshes, 0)
    }

    func testNotificationsRecheckConditionAndSpuriousEventsAreNotProof() async throws {
        let source = FakeSource(); var clock = 0.0; var checks = 0; var wakes = 0
        let result = try await LocalChangeWait.run(signal: LocalChangeSignal(lease: nil), source: source, deadline: 1,
            check: { checks += 1; return checks == 3 }, now: { clock }, sleep: { clock += $0 }, wake: { _ in
                wakes += 1; clock += 0.1; return .notification
            })
        XCTAssertEqual(checks, 3); XCTAssertEqual(wakes, 2); XCTAssertEqual(result.candidate, true)
        XCTAssertEqual(source.refreshes, 2); XCTAssertEqual(source.closes, 1)
    }

    func testUnsupportedOrDroppedNotificationsPollAtBoundAndRemainUnconfirmed() async throws {
        for supported in [true, false] {
            let source = FakeSource(); source.supported = supported; var clock = 0.0; var intervals: [Double] = []
            let result = try await LocalChangeWait.run(signal: LocalChangeSignal(lease: nil), source: source, deadline: 1.2,
                check: { false }, now: { clock }, wake: { interval in intervals.append(interval); clock += interval; return .poll })
            XCTAssertEqual(clock, 1.2); XCTAssertEqual(result.candidate, false)
            XCTAssertEqual(result.checks, 4); XCTAssertEqual(intervals, [0.5, 0.5, 0.19999999999999996])
            XCTAssertEqual(result.pollWakeups, 3)
            XCTAssertEqual(result.supported, supported); XCTAssertEqual(source.closes, 1)
        }
    }

    func testNotificationWithoutRecognizedExpectationOnlyRequestsFreshEvidence() async throws {
        let source = FakeSource(); var checks = 0; var clock = 0.0
        let result = try await LocalChangeWait.run(signal: LocalChangeSignal(lease: nil), source: source, deadline: 1,
            check: { checks += 1; return nil }, now: { clock }, sleep: { clock += $0 }, wake: { _ in .notification })
        XCTAssertNil(result.candidate); XCTAssertEqual(result.reason, "change_notification")
        XCTAssertEqual(checks, 2); XCTAssertEqual(result.dictionary["effect_ready"] as? NSNull, NSNull())
    }

    func testDebounceAndStabilityDelayShareRemainingDeadline() async throws {
        let source = FakeSource(); var clock = 0.9
        let result = try await LocalChangeWait.run(signal: LocalChangeSignal(lease: nil), source: source, deadline: 1,
            minimumDelay: 0.3, check: { false }, now: { clock }, sleep: { clock += $0 }, wake: { _ in
                XCTFail("Delay must not multiply the deadline"); return .notification
            })
        XCTAssertEqual(clock, 1); XCTAssertEqual(result.checks, 1); XCTAssertEqual(result.candidate, false)
    }

    func testReadbackErrorClosesSourceWithoutTryingAnotherAction() async {
        let source = FakeSource()
        do {
            _ = try await LocalChangeWait.run(signal: LocalChangeSignal(lease: nil), source: source, deadline: 2,
                check: { throw CancellationError() }, now: { 0 })
            XCTFail("Cancellation was swallowed")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(source.closes, 1); XCTAssertEqual(source.refreshes, 0)
    }

    func testStopDuringDebounceCannotPublishEvenAnAlreadySatisfiedCondition() async {
        let lease = TaskLease(), source = FakeSource()
        let owned = LocalChangeSignal(lease: lease)
        var reads = 0
        do {
            _ = try await TaskOwnership.$current.withValue(lease) {
                try await LocalChangeWait.run(signal: owned, source: source, deadline: 1, minimumDelay: 0.05,
                    check: { reads += 1; return true }, now: { 0 }, sleep: { _ in lease.revoke() })
            }
            XCTFail("Revoked task published a result")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(reads, 0); XCTAssertEqual(source.closes, 1)
    }

    func testBurstSignalsCoalesceAndClosedSignalCannotResumeAgain() async {
        let signal = LocalChangeSignal(lease: nil)
        for _ in 0..<100 { signal.notify() }
        let first = await signal.wait(seconds: 0.01)
        let second = await signal.wait(seconds: 0.01)
        XCTAssertEqual(first, .notification); XCTAssertEqual(second, .poll)
        XCTAssertEqual(signal.notifications, 100)
        signal.close(); signal.notify()
        let closed = await signal.wait(seconds: 1)
        XCTAssertEqual(closed, .interrupted); XCTAssertEqual(signal.notifications, 100)
    }

    func testCancelledTimerDoesNotInterruptNextWait() async throws {
        let signal = LocalChangeSignal(lease: nil)
        let first = Task { await signal.wait(seconds: 0.04) }
        try await Task.sleep(for: .milliseconds(10)); signal.notify()
        let delivered = await first.value
        XCTAssertEqual(delivered, .notification)
        let started = ProcessInfo.processInfo.systemUptime
        let second = await signal.wait(seconds: 0.09)
        XCTAssertEqual(second, .poll)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.075)
    }

    func testCancellationWakesPendingContinuationAndClosesScopedSource() async throws {
        let source = FakeSource(); let signal = LocalChangeSignal(lease: nil)
        let task = Task {
            try await LocalChangeWait.run(signal: signal, source: source,
                deadline: ProcessInfo.processInfo.systemUptime + 5, check: { false })
        }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled wait returned a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(source.closes, 1)
    }

    func testRevokedTaskCannotPublishReadbackOrWakeAnotherGeneration() async {
        let lease = TaskLease(), newer = TaskLease(), source = FakeSource()
        let signal = LocalChangeSignal(lease: lease), newSignal = LocalChangeSignal(lease: newer)
        var checks = 0
        do {
            _ = try await TaskOwnership.$current.withValue(lease) {
                try await LocalChangeWait.run(signal: signal, source: source, deadline: 1,
                    check: { checks += 1; return false }, now: { 0 }, wake: { _ in
                        lease.revoke(); signal.notify(); return .notification
                    })
            }
            XCTFail("Revoked generation returned evidence")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(checks, 1); XCTAssertEqual(source.closes, 1); XCTAssertEqual(signal.notifications, 0)
        let independent = await newSignal.wait(seconds: 0.001)
        XCTAssertEqual(independent, .poll)
    }

    func testPauseResumeDiscardsOldSubscriptionEpoch() async throws {
        let lease = TaskLease(), source = FakeSource()
        let owned = LocalChangeSignal(lease: lease)
        let result = try await TaskOwnership.$current.withValue(lease) {
            try await LocalChangeWait.run(signal: owned, source: source, deadline: 1,
                check: { false }, now: { 0 }, wake: { _ in
                    lease.pause(); owned.notify(); lease.resume(); return .notification
                })
        }
        XCTAssertEqual(result.reason, "resumed"); XCTAssertNil(result.candidate); XCTAssertEqual(result.checks, 1)
        XCTAssertEqual(owned.notifications, 0); XCTAssertEqual(source.closes, 1)
        let fresh = LocalChangeSignal(lease: lease); fresh.notify()
        let wake = await fresh.wait(seconds: 0.001); XCTAssertEqual(wake, .notification)
    }

    func testPauseDuringNotificationDebounceSkipsStaleReadback() async throws {
        let lease = TaskLease(), source = FakeSource()
        let owned = LocalChangeSignal(lease: lease); var reads = 0
        let result = try await TaskOwnership.$current.withValue(lease) {
            try await LocalChangeWait.run(signal: owned, source: source, deadline: 1,
                check: { reads += 1; return reads > 1 }, now: { 0 },
                sleep: { _ in lease.pause(); lease.resume() }, wake: { _ in .notification })
        }
        XCTAssertEqual(result.reason, "resumed"); XCTAssertNil(result.candidate)
        XCTAssertEqual(reads, 1); XCTAssertEqual(source.closes, 1)
    }

    func testReadbackCrossingPauseResumeCannotBecomeEvidence() async throws {
        let lease = TaskLease(), source = FakeSource()
        let result = try await TaskOwnership.$current.withValue(lease) {
            try await LocalChangeWait.run(signal: LocalChangeSignal(lease: lease), source: source, deadline: 1,
                check: { lease.pause(); lease.resume(); return true }, now: { 0 })
        }
        XCTAssertEqual(result.reason, "resumed"); XCTAssertNil(result.candidate)
        XCTAssertEqual(result.checks, 1); XCTAssertEqual(source.closes, 1)
    }

    func testFilesystemWakeRequiresExactReadbackAfterUnrelatedAndAtomicWrites() async throws {
        let folder = try fixture(), target = folder.appendingPathComponent("note")
        try Data("old".utf8).write(to: target)
        let signal = LocalChangeSignal(lease: nil)
        let source = await NativeChangeSubscription.file(target, signal: signal)
        XCTAssertTrue(source.supported)
        let writer = Task {
            try await Task.sleep(for: .milliseconds(30))
            try Data("unrelated".utf8).write(to: folder.appendingPathComponent("other"))
            try await Task.sleep(for: .milliseconds(70))
            try Data("wanted".utf8).write(to: target, options: .atomic)
        }
        let tools = TaskToolExecutor(); var verified = false
        let result = try await LocalChangeWait.run(signal: signal, source: source,
            deadline: ProcessInfo.processInfo.systemUptime + 1, check: {
                let checked = try await tools.checkOutcome(["type": "file_contents", "path": target.path, "content": "wanted"])
                verified = (checked["checks"] as? [[String: Any]])?.first?["verified"] as? Bool == true
                return verified
            })
        try await writer.value
        XCTAssertEqual(result.candidate, true); XCTAssertTrue(verified)
        XCTAssertGreaterThan(result.notifications, 0); XCTAssertGreaterThanOrEqual(result.checks, 2)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "wanted")
        let closed = await signal.wait(seconds: 0.001); XCTAssertEqual(closed, .interrupted)
    }

    func testWatchMissingParentRearmsAfterCreationAndFileReplacement() async throws {
        let folder = try fixture(), parent = folder.appendingPathComponent("new"), target = parent.appendingPathComponent("note")
        XCTAssertEqual(NativeChangeSubscription.fileWatchPaths(target), [folder.path])
        let signal = LocalChangeSignal(lease: nil)
        let source = await NativeChangeSubscription.file(target, signal: signal)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: target)
        await source.refresh()
        XCTAssertEqual(Set(NativeChangeSubscription.fileWatchPaths(target)), Set([parent.path, target.path]))
        try Data("replacement".utf8).write(to: target, options: .atomic)
        await source.refresh(); XCTAssertTrue(source.supported)
        await source.close(); XCTAssertFalse(source.supported); signal.close()
    }

    func testFileWaitBridgeChecksOnceWhenHealthyAndRejectsForeignGeneration() async throws {
        let folder = try fixture(), target = folder.appendingPathComponent("note")
        try Data("wanted".utf8).write(to: target)
        let lease = TaskLease()
        let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
        try bridge.bind(lease)
        let request: [String: Any] = ["task_generation_id": lease.id, "request_id": "wait", "method": "wait_file_effect",
            "params": ["check": ["type": "file_contents", "path": target.path, "content": "wanted"], "timeout_ms": 100]]
        let response = await bridge.handleOwned(request, lease: lease)
        XCTAssertEqual(response["ok"] as? Bool, true)
        let result = response["result"] as! [String: Any], wait = result["local_wait"] as! [String: Any]
        XCTAssertEqual(wait["targeted_checks"] as? Int, 1); XCTAssertEqual(wait["effect_ready"] as? Bool, true)
        XCTAssertNil(response["action_receipt"])
        var foreign = request; foreign["task_generation_id"] = UUID().uuidString
        let rejected = await bridge.handleOwned(foreign, lease: lease)
        XCTAssertEqual(rejected["ok"] as? Bool, false)
    }

    func testFileWaitRejectsInvalidTypesBoundsAndUnknownChecksBeforeSubscription() async throws {
        let folder = try fixture(), target = folder.appendingPathComponent("missing"), lease = TaskLease()
        let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
        try bridge.bind(lease)
        for timeout: Any in [true, "100", 0, -1, 2.5, 2001, Double.infinity] {
            let response = await bridge.handleOwned(["task_generation_id": lease.id, "method": "wait_file_effect",
                "params": ["check": ["type": "file_exists", "path": target.path], "timeout_ms": timeout]], lease: lease)
            XCTAssertEqual(response["ok"] as? Bool, false)
        }
        let unknown = await bridge.handleOwned(["task_generation_id": lease.id, "method": "wait_file_effect",
            "params": ["check": ["type": "stdout_equals", "text": "not a file"]]], lease: lease)
        XCTAssertEqual(unknown["ok"] as? Bool, false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testReadOnlyScreenWaitRejectsStaleRevisionBeforeObservingApplications() throws {
        let controller = AccessibilityController()
        XCTAssertThrowsError(try controller.localChangeTarget(["observation_revision": "stale", "pid": 42])) { error in
            XCTAssertEqual((error as? AccessibilityActionError)?.code, "stale_target")
        }
    }

    func testPrivateCountersDecodeOlderHistoryWithoutChangingSummary() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let base = "\"planning\":1,\"verification\":0,\"retries\":0,\"model_switches\":0,\"cache_hits\":0,\"reconnects\":0"
        let old = try decoder.decode(AgentRequestMetrics.self, from: Data(("{" + base + "}").utf8))
        let current = try decoder.decode(AgentRequestMetrics.self, from: Data(("{" + base + ",\"local_notifications\":2,\"local_targeted_checks\":3,\"local_poll_wakeups\":1}").utf8))
        XCTAssertNil(old.localNotifications); XCTAssertEqual(current.localNotifications, 2)
        XCTAssertEqual(current.localTargetedChecks, 3); XCTAssertEqual(current.localPollWakeups, 1)
        XCTAssertEqual(old.summary, current.summary)
    }
}
