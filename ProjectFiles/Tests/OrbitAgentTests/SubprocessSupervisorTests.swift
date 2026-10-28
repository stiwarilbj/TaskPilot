import Darwin
import Foundation
import XCTest
@testable import OrbitAgent

final class SubprocessSupervisorTests: XCTestCase {
    func testInsufficientHeadroomRejectsBeforeSpawnOrDescriptorChanges() throws {
        let pipe = try SubprocessSupervisor.makePrivatePipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let descriptors = [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor]
        let flags = descriptors.map { fcntl($0, F_GETFD) }
        var before = rlimit(), after = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &before), 0)
        for resources in [SubprocessSupervisor.DescriptorHeadroom(available: 0, softLimit: 256),
                          .init(available: 2, softLimit: 256), .init(available: 10, softLimit: 2)] {
            var checks = 0, acknowledgements = 0
            let process = SubprocessSupervisor(resourceSnapshot: { checks += 1; return resources })
            process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            process.standardInput = pipe
            process.onLaunchAcknowledged = { _ in acknowledgements += 1 }
            XCTAssertThrowsError(try process.run()) { error in
                guard case SubprocessSupervisor.Failure.localResourceExhausted = error else { return XCTFail("Wrong failure classification") }
                XCTAssertTrue(error.localizedDescription.hasPrefix("local_resource_exhausted:"))
            }
            XCTAssertEqual(checks, 1); XCTAssertEqual(acknowledgements, 0)
            XCTAssertEqual(process.processIdentifier, 0); XCTAssertFalse(process.snapshot.launched)
            XCTAssertFalse(process.snapshot.groupAcknowledged); XCTAssertFalse(process.snapshot.teardownStarted)
        }
        XCTAssertEqual(descriptors.map { fcntl($0, F_GETFD) }, flags)
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &after), 0)
        XCTAssertEqual(after.rlim_cur, before.rlim_cur); XCTAssertEqual(after.rlim_max, before.rlim_max)
    }

    func testAdvisoryUnknownAndExactHeadroomPermitNormalSupervision() throws {
        for resources: SubprocessSupervisor.DescriptorHeadroom? in [nil, .init(available: 3, softLimit: 256)] {
            let process = SubprocessSupervisor(resourceSnapshot: { resources })
            process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            let exit = ProcessExitNotification(process)
            try process.run()
            defer { process.beginTeardown(); _ = process.waitForTree(until: .now() + 2, ignoreInterrupt: true) }
            XCTAssertTrue(process.snapshot.groupAcknowledged)
            XCTAssertEqual(exit.waitForExit(until: .now() + 2), 0)
            guard case .finished = process.waitForTree(until: .now() + 2) else { return XCTFail("Tree did not finish") }
            process.markOutputDrained(); XCTAssertTrue(process.snapshot.outputDrained)
        }
    }

    func testAdvisoryApprovalDoesNotReplaceOSLaunchFailure() {
        let process = SubprocessSupervisor(resourceSnapshot: { .init(available: 100, softLimit: 256) })
        process.executableURL = URL(fileURLWithPath: "/nonexistent-taskpilot-fixture")
        XCTAssertThrowsError(try process.run()) { error in
            guard case SubprocessSupervisor.Failure.launch(let code) = error else { return XCTFail("OS failure was hidden") }
            XCTAssertEqual(code, ENOENT)
        }
        XCTAssertFalse(process.snapshot.launched)
    }

    func testBoundedHeadroomReadDoesNotChangeProcessLimits() throws {
        var before = rlimit(), after = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &before), 0)
        let snapshot = try XCTUnwrap(SubprocessSupervisor.DescriptorHeadroom.read())
        XCTAssertLessThanOrEqual(snapshot.available, snapshot.softLimit)
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &after), 0)
        XCTAssertEqual(before.rlim_cur, after.rlim_cur); XCTAssertEqual(before.rlim_max, after.rlim_max)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-supervisor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func process(_ body: String, arguments: [String] = []) -> SubprocessSupervisor {
        let process = SubprocessSupervisor()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", body] + arguments
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

    func testSignalNormalizationWithDirtyEmbeddingHostPreservesGroupAndStreams() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let probe = try fixture().appendingPathComponent("signal-probe")
        let compiler = SubprocessSupervisor(), compilation = try BufferedProcessOutput(merged: true)
        defer { compilation.close(); compiler.beginTeardown(); _ = compiler.waitForTree(until: .now() + 2, ignoreInterrupt: true) }
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", "-Werror", "-Wno-deprecated-declarations", "-I",
                              project.appendingPathComponent("Sources/ProcessSupport/include").path,
                              project.appendingPathComponent("Tests/Fixtures/signal_state_probe.c").path,
                              project.appendingPathComponent("Sources/ProcessSupport/ProcessSupport.c").path,
                              "-o", probe.path]
        compiler.standardOutput = compilation.stdout; compiler.standardError = compilation.stderr
        let compiled = ProcessExitNotification(compiler)
        try compiler.run(); compilation.closeWriters()
        XCTAssertEqual(compiled.waitForExit(until: .now() + 15), 0)
        guard case .finished = compiler.waitForTree(until: .now() + 3) else { return XCTFail("Compiler did not drain") }
        let diagnostics = try compilation.finish(); compiler.markOutputDrained()
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.path), diagnostics.stdout.text)

        let process = SubprocessSupervisor(), output = try BufferedProcessOutput()
        defer { output.close(); process.beginTeardown(); _ = process.waitForTree(until: .now() + 2, ignoreInterrupt: true) }
        process.executableURL = probe; process.arguments = ["--native-host"]
        process.standardOutput = output.stdout; process.standardError = output.stderr
        let exited = ProcessExitNotification(process)
        try process.run(); output.closeWriters()
        XCTAssertTrue(process.snapshot.groupAcknowledged)
        XCTAssertEqual(exited.waitForExit(until: .now() + 5), 0)
        guard case .finished = process.waitForTree(until: .now() + 3) else { return XCTFail("Signal fixture did not drain") }
        let result = try output.finish(); process.markOutputDrained()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.text.utf8)) as? [String: Bool])
        XCTAssertEqual(report, ["mask_empty": true, "defaults": true, "unrelated_ignored": false,
                                "own_group": true, "own_session": false])
        XCTAssertEqual(result.stderr.text, "")
        XCTAssertTrue(process.snapshot.outputDrained)
    }

    func testPrivatePipesProtectBothControllerEnds() throws {
        let pipe = try SubprocessSupervisor.makePrivatePipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            XCTAssertNotEqual(fcntl(handle.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
        }
    }

    func testSpawnClosesUnrelatedAndStandardStreamSourceDescriptors() throws {
        let capture = try BufferedProcessOutput()
        defer { capture.close() }
        let input = try SubprocessSupervisor.makePrivatePipe()
        defer { try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close() }
        let sources = [input.fileHandleForReading, capture.stdout, capture.stderr]
        let handles = try sources.map { source -> FileHandle in
            let fd = fcntl(source.fileDescriptor, F_DUPFD, 128)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        defer { handles.forEach { try? $0.close() } }
        let unrelated = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(unrelated, 0)
        defer { close(unrelated) }
        // Deliberately inheritable descriptors stay open in the controller.
        let descriptors = handles.map(\.fileDescriptor) + [unrelated]
        let process = process("")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import os, sys, errno
        for fd in map(int, sys.argv[1:]):
            try: os.fstat(fd)
            except OSError as error: assert error.errno == errno.EBADF
            else: raise AssertionError('inherited descriptor: %s' % fd)
        assert sys.stdin.readline() == 'input\\n'
        sys.stdout.write('last stdout')
        sys.stderr.write('last stderr')
        """] + descriptors.map(String.init)
        process.standardInput = handles[0]; process.standardOutput = handles[1]; process.standardError = handles[2]
        try input.fileHandleForWriting.write(contentsOf: Data("input\n".utf8))
        let exit = ProcessExitNotification(process)
        try process.run()
        XCTAssertTrue(process.snapshot.groupAcknowledged)
        for fd in descriptors { XCTAssertEqual(fcntl(fd, F_GETFD), 0, "Caller flags must remain unchanged") }
        handles.forEach { try? $0.close() }
        capture.closeWriters()
        XCTAssertEqual(exit.waitForExit(until: .now() + 3), 0)
        guard case .finished = process.waitForTree(until: .now() + 3) else { return XCTFail("Tree did not finish") }
        let output = try capture.finish()
        process.markOutputDrained()
        XCTAssertEqual(output.stdout.text, "last stdout")
        XCTAssertEqual(output.stderr.text, "last stderr")
        XCTAssertTrue(process.snapshot.outputDrained)
    }

    func testMergedOutputAndAlreadyClosedUnusedInputEnd() throws {
        let capture = try BufferedProcessOutput(merged: true)
        defer { capture.close() }
        let input = Pipe()
        try input.fileHandleForWriting.close()
        let process = process("read value; printf out; printf err >&2")
        process.standardInput = input
        process.standardOutput = capture.stdout; process.standardError = capture.stderr
        let exit = ProcessExitNotification(process)
        try process.run()
        capture.closeWriters()
        XCTAssertEqual(exit.waitForExit(until: .now() + 3), 0)
        guard case .finished = process.waitForTree(until: .now() + 3) else { return XCTFail("Tree did not finish") }
        XCTAssertEqual(try capture.finish().stdout.text, "outerr")
        process.markOutputDrained()
    }

    func testContinuousStdoutDoesNotStarveStderrOrSupervisedTeardown() async throws {
        let capture = try BufferedProcessOutput(maximumBytes: 1_024)
        defer { capture.close() }
        let process = process("")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import os, signal, threading, time
        def stop(*args):
            os.write(2, b'final diagnostic')
            os._exit(0)
        signal.signal(signal.SIGTERM, stop)
        def noisy():
            while True: os.write(1, b'x' * 16384)
        threading.Thread(target=noisy, daemon=True).start()
        os.write(2, b'early diagnostic;')
        while True: time.sleep(0.01)
        """]
        process.standardOutput = capture.stdout; process.standardError = capture.stderr
        let exit = ProcessExitNotification(process)
        try process.run()
        capture.closeWriters()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while capture.statistics.stderrDrainedBytes < 17, .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(capture.statistics.stderrDrainedBytes, 17)
        XCTAssertGreaterThan(capture.statistics.stdoutDrainedBytes, 0)
        XCTAssertTrue(process.isRunning, "Diagnostics should drain before stdout stops")
        process.beginTeardown()
        XCTAssertEqual(exit.waitForExit(until: .now() + 3), 0)
        guard case .finished = process.waitForTree(until: .now() + 3) else { return XCTFail("Noisy process did not drain") }
        XCTAssertFalse(process.snapshot.outputDrained)
        let result = try capture.finish()
        process.markOutputDrained()
        XCTAssertEqual(result.stderr.text, "early diagnostic;final diagnostic")
        XCTAssertFalse(result.stderr.truncated)
        XCTAssertEqual(result.stdout.text, String(repeating: "x", count: 1_024))
        XCTAssertTrue(result.stdout.truncated)
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

    func testSeededChildExitCancellationAndDelayedCallbacksAreReproducible() async throws {
        var observedRaceOrders = Set<String>()
        var replayBySeed: [UInt64: (raceOrder: String, callbacks: [String], markerExists: Bool)] = [:]
        for seed: UInt64 in [1, 2, 1, 2] {
            let root = try fixture()
            let release = root.appendingPathComponent("release-child")
            let marker = root.appendingPathComponent("child-finished")
            let scheduler = SeededLifecycleScheduler(seed: seed)
            let callbacks = LockedTestValue<[String]>([])
            let parentCallbackQueued = LockedTestValue(false)
            let treeCallbackQueued = LockedTestValue(false)
            let process = process("(while [[ ! -e \"$1\" ]]; do /bin/sleep 0.01; done; /usr/bin/touch \"$2\") & exit 0",
                                  arguments: ["fixture", release.path, marker.path])
            process.terminationHandler = { _ in
                scheduler.schedule(after: 20, name: "delayed-parent-callback") {
                    callbacks.update { $0.append("parent") }
                }
                parentCallbackQueued.update { $0 = true }
            }
            process.whenTreeExits {
                scheduler.schedule(after: 5, name: "delayed-tree-callback") {
                    callbacks.update { $0.append("tree") }
                }
                treeCallbackQueued.update { $0 = true }
            }
            try process.run()
            let parentCallbackArrived = await waitForSeededLifecycleCondition { parentCallbackQueued.read() }
            XCTAssertTrue(parentCallbackArrived, "parent callback timeout; seed=\(seed)")
            XCTAssertTrue(process.snapshot.parentExited, "seed=\(seed)")

            scheduler.schedule(at: 10, name: "release-child") {
                FileManager.default.createFile(atPath: release.path, contents: Data())
                guard case .finished = process.waitForTree(until: .now() + 2, ignoreInterrupt: true) else {
                    XCTFail("Child did not drain after release; seed=\(seed)")
                    return
                }
                let callbackArrived = await waitForSeededLifecycleCondition { treeCallbackQueued.read() }
                XCTAssertTrue(callbackArrived, "tree callback timeout; seed=\(seed)")
            }
            scheduler.schedule(at: 10, name: "cancel-tree") {
                process.beginTeardown(grace: 0)
                guard case .finished = process.waitForTree(until: .now() + 2, ignoreInterrupt: true) else {
                    XCTFail("Child did not drain after cancellation; seed=\(seed)")
                    return
                }
                let callbackArrived = await waitForSeededLifecycleCondition { treeCallbackQueued.read() }
                XCTAssertTrue(callbackArrived, "tree callback timeout; seed=\(seed)")
            }
            await scheduler.runAll()
            await scheduler.runAll()

            XCTAssertTrue(process.snapshot.parentExited, "seed=\(seed)")
            XCTAssertTrue(process.snapshot.treeFinished, "seed=\(seed)")
            let raceOrder = scheduler.trace.filter { $0 == "release-child" || $0 == "cancel-tree" }
            XCTAssertEqual(raceOrder.count, 2, "seed=\(seed)")
            observedRaceOrders.insert(raceOrder.joined(separator: ","))
            let markerExists = FileManager.default.fileExists(atPath: marker.path)
            XCTAssertEqual(markerExists, raceOrder.first == "release-child",
                           "the first seeded event should decide whether the child finishes naturally; seed=\(seed)")
            XCTAssertEqual(callbacks.read(), ["tree", "parent"], "delayed callbacks must remain exactly once and ordered; seed=\(seed)")
            XCTAssertGreaterThanOrEqual(scheduler.clock.now, 20)
            let current = (raceOrder: raceOrder.joined(separator: ","), callbacks: callbacks.read(), markerExists: markerExists)
            if let previous = replayBySeed[seed] {
                XCTAssertEqual(current.raceOrder, previous.raceOrder, "same seed changed event order; seed=\(seed)")
                XCTAssertEqual(current.callbacks, previous.callbacks, "same seed changed callback trace; seed=\(seed)")
                XCTAssertEqual(current.markerExists, previous.markerExists, "same seed changed child outcome; seed=\(seed)")
            }
            replayBySeed[seed] = current
        }
        XCTAssertEqual(observedRaceOrders, ["release-child,cancel-tree", "cancel-tree,release-child"])
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
