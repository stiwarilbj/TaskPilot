import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class BufferedProcessOutputTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-buffer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func children(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    private func helper(_ root: URL, _ body: String) throws -> URL {
        let path = root.appendingPathComponent("helper")
        try ("#!/bin/zsh -f\n" + body + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }

    private func run(_ capture: BufferedProcessOutput, _ body: String, arguments: [String] = []) throws -> BufferedProcessOutput.Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", body, "taskpilot-output-fixture"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = capture.stdout
        process.standardError = capture.stderr
        let exit = ProcessExitNotification(process)
        defer { process.terminationHandler = nil }
        try process.run()
        _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
        capture.closeWriters()
        guard exit.waitForExit(until: .now() + 5) != nil else {
            _ = Darwin.kill(-process.processIdentifier, SIGKILL)
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = exit.waitForExit()
            throw NSError(domain: "BufferedOutputFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Fixture stopped draining"])
        }
        defer { _ = Darwin.kill(-process.processIdentifier, SIGKILL) }
        return try capture.finish()
    }

    func testDrainBudgetBoundsBytesAndInterruptedOrShortReads() {
        var full = BufferedProcessOutput.DrainBudget()
        while full.nextReadSize > 0 {
            let requested = full.nextReadSize
            XCTAssertLessThanOrEqual(requested, 16_384)
            full.record(requested)
        }
        XCTAssertEqual(full.bytes, 65_536)
        XCTAssertEqual(full.reads, 4)
        for result in [-1, 1] { // EINTR and one-byte successful reads.
            var short = BufferedProcessOutput.DrainBudget()
            while short.nextReadSize > 0 { short.record(result) }
            XCTAssertEqual(short.reads, 16)
            XCTAssertEqual(short.bytes, result > 0 ? 16 : 0)
        }
    }

    func testLargeStreamsPreserveTheirFinalBytesAcrossDrainTurns() throws {
        let capture = try BufferedProcessOutput(spillRoot: fixture())
        defer { capture.close() }
        let output = try run(capture,
            "(printf '%524288s' ''; printf stdout-tail) & (printf '%524288s' '' >&2; printf stderr-tail >&2) & wait")
        XCTAssertEqual(output.stdout.text, String(repeating: " ", count: 524_288) + "stdout-tail")
        XCTAssertEqual(output.stderr.text, String(repeating: " ", count: 524_288) + "stderr-tail")
        XCTAssertFalse(output.stdout.truncated); XCTAssertFalse(output.stderr.truncated)
    }

    func testEmptyAndShortStreamsCreateNoTemporaryOutputFiles() throws {
        let root = try fixture()
        for body in ["exit 0", "printf short; printf error >&2"] {
            let capture = try BufferedProcessOutput(maximumBytes: 65_536, spillRoot: root)
            defer { capture.close() }
            let output = try run(capture, body)
            XCTAssertEqual(output.stdout.text, body == "exit 0" ? "" : "short")
            XCTAssertEqual(output.stderr.text, body == "exit 0" ? "" : "error")
            XCTAssertFalse(output.stdout.truncated); XCTAssertFalse(output.stderr.truncated)
            XCTAssertEqual(capture.statistics.spillFiles, 0)
            XCTAssertTrue(try children(root).isEmpty)
        }
    }

    func testMemoryAndOutputLimitBoundariesPreserveExactBytes() throws {
        let root = try fixture()
        for count in [32_768, 32_769, 65_536, 65_537] {
            let capture = try BufferedProcessOutput(maximumBytes: 65_536, spillRoot: root)
            defer { capture.close() }
            let output = try run(capture, "printf '%\(count)s' ''")
            XCTAssertEqual(output.stdout.data, Data(repeating: 0x20, count: min(count, 65_536)))
            XCTAssertEqual(output.stdout.truncated, count > 65_536)
            XCTAssertEqual(capture.statistics.drainedBytes, UInt64(count))
            XCTAssertEqual(capture.statistics.spillFiles, count > 32_768 ? 1 : 0)
            XCTAssertLessThanOrEqual(capture.statistics.memoryBytes, 32_768)
            capture.close()
            XCTAssertTrue(try children(root).isEmpty)
        }
    }

    func testSpillReadbackSkipsSlowSyncAndPreservesBytesAndTruncation() throws {
        let root = try fixture()
        let command = "printf '%257s' ''; printf '%193s' '' >&2"
        let expectedStdout = Data(repeating: 0x20, count: 200)
        let expectedStderr = Data(repeating: 0x20, count: 193)
        let fastCapture = try BufferedProcessOutput(maximumBytes: 200, memoryThreshold: 128, spillRoot: root)
        defer { fastCapture.close() }
        let fastStarted = ProcessInfo.processInfo.systemUptime
        let fast = try run(fastCapture, command)
        let fastDuration = ProcessInfo.processInfo.systemUptime - fastStarted
        XCTAssertEqual(fast.stdout.data, expectedStdout)
        XCTAssertEqual(fast.stderr.data, expectedStderr)
        XCTAssertTrue(fast.stdout.truncated)
        XCTAssertFalse(fast.stderr.truncated)
        XCTAssertEqual(fastCapture.statistics.spillFiles, 2)
        fastCapture.close()

        // Recreate the former readback cost as a test-only injected baseline.
        var slowSynchronizationCalls = 0
        let slowCapture = try BufferedProcessOutput(maximumBytes: 200, memoryThreshold: 128, spillRoot: root,
            spillReadback: { handle in
                slowSynchronizationCalls += 1
                Thread.sleep(forTimeInterval: 0.15)
                try handle.synchronize()
                try handle.seek(toOffset: 0)
                return try handle.readToEnd() ?? Data()
            })
        defer { slowCapture.close() }
        let slowStarted = ProcessInfo.processInfo.systemUptime
        let slow = try run(slowCapture, command)
        let slowDuration = ProcessInfo.processInfo.systemUptime - slowStarted
        XCTAssertEqual(slow.stdout.data, fast.stdout.data)
        XCTAssertEqual(slow.stderr.data, fast.stderr.data)
        XCTAssertEqual(slow.stdout.truncated, fast.stdout.truncated)
        XCTAssertEqual(slow.stderr.truncated, fast.stderr.truncated)
        XCTAssertEqual(slowSynchronizationCalls, 2)
        XCTAssertGreaterThan(slowDuration - fastDuration, 0.1,
                             "Default disposable-spill readback should not wait for the injected sync operation")
        slowCapture.close()
        XCTAssertTrue(try children(root).isEmpty)
    }

    func testCancellationAfterSpillRemovesDisposableOutputFiles() throws {
        let root = try fixture()
        let capture = try BufferedProcessOutput(maximumBytes: 128, memoryThreshold: 16, spillRoot: root)
        capture.stdout.write(Data(repeating: 0x78, count: 256))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while capture.statistics.spillFiles == 0 && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertEqual(capture.statistics.spillFiles, 1)
        XCTAssertFalse(try children(root).isEmpty)

        capture.close()
        capture.close()
        XCTAssertTrue(try children(root).isEmpty)
    }

    func testBothNoisyStreamsDrainBeyondRetentionCapsWithoutBlocking() throws {
        let root = try fixture(), capture = try BufferedProcessOutput(maximumBytes: 65_536, spillRoot: root)
        defer { capture.close() }
        let output = try run(capture, "(printf '%1048576s' '' | /usr/bin/tr ' ' x) & (printf '%1048576s' '' | /usr/bin/tr ' ' y >&2) & wait")
        XCTAssertEqual(output.stdout.text, String(repeating: "x", count: 65_536))
        XCTAssertEqual(output.stderr.text, String(repeating: "y", count: 65_536))
        XCTAssertTrue(output.stdout.truncated); XCTAssertTrue(output.stderr.truncated)
        XCTAssertEqual(capture.statistics.drainedBytes, 2_097_152)
        XCTAssertEqual(capture.statistics.retainedBytes, 131_072)
        XCTAssertEqual(capture.statistics.spillFiles, 2)
        let directory = try XCTUnwrap(children(root).first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        let files = try children(directory)
        XCTAssertEqual(files.count, 2)
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
            XCTAssertEqual(attributes[.size] as? Int, 65_536)
        }
        capture.close()
        XCTAssertTrue(try children(root).isEmpty)
    }

    func testOneLargeStreamDoesNotForceTheOtherToSpill() throws {
        let capture = try BufferedProcessOutput(maximumBytes: 65_536, spillRoot: fixture())
        defer { capture.close() }
        let output = try run(capture, "printf '%40000s' ''; printf short-error >&2")
        XCTAssertEqual(output.stdout.data.count, 40_000)
        XCTAssertEqual(output.stderr.text, "short-error")
        XCTAssertEqual(capture.statistics.spillFiles, 1)
        XCTAssertEqual(capture.statistics.memoryBytes, "short-error".utf8.count)
        XCTAssertFalse(output.stdout.truncated); XCTAssertFalse(output.stderr.truncated)
    }

    func testCombinedProbeLimitCountsBothStreamsAndNotifiesOnce() throws {
        let signal = DispatchSemaphore(value: 0)
        for extra in [0, 1] {
            let capture = try BufferedProcessOutput(maximumBytes: 65_536, combinedLimit: 65_536,
                spillRoot: fixture(), onInterruption: { signal.signal() })
            defer { capture.close() }
            let output = try run(capture, "printf '%32768s' ''; printf '%\(32768 + extra)s' '' >&2")
            XCTAssertEqual(output.stdout.data.count, 32_768)
            XCTAssertEqual(output.stderr.data.count, 32_768 + extra)
            XCTAssertEqual(capture.statistics.limitExceeded, extra > 0)
            XCTAssertEqual(signal.wait(timeout: .now()), extra > 0 ? .success : .timedOut)
            XCTAssertEqual(signal.wait(timeout: .now()), .timedOut)
        }
    }

    func testUTF8BytesSurviveChunkingAndSpillWithoutReencoding() throws {
        let root = try fixture(), input = root.appendingPathComponent("input")
        let text = String(repeating: "é🙂", count: 8_000)
        try Data(text.utf8).write(to: input)
        for cap in [65_536, 32_769] {
            let capture = try BufferedProcessOutput(maximumBytes: cap, spillRoot: root)
            defer { capture.close() }
            // Pass the literal path as a positional argument to the shell.
            let output = try run(capture, "/bin/cat \"$1\"", arguments: [input.path])
            XCTAssertEqual(output.stdout.data, Data(text.utf8.prefix(cap)))
            XCTAssertEqual(output.stdout.text, String(decoding: text.utf8.prefix(cap), as: UTF8.self))
            XCTAssertEqual(output.stdout.truncated, text.utf8.count > cap)
        }
    }

    func testZeroRetentionStillDrainsBothStreamsWithoutFiles() throws {
        let root = try fixture(), capture = try BufferedProcessOutput(maximumBytes: 0, spillRoot: root)
        defer { capture.close() }
        let output = try run(capture, "printf '%131073s' ''; printf '%131073s' '' >&2")
        XCTAssertTrue(output.stdout.data.isEmpty); XCTAssertTrue(output.stderr.data.isEmpty)
        XCTAssertTrue(output.stdout.truncated); XCTAssertTrue(output.stderr.truncated)
        XCTAssertEqual(capture.statistics.drainedBytes, 262_146)
        XCTAssertEqual(capture.statistics.memoryBytes, 0)
        XCTAssertTrue(try children(root).isEmpty)
    }

    func testSpillFailureStillDrainsBothStreamsAndNeverReturnsPartialSuccess() throws {
        let root = try fixture(), blocked = root.appendingPathComponent("not-a-directory")
        try Data("sentinel".utf8).write(to: blocked)
        let signal = DispatchSemaphore(value: 0)
        let capture = try BufferedProcessOutput(maximumBytes: 65_536, spillRoot: blocked,
                                               onInterruption: { signal.signal() })
        defer { capture.close() }
        XCTAssertThrowsError(try run(capture, "printf '%524288s' ''; printf '%524288s' '' >&2")) { error in
            XCTAssertEqual(error.localizedDescription, "Command output could not be buffered")
        }
        XCTAssertEqual(capture.statistics.drainedBytes, 1_048_576)
        XCTAssertEqual(signal.wait(timeout: .now()), .success)
        XCTAssertEqual(signal.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("sentinel".utf8))
        XCTAssertEqual(try children(root).count, 1)
    }

    func testUnclosedInheritedWritersCannotHangOrProveExactOutput() throws {
        let capture = try BufferedProcessOutput(maximumBytes: 65_536, spillRoot: fixture())
        defer { capture.close() }
        let start = ContinuousClock.now
        let output = try run(capture, "(/bin/sleep 10) & printf ready; exit 0")
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(output.stdout.text, "ready")
        XCTAssertTrue(output.stdout.truncated); XCTAssertTrue(output.stderr.truncated)
    }

    func testMergedStatusOutputKeepsWriteOrderAndFullOutput() throws {
        let root = try fixture(), capture = try BufferedProcessOutput(merged: true, spillRoot: root)
        defer { capture.close() }
        let output = try run(capture, "printf first; printf '%131073s' '' >&2; printf last")
        XCTAssertEqual(output.stdout.text, "first" + String(repeating: " ", count: 131_073) + "last")
        XCTAssertTrue(output.stderr.data.isEmpty)
        XCTAssertFalse(output.stdout.truncated); XCTAssertFalse(output.stderr.truncated)
        XCTAssertEqual(capture.statistics.spillFiles, 1)
    }

    func testFastExitsAndRepeatedCleanupDoNotLeakStaleOutput() throws {
        let root = try fixture()
        for index in 0..<40 {
            let capture = try BufferedProcessOutput(maximumBytes: 65_536, spillRoot: root)
            defer { capture.close() }
            let output = try run(capture, "printf out-\(index); printf err-\(index) >&2")
            XCTAssertEqual(output.stdout.text, "out-\(index)")
            XCTAssertEqual(output.stderr.text, "err-\(index)")
            XCTAssertFalse(output.stdout.truncated); XCTAssertFalse(output.stderr.truncated)
            capture.close(); capture.close()
            XCTAssertThrowsError(try capture.finish())
        }
        XCTAssertTrue(try children(root).isEmpty)
    }

    func testTaskExecutionAndSyntaxProbesNeedNoWritableSpillLocationForShortOutput() async throws {
        let unavailable = try fixture().appendingPathComponent("missing-directory")
        let executor = TaskToolExecutor(outputSpillRoot: unavailable)
        let result = try await executor.perform(action: ["type": "run_command", "command": "printf healthy; printf error >&2",
            "checks": [["type": "stdout_equals", "text": "healthy"]]])
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual(result["stderr"] as? String, "error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path))
        let status = OpenClawService.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["healthy"],
                                        timeout: 1, outputSpillRoot: unavailable)
        XCTAssertEqual(status.status, 0); XCTAssertEqual(status.output, "healthy")
    }

    func testTaskSpillFailureIsUncertainAndDoesNotReplayMutation() async throws {
        let root = try fixture(), count = root.appendingPathComponent("executions")
        let executable = try helper(root, "printf once >> \"$1\"; printf '%131073s' ''")
        let unavailable = root.appendingPathComponent("missing-directory")
        let executor = TaskToolExecutor(outputSpillRoot: unavailable)
        do {
            _ = try await executor.perform(action: ["type": "run_command", "argv": [executable.path, count.path]])
            XCTFail("Spill failure authorized completion")
        } catch let error as TaskToolError { XCTAssertEqual(error.code, "delivery_uncertain") }
        XCTAssertEqual(try String(contentsOf: count), "once")
        let next = try await executor.perform(action: ["type": "run_command", "argv": ["/usr/bin/printf", "next"],
            "checks": [["type": "stdout_equals", "text": "next"]]])
        XCTAssertEqual(next["verified"] as? Bool, true)
    }

    func testShortHelpProbesNeedNoWritableSpillLocation() async throws {
        let root = try fixture(), unavailable = root.appendingPathComponent("missing-directory")
        let executable = try helper(root, "if [ \"$1\" = --help ]; then printf '%s\\n' 'Options: --help --safe'; exit 0; fi\nprintf delivered")
        let executor = TaskToolExecutor(profileProvider: { _, _ in
            .init(arguments: ["--help"], context: "fixture", exhaustiveLongOptions: true)
        }, outputSpillRoot: unavailable)
        let input: [String: Any] = ["type": "run_command", "argv": [executable.path, "--safe"],
                                   "checks": [["type": "stdout_equals", "text": "delivered"]]]
        let inspected = try await executor.inspectCommand(action: input)
        XCTAssertEqual(inspected["ready"] as? Bool, true)
        XCTAssertEqual(inspected["probes"] as? Int, 1)
        let executed = try await executor.perform(action: input, commandBindingID: inspected["inspection_id"] as? String)
        XCTAssertEqual(executed["verified"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path))
    }

    func testSpillFailureDuringHelpRejectsBeforeTheRequestedCommand() async throws {
        let root = try fixture(), marker = root.appendingPathComponent("delivered")
        let executable = try helper(root, "if [ \"$1\" = --help ]; then printf '%40000s' ''; exit 0; fi\n/usr/bin/touch \"$1\"")
        let executor = TaskToolExecutor(profileProvider: { _, _ in
            .init(arguments: ["--help"], context: "fixture", exhaustiveLongOptions: true)
        }, outputSpillRoot: root.appendingPathComponent("missing-directory"))
        let result = try await executor.inspectCommand(action: ["type": "run_command", "argv": [executable.path, marker.path]])
        XCTAssertEqual(result["ready"] as? Bool, false)
        XCTAssertEqual(result["error_code"] as? String, "delivery_rejected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationAfterSpillingDrainsTheProcessAndRemovesFiles() async throws {
        let root = try fixture(), spills = try fixture(), marker = root.appendingPathComponent("started")
        let executable = try helper(root, "printf '%40000s' ''; /usr/bin/touch \"$1\"; exec /bin/sleep 20")
        let executor = TaskToolExecutor(outputSpillRoot: spills)
        let pending = Task.detached {
            try await executor.perform(action: ["type": "run_command", "argv": [executable.path, marker.path]])
        }
        defer { pending.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: marker.path), !(try children(spills)).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(try children(spills).isEmpty)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled output authorized a result") }
        catch is CancellationError { }
        XCTAssertTrue(try children(spills).isEmpty)
    }

    func testIncompleteStatusAndLaunchFailureDoNotClaimReadinessOrLeaveSpills() throws {
        let root = try fixture(), spills = try fixture()
        let pid = root.appendingPathComponent("child")
        let executable = try helper(root, "(/bin/sleep 20) & printf '%s' $! > \"$1\"; printf ready; exit 0")
        defer { if let contents = try? String(contentsOf: pid), let child = Int32(contents) { _ = Darwin.kill(child, SIGKILL) } }
        let output = OpenClawService.run(executable: executable, arguments: [pid.path], timeout: 1, outputSpillRoot: spills)
        XCTAssertEqual(output.status, -2)
        XCTAssertEqual(output.output, "OpenClaw status check timed out")
        let missing = OpenClawService.run(executable: root.appendingPathComponent("missing"), arguments: [], timeout: 1,
                                          outputSpillRoot: spills)
        XCTAssertEqual(missing.status, -1)
        XCTAssertTrue(try children(spills).isEmpty)
    }
}
