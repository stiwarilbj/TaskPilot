import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class SubprocessSupervisorTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-supervisor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func process(_ body: String) -> SubprocessSupervisor {
        let process = SubprocessSupervisor()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", body]
        addTeardownBlock { process.beginTeardown(); _ = process.waitForTree(until: .now() + 2, ignoreInterrupt: true) }
        return process
    }
    private func waitFor(_ file: URL) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: file.path), .now < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testSpawnAcknowledgesDedicatedGroupAndSeparatesParentTreeAndOutput() throws {
        let process = process("/bin/sleep 0.3 & exit 0"), exit = ProcessExitNotification(process)
        try process.run()
        XCTAssertTrue(process.snapshot.groupAcknowledged)
        XCTAssertEqual(exit.waitForExit(until: .now() + 2), 0)
        XCTAssertTrue(process.snapshot.parentExited)
        XCTAssertFalse(process.snapshot.treeFinished)
        XCTAssertFalse(process.snapshot.outputDrained)
        XCTAssertGreaterThan(process.snapshot.descendants, 0)
        guard case .finished = process.waitForTree(until: .now() + 2) else { return XCTFail("Lost descendants") }
        XCTAssertTrue(process.snapshot.treeFinished)
        process.markOutputDrained()
        XCTAssertTrue(process.snapshot.outputDrained)
    }

    func testFailedGroupSetupCannotRunRequestedProgram() throws {
        let marker = try fixture().appendingPathComponent("must-not-exist")
        let process = SubprocessSupervisor(launchCheck: { throw SubprocessSupervisor.Failure.launch(EPERM) })
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch"); process.arguments = [marker.path]
        XCTAssertThrowsError(try process.run()) { XCTAssertTrue($0.localizedDescription.contains("owned process group")) }
        XCTAssertFalse(process.snapshot.launched)
        XCTAssertFalse(process.snapshot.groupAcknowledged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testOrdinaryCommandsWaitForChildrenAndTheirLastOutput() async throws {
        let start = ContinuousClock.now
        let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": ["/bin/zsh", "-f", "-c", "(/bin/sleep 0.3; printf child; printf error >&2) & exit 0"],
            "checks": [["type": "stdout_equals", "text": "child"]]])
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(280))
        XCTAssertEqual(result["stdout"] as? String, "child")
        XCTAssertEqual(result["stderr"] as? String, "error")
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual(result["stdout_truncated"] as? Bool, false)
    }

    func testClosedPipesDoNotProveDetachedChildrenFinished() async throws {
        let marker = try fixture().appendingPathComponent("finished")
        let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": ["/bin/zsh", "-f", "-c",
            "(/bin/sleep 0.25; /usr/bin/touch \"$1\") >/dev/null 2>&1 & exit 0", "fixture", marker.path]])
        XCTAssertEqual(result["timed_out"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testTimeoutAfterSuccessfulParentExitKillsUnfinishedChildren() async throws {
        let marker = try fixture().appendingPathComponent("late")
        let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": ["/bin/zsh", "-f", "-c",
            "(trap '' TERM; /bin/sleep 0.6; /usr/bin/touch \"$1\") >/dev/null 2>&1 & exit 0", "fixture", marker.path], "timeout_seconds": 0.2])
        XCTAssertEqual(result["exit_code"] as? Int, 0)
        XCTAssertEqual(result["timed_out"] as? Bool, true)
        XCTAssertEqual(result["verified"] as? Bool, false)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationStillWorksAfterParentExit() async throws {
        let root = try fixture(), marker = root.appendingPathComponent("started"), late = root.appendingPathComponent("late")
        let executor = TaskToolExecutor()
        let task = Task.detached {
            try await executor.perform(action: ["type": "run_command", "argv": ["/bin/zsh", "-f", "-c",
                "(trap '' TERM; touch \"$1\"; /bin/sleep 0.6; touch \"$2\") & exit 0", "fixture", marker.path, late.path]])
        }
        try await waitFor(marker)
        try await Task.sleep(for: .milliseconds(60))
        executor.cancelActiveCommand() // Direct native cancellation, without Task.cancel().
        do { _ = try await task.value; XCTFail("Cancelled command returned success") } catch is CancellationError { }
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }

    func testTrackedChildRemainsOwnedAfterLeavingGroupAndReparenting() async throws {
        let root = try fixture(), marker = root.appendingPathComponent("late")
        let file = root.appendingPathComponent("fork.py")
        try """
        import os, sys, time
        if os.fork() == 0:
            os.setsid()
            time.sleep(0.8)
            open(sys.argv[1], 'w').close()
            os._exit(0)
        time.sleep(0.25)
        """.write(to: file, atomically: true, encoding: .utf8)
        let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": ["/usr/bin/python3", file.path, marker.path], "timeout_seconds": 0.4])
        XCTAssertEqual(result["timed_out"] as? Bool, true)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testPersistentAuthorizationComesFromOriginalTask() {
        XCTAssertFalse(TaskLease().permitsPersistentProcesses)
        XCTAssertFalse(TaskLease(taskRequest: "Run my command").permitsPersistentProcesses)
        XCTAssertFalse(TaskLease(taskRequest: "Explain how to run a service in the background").permitsPersistentProcesses)
        XCTAssertFalse(TaskLease(taskRequest: "Do not run this in the background").permitsPersistentProcesses)
        XCTAssertTrue(TaskLease(taskRequest: "Run the local server in the background").permitsPersistentProcesses)
        XCTAssertTrue(TaskLease(taskRequest: "Keep the server running").permitsPersistentProcesses)
    }

    func testPersistentServicesFollowCleanupAndKeepDrainingInheritedOutput() async throws {
        for cleanup in [true, false] {
            let root = try fixture(), late = root.appendingPathComponent("late")
            let lease = TaskLease(taskRequest: "Run this service in the background", closePersistentProcesses: cleanup)
            let executor = TaskToolExecutor()
            let result = try await TaskOwnership.$current.withValue(lease) {
                try await executor.perform(action: ["type": "run_command", "argv": ["/bin/zsh", "-f", "-c",
                    "(/bin/sleep 0.25; printf inherited-output; touch \"$1\") & exit 0", "fixture", late.path]])
            }
            XCTAssertEqual(result["timed_out"] as? Bool, false)
            XCTAssertTrue((result["message"] as? String ?? "").contains("supervised"))
            lease.revoke()
            let until = ContinuousClock.now.advanced(by: .seconds(2))
            while !lease.drainPersistentProcesses(), .now < until { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(lease.drainPersistentProcesses())
            lease.retire()
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(FileManager.default.fileExists(atPath: late.path), !cleanup)
        }
    }

    func testInspectionFailureCannotReleaseOwnership() throws {
        final class Gate {
            private let lock = NSLock()
            private var open = false
            func allow() -> Bool { lock.withLock { open } }
            func resume() { lock.withLock { open = true } }
        }
        let gate = Gate(), process = SubprocessSupervisor(inspectionCheck: { gate.allow() })
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let exit = ProcessExitNotification(process)
        try process.run()
        XCTAssertEqual(exit.waitForExit(until: .now() + 2), 0)
        guard case .timedOut = process.waitForTree(until: .now() + 0.1) else { return XCTFail("Inspection failure released work") }
        XCTAssertTrue(process.snapshot.inspectionFailed)
        XCTAssertFalse(process.snapshot.treeFinished)
        gate.resume()
        guard case .finished = process.waitForTree(until: .now() + 2) else { return XCTFail("Recovered inspection stayed blocked") }
    }

    func testMonitorOutlivesCallerAndImmediateParentThenReleasesItself() async throws {
        var owned: SubprocessSupervisor? = SubprocessSupervisor()
        weak var observed = owned
        owned?.executableURL = URL(fileURLWithPath: "/bin/zsh")
        owned?.arguments = ["-f", "-c", "/bin/sleep 0.3 & exit 0"]
        let exit = ProcessExitNotification(owned!)
        try owned!.run()
        XCTAssertEqual(exit.waitForExit(until: .now() + 2), 0)
        owned = nil
        XCTAssertNotNil(observed)
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while observed != nil, .now < until { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(observed, "Supervisor retained itself after tree exit")
    }

    func testStatusHelpersAlsoWaitForTheWholeTree() throws {
        let result = OpenClawService.run(executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", "(/bin/sleep 0.2; printf child) & exit 0"], timeout: 2)
        XCTAssertEqual(result.status, 0); XCTAssertEqual(result.output, "child")
    }
}
