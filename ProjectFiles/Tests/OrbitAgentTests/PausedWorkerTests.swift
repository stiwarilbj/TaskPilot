import Foundation
import XCTest
@testable import OrbitAgent

final class PausedWorkerTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
    private struct ParkingTimeout: Error {}

    // Controlled synchronous fixture, matching a native worker between its
    // async entry point and the synchronous commit being tested.
    private func waitForRelease(_ release: DispatchSemaphore, entered: XCTestExpectation) {
        entered.fulfill(); release.wait()
    }

    private func parked(_ lease: TaskLease, count: Int, registrations: Int = 0) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while lease.pauseWaiterCount != count || lease.pauseWaitRegistrationCount < registrations {
            guard ContinuousClock.now < deadline else {
                XCTFail("Workers did not park at the expected ownership boundary")
                throw ParkingTimeout()
            }
            await Task.yield()
        }
    }

    func testMixedWorkersParkOnceWithoutIdleWakeupsAndResumeTogether() async throws {
        let lease = TaskLease(), effects = Counter(), finished = expectation(description: "All workers resumed")
        finished.expectedFulfillmentCount = 8
        defer { lease.revoke() }
        lease.pause()
        for _ in 0..<4 {
            Task {
                defer { finished.fulfill() }
                do { try await lease.checkpoint(); try lease.commit { effects.increment() } }
                catch { XCTFail("Healthy worker failed: \(error)") }
            }
            DispatchQueue.global().async {
                defer { finished.fulfill() }
                do { try lease.commit { effects.increment() } }
                catch { XCTFail("Healthy native worker failed: \(error)") }
            }
        }
        try await parked(lease, count: 8)
        XCTAssertEqual(lease.pauseWaitRegistrationCount, 8)
        // Longer than six former 25ms intervals: no timer wakes or reparks.
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(lease.pauseWaitRegistrationCount, 8)
        XCTAssertEqual(lease.pauseWaiterCount, 8)
        XCTAssertEqual(effects.value, 0)
        lease.resume(); lease.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(effects.value, 8)
        XCTAssertEqual(lease.pauseWaiterCount, 0)
        XCTAssertEqual(lease.pauseWaitRegistrationCount, 8)
        XCTAssertEqual(lease.suspensionRevision, 1)
    }

    func testRevocationAndRetirementWakeBothKindsWithoutGrantingAuthority() async throws {
        for retire in [false, true] {
            let lease = TaskLease(), effects = Counter(), finished = expectation(description: "Stopped waits drained")
            finished.expectedFulfillmentCount = 2
            defer { lease.revoke() }
            lease.pause()
            Task {
                defer { finished.fulfill() }
                do { try await lease.checkpoint(); try lease.commit { effects.increment() }; XCTFail("Stopped worker ran") }
                catch { XCTAssertTrue(error is CancellationError) }
            }
            DispatchQueue.global().async {
                defer { finished.fulfill() }
                do { try lease.commit { effects.increment() }; XCTFail("Stopped native worker ran") }
                catch { XCTAssertTrue(error is CancellationError) }
            }
            try await parked(lease, count: 2)
            if retire { lease.retire() } else { lease.revoke() }
            lease.resume(); lease.revoke(); lease.retire()
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(effects.value, 0)
            XCTAssertEqual(lease.pauseWaiterCount, 0)
            XCTAssertEqual(lease.state, .retired)
        }
    }

    func testCancellationRemovesOnlyTheCancelledAsyncWaiter() async throws {
        let lease = TaskLease(), cancelled = expectation(description: "Cancelled without Resume")
        let resumed = expectation(description: "Other worker still owned"), effects = Counter()
        defer { lease.revoke() }
        lease.pause()
        let worker = Task {
            defer { cancelled.fulfill() }
            do { try await lease.checkpoint(); XCTFail("Cancelled checkpoint returned") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        Task {
            defer { resumed.fulfill() }
            do { try await lease.checkpoint(); try lease.commit { effects.increment() } }
            catch { XCTFail("Other waiter lost its authority") }
        }
        try await parked(lease, count: 2)
        worker.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(lease.state, .paused)
        XCTAssertEqual(lease.pauseWaiterCount, 1)
        XCTAssertEqual(lease.pauseWaitRegistrationCount, 2)
        XCTAssertEqual(effects.value, 0)
        lease.resume()
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(effects.value, 1)
    }

    func testCancellationWakesSynchronousCommitWithoutResumeOrStop() async throws {
        let lease = TaskLease(), finished = expectation(description: "Cancelled native wait"), effects = Counter()
        defer { lease.revoke() }
        lease.pause()
        let worker = Task.detached {
            defer { finished.fulfill() }
            do {
                try await TaskOwnership.$current.withValue(lease) {
                    try await TaskOwnership.withCancellationWakeup {
                        try TaskOwnership.commit { effects.increment() }
                    }
                }
                XCTFail("Cancelled commit delivered")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        try await parked(lease, count: 1)
        worker.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(lease.state, .paused)
        XCTAssertEqual(effects.value, 0)
        XCTAssertEqual(lease.pauseWaiterCount, 0)
    }

    func testCancellationBeforeRegistrationCannotLoseItsWakeup() async throws {
        for synchronous in [false, true] {
            let lease = TaskLease(), entered = expectation(description: "Cancellation scope installed")
            let finished = expectation(description: "Precancelled wait ended"), release = DispatchSemaphore(value: 0)
            defer { lease.revoke(); release.signal() }
            lease.pause()
            let worker = Task.detached {
                defer { finished.fulfill() }
                do {
                    try await TaskOwnership.$current.withValue(lease) {
                        try await TaskOwnership.withCancellationWakeup {
                            self.waitForRelease(release, entered: entered)
                            if synchronous { try lease.commit { XCTFail("Precancelled mutation") } }
                            else { try await lease.checkpoint() }
                        }
                    }
                    XCTFail("Precancelled worker returned")
                } catch { XCTAssertTrue(error is CancellationError) }
            }
            await fulfillment(of: [entered], timeout: 2)
            worker.cancel(); release.signal()
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(lease.pauseWaiterCount, 0)
            XCTAssertEqual(lease.pauseWaitRegistrationCount, 0)
        }
    }

    func testWakeupWhileStillPausedRechecksOwnershipAndParksAgain() async throws {
        let lease = TaskLease(), effects = Counter(), finished = expectation(description: "Resumed after spurious wake")
        finished.expectedFulfillmentCount = 2
        defer { lease.revoke() }
        lease.pause()
        Task {
            defer { finished.fulfill() }
            do { try await lease.checkpoint(); try lease.commit { effects.increment() } }
            catch { XCTFail("Async wait failed") }
        }
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do { try lease.commit { effects.increment() } }
            catch { XCTFail("Native wait failed") }
        }
        try await parked(lease, count: 2)
        lease.wakePausedWorkers()
        try await parked(lease, count: 2, registrations: 4)
        XCTAssertEqual(lease.state, .paused)
        XCTAssertEqual(effects.value, 0)
        XCTAssertEqual(lease.suspensionRevision, 1)
        lease.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(effects.value, 2)
    }

    func testResumeRacingWithRegistrationDoesNotStrandWorkers() async {
        let leases = (0..<80).map { _ in TaskLease() }
        let finished = expectation(description: "Registration races drained"), effects = Counter()
        finished.expectedFulfillmentCount = leases.count * 2
        defer { for lease in leases { lease.revoke() } }
        for lease in leases {
            lease.pause()
            Task {
                defer { finished.fulfill() }
                do { try await lease.checkpoint(); try lease.commit { effects.increment() } }
                catch { XCTFail("Resume race rejected async work") }
            }
            DispatchQueue.global().async {
                defer { finished.fulfill() }
                do { try lease.commit { effects.increment() } }
                catch { XCTFail("Resume race rejected native work") }
            }
            lease.resume()
        }
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(effects.value, leases.count * 2)
        XCTAssertTrue(leases.allSatisfy { $0.pauseWaiterCount == 0 })
    }

    func testConcurrentResumeCancellationAndStopResumeEachContinuationOnce() async throws {
        for _ in 0..<40 {
            let lease = TaskLease(), finished = expectation(description: "Racing wakeups settled")
            defer { lease.revoke() }
            lease.pause()
            let worker = Task {
                defer { finished.fulfill() }
                do { try await lease.checkpoint(); try lease.commit {} }
                catch { XCTAssertTrue(error is CancellationError) }
            }
            try await parked(lease, count: 1)
            let transitions = DispatchGroup()
            for change in [lease.resume, lease.revoke, lease.retire, worker.cancel] {
                DispatchQueue.global().async(group: transitions) { change() }
            }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(transitions.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(lease.pauseWaiterCount, 0)
            XCTAssertFalse(lease.accepts(lease.id))
        }
    }

    @MainActor func testMainThreadRejectsPauseWithoutBlockingAndNestedCommitsStillWork() throws {
        let lease = TaskLease(), effects = Counter()
        lease.pause()
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertThrowsError(try lease.commit { effects.increment() })
        XCTAssertEqual(lease.pauseWaiterCount, 0)
        lease.resume()
        try lease.commit { try lease.commit { effects.increment() } }
        XCTAssertEqual(effects.value, 1)
    }

    func testOldLeaseWakeupsCannotResumeANewerPausedTask() async throws {
        let old = TaskLease(), current = TaskLease(), finished = expectation(description: "Current generation resumed")
        defer { old.revoke(); current.revoke() }
        current.pause()
        Task {
            defer { finished.fulfill() }
            do { try await current.checkpoint(); try current.commit {} }
            catch { XCTFail("Current generation was cancelled by old work") }
        }
        try await parked(current, count: 1)
        old.pause(); old.resume(); old.revoke(); old.retire(); old.wakePausedWorkers()
        XCTAssertEqual(current.state, .paused)
        XCTAssertEqual(current.pauseWaiterCount, 1)
        XCTAssertEqual(current.pauseWaitRegistrationCount, 1)
        current.resume()
        await fulfillment(of: [finished], timeout: 2)
    }

    func testBridgeCancellationWhilePausedReturnsOnlyItsOwnedError() async throws {
        let lease = TaskLease(), finished = expectation(description: "Owned cancellation response")
        let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: AccessibilityController(), capture: ScreenCaptureService())
        try bridge.bind(lease)
        defer { lease.revoke() }
        lease.pause()
        let worker = Task {
            let response = await bridge.handleOwned(["task_generation_id": lease.id, "request_id": "fixture",
                "method": "action_receipt", "params": ["action_id": UUID().uuidString]], lease: lease)
            XCTAssertEqual(response["error_code"] as? String, "cancelled")
            XCTAssertEqual(response["task_generation_id"] as? String, lease.id)
            XCTAssertEqual(response["request_id"] as? String, "fixture")
            finished.fulfill()
        }
        try await parked(lease, count: 1)
        worker.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(lease.state, .paused)
        XCTAssertEqual(lease.pauseWaiterCount, 0)
    }

    func testToolCancellationBetweenCheckpointAndCommandLaunchDoesNotExecute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("fixture"), marker = root.appendingPathComponent("unexpected-launch")
        try "#!/bin/sh\n/usr/bin/touch \"${0}.launched\"\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        for inspection in [false, true] {
            let lease = TaskLease(), finished = expectation(description: "Paused tool cancellation")
            defer { lease.revoke() }
            let executor = TaskToolExecutor(profileProvider: { _, _ in
                lease.pause()
                return .init(arguments: ["--help"], context: "fixture", exhaustiveLongOptions: true)
            })
            let action: [String: Any] = ["type": "run_command", "argv": [tool.path, marker.path], "working_directory": root.path]
            let worker = Task.detached {
                defer { finished.fulfill() }
                do {
                    _ = try await TaskOwnership.$current.withValue(lease) {
                        if inspection { return try await executor.inspectCommand(action: action) }
                        return try await executor.perform(action: action)
                    }
                    XCTFail("Cancelled tool returned success")
                } catch { XCTAssertTrue(error is CancellationError) }
            }
            try await parked(lease, count: 1)
            worker.cancel()
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(lease.pauseWaiterCount, 0)
            XCTAssertEqual(lease.state, .paused)
            XCTAssertFalse(FileManager.default.fileExists(atPath: tool.path + ".launched"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }
}
