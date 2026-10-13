import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class ProcessExitNotificationTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func helper(_ root: URL, _ body: String) throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString)
        try ("#!/bin/zsh -f\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private func waitForFile(_ file: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testExitNotificationRetainsExitBeforeTheWorkerWaits() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let exit = ProcessExitNotification(process)
        defer { process.terminationHandler = nil }
        try process.run()
        XCTAssertEqual(exit.waitForExit(until: .now() + 2), 0)
        guard case .exited(0) = exit.wait(until: .now()) else { return XCTFail("Lost an already delivered exit") }
        exit.interrupt()
        XCTAssertEqual(exit.waitForExit(until: .now()), 0)
    }

    func testImmediateCommandsPreserveLastStdoutStderrAndExitStatus() async throws {
        let executor = TaskToolExecutor()
        for index in 0..<24 {
            let status = index % 2 == 0 ? 0 : 7
            let result = try await executor.perform(action: ["type": "run_command", "argv": ["/bin/zsh", "-f", "-c",
                "printf 'out-\(index)'; printf 'err-\(index)' >&2; exit \(status)"]])
            XCTAssertEqual(result["exit_code"] as? Int, status)
            XCTAssertEqual(result["stdout"] as? String, "out-\(index)")
            XCTAssertEqual(result["stderr"] as? String, "err-\(index)")
            XCTAssertEqual(result["timed_out"] as? Bool, false)
        }
    }

    func testTimeoutDrainsWritesFromTerminationTrapWithoutClaimingSuccess() async throws {
        let executable = try helper(fixture(), "trap 'printf terminal; printf final-error >&2; exit 0' TERM\nprintf ready\nwhile :; do /bin/sleep 0.03; done")
        let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": [executable.path],
            "timeout_seconds": 0.2, "checks": [["type": "stdout_equals", "text": "readyterminal"]]])
        XCTAssertEqual(result["stdout"] as? String, "readyterminal")
        XCTAssertEqual(result["stderr"] as? String, "final-error")
        XCTAssertEqual(result["timed_out"] as? Bool, true)
        XCTAssertEqual(result["verified"] as? Bool, false)
    }

    func testIgnoredTerminationEscalatesWithinTheGracePeriod() async throws {
        let executable = try helper(fixture(), "trap '' TERM\nprintf ready\nexec /bin/sleep 20")
        let start = ContinuousClock.now
        let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": [executable.path], "timeout_seconds": 0.2])
        XCTAssertLessThan(start.duration(to: .now), .seconds(2.5))
        XCTAssertEqual(result["exit_code"] as? Int, Int(SIGKILL))
        XCTAssertEqual(result["stdout"] as? String, "ready")
        XCTAssertEqual(result["timed_out"] as? Bool, true)
        XCTAssertEqual(result["verified"] as? Bool, false)
    }

    func testTaskCancellationAloneStopsTheCommandAndDoesNotPoisonNextInvocation() async throws {
        let root = try fixture(), marker = root.appendingPathComponent("started"), executor = TaskToolExecutor()
        let executable = try helper(root, "/usr/bin/touch \"$1\"\nexec /bin/sleep 20")
        let pending = Task.detached { try await executor.perform(action: ["type": "run_command", "argv": [executable.path, marker.path]]) }
        try await waitForFile(marker)
        let start = ContinuousClock.now
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled command published a result") }
        catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2.5))
        let next = try await executor.perform(action: ["type": "run_command", "argv": ["/usr/bin/printf", "next"],
            "checks": [["type": "stdout_equals", "text": "next"]]])
        XCTAssertEqual(next["verified"] as? Bool, true)
    }

    func testRevocationAloneWakesAndDrainsAPausedOwnedCommand() async throws {
        let root = try fixture(), marker = root.appendingPathComponent("started"), executor = TaskToolExecutor(), lease = TaskLease()
        let executable = try helper(root, "/usr/bin/touch \"$1\"\nexec /bin/sleep 20")
        let pending = Task.detached {
            try await TaskOwnership.$current.withValue(lease) {
                try await executor.perform(action: ["type": "run_command", "argv": [executable.path, marker.path]])
            }
        }
        try await waitForFile(marker)
        lease.pause(); executor.pauseActiveCommand()
        let start = ContinuousClock.now
        lease.revoke()
        do { _ = try await pending.value; XCTFail("Revoked command published a result") }
        catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2.5))
    }

    func testRevocationObserversFireOnceAndCanBeRemoved() {
        let lease = TaskLease(), signal = DispatchSemaphore(value: 0)
        _ = lease.observeRevocation { signal.signal() }
        lease.revoke()
        XCTAssertEqual(signal.wait(timeout: .now()), .success)
        lease.revoke(); lease.retire()
        XCTAssertEqual(signal.wait(timeout: .now()), .timedOut)
        _ = lease.observeRevocation { signal.signal() }
        XCTAssertEqual(signal.wait(timeout: .now()), .success)
        let other = TaskLease()
        let token = other.observeRevocation { signal.signal() }
        other.removeRevocationObserver(token)
        other.retire()
        XCTAssertEqual(signal.wait(timeout: .now()), .timedOut)
    }

    func testStatusHelperDrainsOutputLargerThanAPipeAndItsTerminalWrites() throws {
        let executable = try helper(fixture(), "printf '%131073s' '' | /usr/bin/tr ' ' x\nprintf terminal\nprintf error >&2\nexit 7")
        let result = OpenClawService.run(executable: executable, arguments: [], timeout: 2)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, String(repeating: "x", count: 131073) + "terminalerror")
    }

    func testStatusHelpersTerminateAndReapCommandsIgnoringTERM() throws {
        let executable = try helper(fixture(), "trap '' TERM\nprintf fixture-output\nexec /bin/sleep 20")
        var start = ContinuousClock.now
        let result = OpenClawService.run(executable: executable, arguments: [], timeout: 0.2)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2.5))
        XCTAssertEqual(result.status, -2)
        XCTAssertEqual(result.output, "OpenClaw status check timed out")
        start = .now
        XCTAssertEqual(OpenClawService.runDiscardingOutput(executable: executable, arguments: [], timeout: 0.2), -2)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2.5))
    }

    func testStatusHelpersRecoverAfterLaunchFailureAndDiscardOutput() throws {
        let missing = try fixture().appendingPathComponent("missing")
        XCTAssertEqual(OpenClawService.run(executable: missing, arguments: [], timeout: 1).status, -1)
        XCTAssertEqual(OpenClawService.runDiscardingOutput(executable: missing, arguments: [], timeout: 1), -1)
        let executable = try helper(fixture(), "printf fixture-output; printf fixture-error >&2; exit 3")
        XCTAssertEqual(OpenClawService.runDiscardingOutput(executable: executable, arguments: [], timeout: 1), 3)
        XCTAssertEqual(OpenClawService.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["healthy"], timeout: 1).output, "healthy")
    }

    func testTimeoutKillsDescendantsThatIgnoreTERMAndOutliveTheirShell() async throws {
        for statusHelper in [false, true] {
            let root = try fixture(), marker = root.appendingPathComponent("late-effect")
            let executable = try helper(root, "(trap '' TERM; /usr/bin/touch \"$1.started\"; /bin/sleep 0.8; /usr/bin/touch \"$1\") &\nwait")
            if statusHelper {
                XCTAssertEqual(OpenClawService.run(executable: executable, arguments: [marker.path], timeout: 0.35).status, -2)
            } else {
                let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "argv": [executable.path, marker.path], "timeout_seconds": 0.35])
                XCTAssertEqual(result["timed_out"] as? Bool, true)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path + ".started"))
            try await Task.sleep(for: .seconds(1))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Descendant delivered a late effect after \(statusHelper ? "status" : "task") timeout")
        }
    }
}
