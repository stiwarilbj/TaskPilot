import Foundation
import XCTest
@testable import OrbitAgent

final class TaskOwnershipTests: XCTestCase {
    private actor Suspension {
        var continuation: CheckedContinuation<Void, Never>?
        func wait(_ started: XCTestExpectation) async {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        func release() { continuation?.resume(); continuation = nil }
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
        try ("""
        #!/usr/bin/python3
        import json, sys, time, uuid
        config = json.loads(sys.stdin.readline())
        def completion_gate(revision):
            request = dict(kind='bridge_request', task_generation_id=config['task_generation_id'],
                instruction_revision=revision, working_document_revision=0,
                request_id=str(uuid.uuid4()), method='completion_gate', params={})
            print(json.dumps(request), flush=True)
            response = json.loads(sys.stdin.readline())
            assert response.get('ok') and response.get('result', {}).get('accepted') is True, response
        def emit(kind, **fields):
            revision = fields.pop('instruction_revision', 0)
            if kind == 'complete': completion_gate(revision)
            print(json.dumps(dict(kind=kind, task_generation_id=config['task_generation_id'],
                instruction_revision=revision, working_document_revision=0, **fields)), flush=True)
        """ + "\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    // A nonisolated native fixture; a closure declared in a @MainActor test
    // would inherit that actor and intentionally reject Pause without parking.
    private func pausedNativeHandler(_ request: [String: Any]) async -> [String: Any] {
        let owner = TaskOwnership.current!
        XCTAssertFalse(Thread.isMainThread)
        owner.pause() // Pause after the bridge's async entry, before delivery.
        do { try TaskOwnership.commit { XCTFail("Paused delivery escaped") } }
        catch { XCTAssertTrue(error is CancellationError) }
        return ["kind": "bridge_response", "task_generation_id": owner.id,
                "request_id": request["request_id"]!, "ok": false, "error_code": "cancelled"]
    }
    func testRevokedLeaseRejectsEveryDeliveryAndNestedCallback() throws {
        let old = TaskLease(), newer = TaskLease()
        var effects = 0
        try TaskOwnership.$current.withValue(old) { try TaskOwnership.commit { effects += 1 } }
        old.revoke()
        XCTAssertThrowsError(try old.commit { effects += 1 })
        TaskOwnership.callback(old) { effects += 1 }
        TaskOwnership.callback(newer) {
            XCTAssertTrue(TaskOwnership.current === newer)
            TaskOwnership.callback(old) { effects += 1 }
        }
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(old.staleWorkCount, 3)
        XCTAssertFalse(old.accepts(newer.id))
    }
    func testInstructionCorrectionFencesOldActionsAndCompletionButPreservesDispatchedWork() throws {
        let lease = TaskLease(), correction = UUID().uuidString.lowercased()
        try lease.beginInstructionCorrection(id: correction, revision: 1)
        XCTAssertThrowsError(try lease.validateInstructionRevision(0))
        XCTAssertNoThrow(try lease.validateInstructionRevision(0, allowDispatchedReceipt: true))
        XCTAssertFalse(lease.claimCompletion(instructionRevision: 0))

        try lease.applyInstructionCorrection(id: correction, revision: 1)
        XCTAssertNoThrow(try lease.applyInstructionCorrection(id: correction, revision: 1))
        XCTAssertThrowsError(try lease.validateInstructionRevision(0))
        XCTAssertNoThrow(try lease.validateInstructionRevision(0, allowDispatchedReceipt: true))
        XCTAssertFalse(lease.claimCompletion(instructionRevision: 0))
        XCTAssertTrue(lease.claimCompletion(instructionRevision: 1))
        XCTAssertThrowsError(try lease.beginInstructionCorrection(id: UUID().uuidString, revision: 2))
    }
    func testInstructionCorrectionPersistenceRollbackRestoresPriorAuthority() throws {
        let lease = TaskLease(), correction = UUID().uuidString.lowercased()
        try lease.beginInstructionCorrection(id: correction, revision: 1)
        XCTAssertFalse(lease.claimCompletion(instructionRevision: 0))
        lease.cancelInstructionCorrection(id: correction)
        XCTAssertFalse(lease.hasPendingInstructionCorrection)
        XCTAssertNoThrow(try lease.validateInstructionRevision(0))
        XCTAssertTrue(lease.claimCompletion(instructionRevision: 0))
    }
    func testCorrectionCanBeAcknowledgedWhilePausedWithoutResumingLease() throws {
        let lease = TaskLease(), correction = UUID().uuidString.lowercased()
        lease.pause()
        try lease.beginInstructionCorrection(id: correction, revision: 1)
        try lease.applyInstructionCorrection(id: correction, revision: 1)
        XCTAssertEqual(lease.state, .paused)
        XCTAssertEqual(lease.currentInstructionRevision, 1)
        XCTAssertNoThrow(try lease.validateInstructionRevision(1))
        XCTAssertFalse(lease.claimCompletion(instructionRevision: 0))
    }
    func testWorkingDocumentUpdateFencesCompletionUntilAtomicAcknowledgement() throws {
        let lease = TaskLease(), updateID = UUID().uuidString.lowercased()
        try lease.beginWorkingDocumentUpdate(id: updateID, revision: 1)
        let pending = lease.claimCompletionGate(instructionRevision: 0)
        XCTAssertFalse(pending.accepted)
        XCTAssertTrue(pending.pendingWorkingDocument)
        XCTAssertFalse(pending.pendingCorrection)
        XCTAssertThrowsError(try lease.validateWorkingDocumentRevision(0))

        var installed = false
        try lease.applyWorkingDocumentUpdate(id: updateID, revision: 1) { installed = true }
        XCTAssertTrue(installed)
        XCTAssertEqual(lease.currentWorkingDocumentRevision, 1)
        XCTAssertTrue(lease.claimCompletionGate(instructionRevision: 0).accepted)
    }

    func testWorkingDocumentWireControlContainsOnlyOpaqueSelectionReference() {
        let selectionID = UUID().uuidString.lowercased()
        let candidate = WorkingDocumentCandidate(selectionID: selectionID, displayID: 1, pid: 42,
            bundleID: "com.example.editor", processLaunchTime: 1, applicationName: "Editor",
            title: "Budget", location: "/Users/test/Budget.xlsx", documentURL: "file:///Users/test/Budget.xlsx",
            accessibilityIdentity: "native-window-id", graphicsWindowID: 9, focused: true)
        let update = WorkingDocumentUpdate(id: UUID().uuidString.lowercased(), generationID: "generation",
                                           revision: 1, candidate: candidate)
        let wire = update.wireValue
        XCTAssertEqual(Set(wire.keys), Set(["version", "update_id", "task_generation_id", "binding_revision", "selection_id"]))
        XCTAssertEqual(wire["selection_id"] as? String, selectionID)
        XCTAssertFalse(wire.values.contains { String(describing: $0).contains("Budget") })
        XCTAssertFalse(wire.values.contains { String(describing: $0).contains("native-window-id") })
    }
    func testPauseRetainsGenerationAndWaitsUntilResume() async throws {
        let lease = TaskLease(), started = expectation(description: "Suspended worker")
        lease.pause()
        let worker = Task {
            started.fulfill()
            try await lease.checkpoint()
            return try lease.commit { lease.id }
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(lease.accepts(lease.id))
        XCTAssertEqual(lease.state, .paused)
        lease.resume()
        let value = try await worker.value
        XCTAssertEqual(value, lease.id)
        lease.pause(); lease.revoke()
        do { try await lease.checkpoint(); XCTFail("Revoked pause resumed") } catch {}
    }
    func testCommitAndRevocationHaveOneOrderingBoundary() async {
        let lease = TaskLease(), entered = expectation(description: "Commit admitted"), revoked = expectation(description: "Revoked")
        let release = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            try lease.commit { entered.fulfill(); release.wait() }
        }
        await fulfillment(of: [entered], timeout: 1)
        DispatchQueue.global().async { lease.revoke(); revoked.fulfill() }
        release.signal()
        _ = try? await worker.value
        await fulfillment(of: [revoked], timeout: 1)
        XCTAssertThrowsError(try lease.commit {})
    }
    func testDelayedCaptureActivationLaunchAndRestorationCannotDeliver() async {
        for phase in ["capture", "activation", "launch", "restore", "notification", "cursor"] {
            let lease = TaskLease(), suspension = Suspension(), entered = expectation(description: phase)
            var delivered = false
            let worker = Task {
                await suspension.wait(entered)
                TaskOwnership.callback(lease) { delivered = true }
            }
            await fulfillment(of: [entered], timeout: 1)
            lease.revoke()
            await suspension.release()
            await worker.value
            XCTAssertFalse(delivered, phase)
        }
    }
    func testRevokedFileAndCommandRequestsHaveNoEffects() async throws {
        let lease = TaskLease(), executor = TaskToolExecutor()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lease.revoke()
        for action: [String: Any] in [
            ["type": "write_file", "path": marker.path, "content": "bad"],
            ["type": "run_command", "argv": ["/usr/bin/touch", marker.path]]
        ] {
            do { _ = try await TaskOwnership.$current.withValue(lease) { try await executor.perform(action: action) }; XCTFail("Stale action executed") } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testDiscardedScreenshotsAreRemovedAtRetirement() throws {
        let lease = TaskLease()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: path)
        try lease.ownArtifact(path)
        lease.revoke(); lease.retire(); lease.retire()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        try Data([1]).write(to: path)
        XCTAssertThrowsError(try lease.ownArtifact(path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testBridgeRejectsCrossTaskRequestBeforeCaptureOrActions() async throws {
        let lease = TaskLease(), other = TaskLease(), bridge = bridge()
        try bridge.bind(lease)
        XCTAssertThrowsError(try bridge.bind(other))
        for method in ["observe", "act"] {
            let response = await TaskOwnership.$current.withValue(lease) {
                await bridge.handle(["kind": "bridge_request", "task_generation_id": other.id, "request_id": "x", "method": method])
            }
            XCTAssertEqual(response["ok"] as? Bool, false)
            XCTAssertEqual(response["error_code"] as? String, "cancelled")
            XCTAssertEqual(response["task_generation_id"] as? String, lease.id)
        }
        lease.revoke(); lease.retire(); try bridge.bind(other)
    }
    @MainActor func testDrainBlocksNextTaskAndDiscardsLateAction() async throws {
        let suspension = Suspension(), entered = expectation(description: "Native pending")
        let waiting = expectation(description: "Shutdown deadline reported"), stopped = expectation(description: "Stopped once")
        let initialStatus = expectation(description: "Identical earlier status delivered")
        let lease = TaskLease()
        let helper = try helper("emit('status', message='Waiting for the previous task’s native work to finish safely…')\nemit('bridge_request', request_id='x', method='act', params={})\ntime.sleep(20)")
        var effects = 0, terminalCount = 0, statusCount = 0
        let runtime = AgentRuntimeProcess(bridge: bridge(), drainReportingDelay: 0.05) { request in
            let owner = TaskOwnership.current!
            if request["method"] as? String == "completion_gate" {
                let revision = (request["instruction_revision"] as? NSNumber)?.uint64Value ?? 0
                return ["kind": "bridge_response", "task_generation_id": owner.id,
                        "request_id": request["request_id"]!, "ok": true,
                        "result": ["accepted": owner.claimCompletion(instructionRevision: revision)]]
            }
            await suspension.wait(entered) // Models a non-cancellable OS completion.
            _ = try? owner.commit { effects += 1 }
            return ["kind": "bridge_response", "task_generation_id": owner.id, "request_id": "x", "ok": true, "result": [:]]
        }
        runtime.onEvent = { event in
            if case .status = event {
                statusCount += 1
                if statusCount == 1 { initialStatus.fulfill() }
                else { waiting.fulfill() }
            }
            if case .stopped = event {
                terminalCount += 1
                XCTAssertEqual(lease.state, .draining)
                // Cleanup still owns this generation while the terminal handler runs.
                do { try runtime.start(task: "too early", display: self.display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: ""); XCTFail("Started before cleanup") } catch {}
                stopped.fulfill()
            }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "", lease: lease)
        await fulfillment(of: [entered, initialStatus], timeout: 3)
        runtime.stop()
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertThrowsError(try runtime.start(task: "next", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: ""))
        await suspension.release()
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(effects, 0); XCTAssertEqual(terminalCount, 1); XCTAssertEqual(lease.state, .retired)
        XCTAssertEqual(statusCount, 2)
        let next = try self.helper("emit('complete', message='next')")
        let complete = expectation(description: "Next generation completed")
        runtime.onEvent = { if case .completed = $0 { complete.fulfill() } }
        try runtime.start(task: "next", display: display, runtimeURL: next, openClawURL: next, geminiAPIKey: "")
        await fulfillment(of: [complete], timeout: 3)
    }
    @MainActor func testProtocolMismatchFailsOnceWithoutExecutingBridge() async throws {
        let helper = try helper("print(json.dumps(dict(kind='bridge_request', task_generation_id='old', instruction_revision=0, working_document_revision=0, request_id='x', method='act')), flush=True)\ntime.sleep(20)")
        let failed = expectation(description: "Mismatch rejected")
        var calls = 0
        let runtime = AgentRuntimeProcess(bridge: bridge()) { _ in calls += 1; return [:] }
        runtime.onEvent = { if case .failed(let message) = $0 { XCTAssertTrue(message.contains("ownership")); failed.fulfill() } }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "")
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testStopDrainsAnAlreadyParkedNativeWorker() async throws {
        let lease = TaskLease(), stopped = expectation(description: "Paused native worker drained")
        let helper = try helper("emit('bridge_request', request_id='parked', method='fixture')\ntime.sleep(20)")
        var terminalCount = 0
        let runtime = AgentRuntimeProcess(bridge: bridge(), bridgeHandler: pausedNativeHandler)
        runtime.onEvent = { event in
            if case .stopped = event { terminalCount += 1; stopped.fulfill() }
            if case .completed = event { XCTFail("Stopped task completed") }
            if case .failed(let message) = event { XCTFail(message) }
        }
        defer { runtime.stop() }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "", lease: lease)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while lease.pauseWaiterCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(lease.pauseWaiterCount, 1)
        runtime.stop()
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(lease.pauseWaiterCount, 0)
        XCTAssertEqual(lease.state, .retired)
    }
    @MainActor func testOldSecureInputCannotReachNewTaskPipe() async throws {
        let helper = try helper("emit('user_input_required', request_id='same')\nreply=json.loads(sys.stdin.readline())\nassert reply['value']=='current'\nassert reply['task_generation_id']==config['task_generation_id']\nemit('complete', message='secure')")
        let complete = expectation(description: "Correct input received")
        let lease = TaskLease()
        let runtime = AgentRuntimeProcess(bridge: bridge())
        runtime.onEvent = { event in
            if case .userInputRequired = event {
                runtime.submitUserInput(requestID: "same", value: "stale", taskGenerationID: TaskLease().id, instructionRevision: 0)
                runtime.submitUserInput(requestID: "same", value: "current", taskGenerationID: lease.id, instructionRevision: 0)
            }
            if case .completed = event { complete.fulfill() }
            if case .failed(let message) = event { XCTFail(message); complete.fulfill() }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "", lease: lease)
        await fulfillment(of: [complete], timeout: 3)
    }
    @MainActor func testCorrectionAcknowledgmentIsIdempotentAndDropsOlderStatus() async throws {
        let applied = expectation(description: "Correction acknowledgment received twice")
        applied.expectedFulfillmentCount = 2
        let currentStatus = expectation(description: "Only current-revision status delivered")
        let complete = expectation(description: "Current-revision completion accepted")
        let helper = try helper("""
        correction=json.loads(sys.stdin.readline())
        assert correction['kind']=='instruction_correction'
        payload=correction['correction']
        emit('instruction_correction_applied', correction_id=payload['correction_id'], instruction_revision=1)
        emit('instruction_correction_applied', correction_id=payload['correction_id'], instruction_revision=1)
        emit('status', message='stale status', instruction_revision=0)
        emit('status', message='current status', instruction_revision=1)
        emit('complete', message='completed under the corrected request', instruction_revision=1)
        """)
        let lease = TaskLease(), runtime = AgentRuntimeProcess(bridge: bridge())
        var statuses: [String] = []
        runtime.onEvent = { event in
            switch event {
            case .instructionCorrectionApplied: applied.fulfill()
            case .status(let message): statuses.append(message); if message == "current status" { currentStatus.fulfill() }
            case .completed: complete.fulfill()
            case .failed(let message): XCTFail(message); complete.fulfill()
            default: break
            }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper,
                          geminiAPIKey: "", lease: lease)
        let correction = TaskInstructionCorrection(revision: 1,
            submission: AgentTaskSubmission(request: "Use the other spreadsheet"))
        try runtime.prepareInstructionCorrection(correction, generationID: lease.id)
        try runtime.sendInstructionCorrection(correction, generationID: lease.id)
        await fulfillment(of: [applied, currentStatus, complete], timeout: 4)
        XCTAssertEqual(statuses, ["current status"])
    }
    @MainActor func testStopDropsQueuedOutputAndOverridesUndeliveredCompletion() async throws {
        let helper = try helper("for _ in range(100): emit('status', message='pending')\nemit('output', content='stale')\nemit('complete', message='old')\nemit('complete', message='duplicate')")
        let stopped = expectation(description: "Stopped exactly once")
        let runtime = AgentRuntimeProcess(bridge: bridge())
        var requested = false, terminalCount = 0
        runtime.onEvent = { event in
            switch event {
            case .status:
                if !requested { requested = true; runtime.stop() }
            case .stopped: terminalCount += 1; stopped.fulfill()
            case .output: XCTFail("Stopped task published queued output")
            case .completed, .failed: XCTFail("Stop was overridden by an old terminal event")
            default: break
            }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "")
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(terminalCount, 1)
    }
    func testStoppingOwnedCommandDrainsItsProcessAndCannotWriteAgain() async throws {
        let lease = TaskLease(), executor = TaskToolExecutor()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        let worker = Task.detached {
            try await TaskOwnership.$current.withValue(lease) {
                try await executor.perform(action: ["type": "run_command", "argv": ["/bin/zsh", "-f", "-c", "touch \"$1\"; exec /bin/sleep 20", "fixture", marker.path]])
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        lease.pause(); executor.pauseActiveCommand()
        lease.resume(); executor.resumeActiveCommand()
        lease.revoke(); executor.cancelActiveCommand(); worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled command returned success") } catch {}
        try FileManager.default.removeItem(at: marker)
        do {
            _ = try await TaskOwnership.$current.withValue(lease) {
                try await executor.perform(action: ["type": "write_file", "path": marker.path, "content": "bad"])
            }
            XCTFail("Revoked task wrote after shutdown")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testStartupFailureRetiresOwnershipAndAllowsAnotherGeneration() throws {
        let lease = TaskLease(), runtime = AgentRuntimeProcess(bridge: bridge())
        let bad = try helper("pass")
        try "#!/nonexistent/taskpilot-interpreter\n".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try runtime.start(task: "fixture", display: display, runtimeURL: bad, openClawURL: bad, geminiAPIKey: "", lease: lease))
        XCTAssertEqual(lease.state, .retired)
        XCTAssertThrowsError(try lease.commit {})
    }

    @MainActor func testProcessExitDrainsItsLastErrorLine() async throws {
        let helper = try helper("sys.stderr.write('fixture crash detail\\n'); sys.stderr.flush()")
        let failed = expectation(description: "Last error retained")
        let runtime = AgentRuntimeProcess(bridge: bridge())
        runtime.onEvent = { if case .failed(let message) = $0 { XCTAssertEqual(message, "fixture crash detail"); failed.fulfill() } }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "")
        await fulfillment(of: [failed], timeout: 3)
    }

    @MainActor func testStreamedBurstAndExitTailDeliverEachEventOnceInOrder() async throws {
        let helper = try helper("""
        messages = [dict(kind='status', task_generation_id=config['task_generation_id'], instruction_revision=0, working_document_revision=0, message=str(i) + ': ☃ 🧭') for i in range(1200)]
        payload = ''.join(json.dumps(message, ensure_ascii=False) + '\\n' for message in messages)
        completion_gate(0)
        payload += json.dumps(dict(kind='complete', task_generation_id=config['task_generation_id'], instruction_revision=0, working_document_revision=0, message='burst finished'))
        encoded = payload.encode('utf-8')
        for offset in range(0, len(encoded), 317):
            sys.stdout.buffer.write(encoded[offset:offset + 317]); sys.stdout.buffer.flush()
        """)
        let complete = expectation(description: "Burst and final tail drained")
        var messages: [String] = [], terminalCount = 0, bridgeCalls = 0
        let runtime = AgentRuntimeProcess(bridge: bridge()) { request in
            bridgeCalls += 1
            if request["method"] as? String == "completion_gate" {
                let owner = TaskOwnership.current!
                let revision = (request["instruction_revision"] as? NSNumber)?.uint64Value ?? 0
                return ["kind": "bridge_response", "task_generation_id": owner.id,
                        "request_id": request["request_id"]!, "ok": true,
                        "result": ["accepted": owner.claimCompletion(instructionRevision: revision)]]
            }
            return ["kind": "bridge_response", "task_generation_id": TaskOwnership.current!.id,
                    "request_id": request["request_id"]!, "ok": true, "result": [:]]
        }
        runtime.onEvent = { event in
            if case .status(let message) = event { messages.append(message) }
            if case .completed(let message) = event {
                XCTAssertEqual(message, "burst finished")
                terminalCount += 1; complete.fulfill()
            }
            if case .failed(let message) = event { XCTFail(message); complete.fulfill() }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "")
        await fulfillment(of: [complete], timeout: 5)
        XCTAssertEqual(messages, (0..<1200).map { "\($0): ☃ 🧭" })
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(bridgeCalls, 1, "Only the atomic completion gate should cross the bridge")
    }

    @MainActor func testRuntimeCompletionWaitsForDescendantTeardownAndDrainsExitTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = root.appendingPathComponent("started"), late = root.appendingPathComponent("late")
        let helper = try helper("""
        import subprocess
        subprocess.Popen(['/bin/zsh', '-f', '-c', 'trap "" TERM; touch "$1"; /bin/sleep 0.7; touch "$2"', 'fixture', \(String(reflecting: started.path)), \(String(reflecting: late.path))])
        while not __import__('os').path.exists(\(String(reflecting: started.path))): time.sleep(0.005)
        completion_gate(0)
        sys.stdout.write(json.dumps(dict(kind='complete', task_generation_id=config['task_generation_id'], instruction_revision=0, working_document_revision=0, message='exit tail')))
        sys.stdout.flush()
        """)
        let completed = expectation(description: "Tree drained before completion")
        let lease = TaskLease(), runtime = AgentRuntimeProcess(bridge: bridge())
        var terminals = 0
        runtime.onEvent = { event in
            if case .completed(let message) = event {
                XCTAssertEqual(message, "exit tail"); terminals += 1; completed.fulfill()
            }
            if case .failed(let message) = event { XCTFail(message); completed.fulfill() }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "", lease: lease)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(lease.state, .retired)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(terminals, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }

    @MainActor func testPressureControlIsPrivateAndRequiresRuntimeNegotiation() async throws {
        for version in ["None", "True", "0", "1"] {
            let supported = version == "1", monitor = MemoryPressureMonitor(listen: false)
            let helper = try helper("""
            import select
            version=\(version)
            if version is not None: emit('runtime_ready', memory_pressure_version=version)
            emit('status', message='ready')
            readable=select.select([sys.stdin], [], [], \(supported ? "2" : "0.25"))[0]
            assert bool(readable)==\(supported ? "True" : "False")
            if readable:
                control=json.loads(sys.stdin.readline())
                assert control==dict(kind='memory_pressure', task_generation_id=config['task_generation_id'], level='warning')
            emit('complete', message='finished')
            """)
            let complete = expectation(description: "Negotiated pressure control \(version)")
            var statuses = 0, terminalCount = 0
            let runtime = AgentRuntimeProcess(bridge: bridge(), memoryPressure: monitor)
            runtime.onEvent = { event in
                switch event {
                case .status(let message):
                    XCTAssertEqual(message, "ready"); statuses += 1
                    monitor.receive(.critical)
                case .completed: terminalCount += 1; complete.fulfill()
                case .failed(let message): XCTFail(message); complete.fulfill()
                default: XCTFail("Private control reached the event handler")
                }
            }
            try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "")
            await fulfillment(of: [complete], timeout: 4)
            runtime.stop()
            XCTAssertEqual(statuses, 1)
            XCTAssertEqual(terminalCount, 1)
        }
    }

    @MainActor func testDuplicateRuntimeSnapshotsKeepTransitionsResultsAndNewInvocations() async throws {
        let helper = try helper("""
        fields = dict(verification=0, retries=0, model_switches=0, cache_hits=0, reconnects=0)
        for _ in range(1000):
            emit('status', message='Working')
            emit('request_metrics', planning=1, **fields)
        for message, count in [('Checking', 2), ('Working', 1)]:
            emit('status', message=message)
            emit('request_metrics', planning=count, **fields)
        for i in range(2):
            emit('output', title='Result', content='Saved', show_output=True)
            emit('model_health', model='fixture', state='verified', detail='Ready')
            emit('bridge_request', request_id=str(i), method='fixture', params={})
            response=json.loads(sys.stdin.readline())
            assert response['request_id']==str(i)
        completion_gate(0)
        sys.stdout.write(json.dumps(dict(kind='complete', task_generation_id=config['task_generation_id'], instruction_revision=0, working_document_revision=0, message='finished')))
        sys.stdout.flush()
        """)
        let next = try self.helper("emit('status', message='Working')\nemit('request_metrics', planning=1, verification=0, retries=0, model_switches=0, cache_hits=0, reconnects=0)\nemit('complete', message='next')")
        let finished = expectation(description: "Filtered burst and final exit tail")
        var events: [String] = [], bridgeCalls = 0
        let runtime = AgentRuntimeProcess(bridge: bridge()) { request in
            bridgeCalls += 1
            if request["method"] as? String == "completion_gate" {
                let owner = TaskOwnership.current!
                let revision = (request["instruction_revision"] as? NSNumber)?.uint64Value ?? 0
                return ["kind": "bridge_response", "task_generation_id": owner.id,
                        "request_id": request["request_id"]!, "ok": true,
                        "result": ["accepted": owner.claimCompletion(instructionRevision: revision)]]
            }
            return ["kind": "bridge_response", "task_generation_id": request["task_generation_id"]!,
                    "request_id": request["request_id"]!, "ok": true, "result": [:]]
        }
        runtime.onEvent = { event in
            switch event {
            case .status(let value): events.append(value)
            case .diagnostics(let value): events.append("metrics:\(value.planning)")
            case .output: events.append("output")
            case .modelHealth: events.append("health")
            case .completed: events.append("complete"); finished.fulfill()
            case .failed(let message): XCTFail(message); finished.fulfill()
            default: XCTFail("Unexpected event")
            }
        }
        defer { runtime.stop() }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "")
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(events, ["Working", "metrics:1", "Checking", "metrics:2", "Working", "metrics:1",
                                "output", "health", "output", "health", "complete"])
        XCTAssertEqual(bridgeCalls, 3)
        let continued = expectation(description: "New task publishes identical initial snapshots")
        events.removeAll()
        runtime.onEvent = { event in
            switch event {
            case .status(let value): events.append(value)
            case .diagnostics(let value): events.append("metrics:\(value.planning)")
            case .completed: events.append("complete"); continued.fulfill()
            case .failed(let message): XCTFail(message); continued.fulfill()
            default: XCTFail("Unexpected event")
            }
        }
        try runtime.start(task: "next", display: display, runtimeURL: next, openClawURL: next, geminiAPIKey: "")
        await fulfillment(of: [continued], timeout: 3)
        XCTAssertEqual(events, ["Working", "metrics:1", "complete"])
    }

    @MainActor func testStatusIsRepublishedAfterPauseResumeAndSecureInputReply() async throws {
        let helper = try helper("""
        emit('status', message='Working')
        emit('bridge_request', request_id='pause', method='fixture', params={})
        json.loads(sys.stdin.readline())
        emit('status', message='Working')
        emit('user_input_required', request_id='credential')
        reply=json.loads(sys.stdin.readline())
        assert reply['value']=='fixture'
        emit('status', message='Working')
        emit('complete', message='finished')
        """)
        let lease = TaskLease(), finished = expectation(description: "Status survives external transitions")
        let firstStatus = expectation(description: "Initial status delivered")
        let entered = expectation(description: "Fixture waits before its next status")
        let suspension = Suspension()
        var statuses = 0
        let runtime = AgentRuntimeProcess(bridge: bridge()) { request in
            if request["method"] as? String == "completion_gate" {
                let owner = TaskOwnership.current!
                let revision = (request["instruction_revision"] as? NSNumber)?.uint64Value ?? 0
                return ["kind": "bridge_response", "task_generation_id": owner.id,
                        "request_id": request["request_id"]!, "ok": true,
                        "result": ["accepted": owner.claimCompletion(instructionRevision: revision)]]
            }
            await suspension.wait(entered)
            return ["kind": "bridge_response", "task_generation_id": TaskOwnership.current!.id,
                    "request_id": request["request_id"]!, "ok": true, "result": [:]]
        }
        runtime.onEvent = { event in
            switch event {
            case .status(let message):
                XCTAssertEqual(message, "Working")
                statuses += 1
                if statuses == 1 { firstStatus.fulfill() }
            case .userInputRequired(let request):
                XCTAssertTrue(runtime.submitUserInput(requestID: request.requestID, value: "fixture",
                    taskGenerationID: lease.id, instructionRevision: request.instructionRevision))
            case .completed: finished.fulfill()
            case .failed(let message): XCTFail(message); finished.fulfill()
            default: break
            }
        }
        defer { runtime.stop() }
        try runtime.start(task: "fixture", display: display, runtimeURL: helper, openClawURL: helper, geminiAPIKey: "", lease: lease)
        await fulfillment(of: [firstStatus, entered], timeout: 3)
        runtime.pause(); runtime.resume()
        await suspension.release()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(statuses, 3)
    }

    @MainActor func testMetricsCodecKeepsSnakeCaseAndRecoversAcrossMessagesAndInvocations() async throws {
        let first = try helper("""
        fields = dict(verification=2, retries=0, model_switches=3, cache_hits=4, reconnects=0)
        for i in range(120):
            if i % 17 == 0: emit('request_metrics', planning='invalid', **fields)
            emit('request_metrics', planning=i, repairs=1, command_probe_cache_hits=i, local_targeted_checks=1, **fields)
        emit('complete', message='first')
        """)
        let next = try helper("emit('request_metrics', planning=7, verification=1, retries=0, model_switches=0, cache_hits=0, reconnects=0)\nemit('complete', message='next')")
        let firstComplete = expectation(description: "Repeated metrics decoded")
        let nextComplete = expectation(description: "Next invocation decoded legacy metrics")
        var metrics: [AgentRequestMetrics] = []
        let runtime = AgentRuntimeProcess(bridge: bridge())
        runtime.onEvent = { event in
            if case .diagnostics(let value) = event { metrics.append(value) }
            if case .completed = event { firstComplete.fulfill() }
            if case .failed(let message) = event { XCTFail(message); firstComplete.fulfill() }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: first, openClawURL: first, geminiAPIKey: "")
        await fulfillment(of: [firstComplete], timeout: 5)
        XCTAssertEqual(metrics.count, 120)
        for (index, value) in metrics.enumerated() {
            XCTAssertEqual(value.planning, index)
            XCTAssertEqual(value.modelSwitches, 3)
            XCTAssertEqual(value.cacheHits, 4)
            XCTAssertEqual(value.commandProbeCacheHits, index)
            XCTAssertEqual(value.localTargetedChecks, 1)
            XCTAssertEqual(value.repairs, 1)
            XCTAssertNil(value.providerRetries)
        }
        metrics.removeAll()
        runtime.onEvent = { event in
            if case .diagnostics(let value) = event { metrics.append(value) }
            if case .completed = event { nextComplete.fulfill() }
            if case .failed(let message) = event { XCTFail(message); nextComplete.fulfill() }
        }
        try runtime.start(task: "fixture", display: display, runtimeURL: next, openClawURL: next, geminiAPIKey: "")
        await fulfillment(of: [nextComplete], timeout: 5)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.planning, 7)
        XCTAssertNil(metrics.first?.repairs)
        XCTAssertNil(metrics.first?.commandProbeCacheHits)
    }

}
