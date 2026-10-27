import CoreFoundation
import Darwin
import Foundation

enum AgentTaskOutputKind: String, Equatable {
    case answer
    case completion
    case result
}

struct AgentTaskOutput: Equatable {
    let shouldShow: Bool
    let title: String
    let content: String
    let decidedByAgent: Bool
    let kind: AgentTaskOutputKind

    init(
        shouldShow: Bool,
        title: String,
        content: String,
        decidedByAgent: Bool,
        kind: AgentTaskOutputKind = .result
    ) {
        self.shouldShow = shouldShow
        self.title = title
        self.content = content
        self.decidedByAgent = decidedByAgent
        self.kind = kind
    }
}

enum AgentUserInputKind: String, Equatable {
    case password
    case verificationCode = "verification_code"
    case secret
}

struct AgentUserInputRequest: Equatable, Identifiable {
    let requestID: String
    let taskGenerationID: String
    let instructionRevision: UInt64
    var workingDocumentRevision: UInt64
    let title: String
    let message: String
    let kind: AgentUserInputKind

    init(requestID: String, taskGenerationID: String, instructionRevision: UInt64,
         workingDocumentRevision: UInt64 = 0, title: String, message: String, kind: AgentUserInputKind) {
        self.requestID = requestID
        self.taskGenerationID = taskGenerationID
        self.instructionRevision = instructionRevision
        self.workingDocumentRevision = workingDocumentRevision
        self.title = title
        self.message = message
        self.kind = kind
    }

    var id: String { requestID }
}

enum RuntimeEvent {
    case status(String)
    case modelHealth(String, String, String)
    case diagnostics(AgentRequestMetrics)
    case output(AgentTaskOutput)
    case userInputRequired(AgentUserInputRequest)
    case targetChoiceRequired(AgentTargetChoiceRequest)
    case targetChoiceApplied(requestID: String, candidateID: String, label: String, detail: String,
                             taskGenerationID: String, bindingRevision: UInt64,
                             workingDocumentRevision: UInt64, workingDocument: [String: Any]?)
    case targetChoiceRejected(requestID: String, taskGenerationID: String, bindingRevision: UInt64,
                              instructionRevision: UInt64, workingDocumentRevision: UInt64, message: String)
    case taskProgress(AgentTaskProgressSnapshot)
    case taskInputRoles(AgentTaskInputRolesSnapshot)
    case taskContinuationCheckpoint(AgentTaskContinuationCheckpoint)
    case taskWait(AgentTaskWaitSnapshot)
    case taskDestination(AgentTaskDestinationSnapshot)
    case taskChangeLens(AgentTaskChangeLensSnapshot)
    case instructionCorrectionApplied(id: String, taskGenerationID: String, revision: UInt64)
    case workingDocumentApplied(id: String, taskGenerationID: String, revision: UInt64, document: [String: Any]?)
    case workingDocumentNeedsReselection(taskGenerationID: String, revision: UInt64, application: String, title: String, selection: Bool)
    case workingDocumentUpdateRejected(id: String, taskGenerationID: String, revision: UInt64, message: String)
    case actionPresentation(actionID: String, taskGenerationID: String, verificationScope: String)
    case completed(String)
    case failed(String)
    case stopped
}

struct AgentActionPresentationMessage: Equatable {
    let actionID: String
    let generationID: String
    let verificationScope: String

    static let supportedScopes: Set<String> = [
        "dialog_appeared", "field_value", "file_contents", "file_exists", "directory_exists", "path_absent"
    ]

    static func parse(_ message: [String: Any], generationID: String,
                      knownActionIDs: Set<String>) -> Self? {
        guard Set(message.keys) == Set(["kind", "task_generation_id", "action_id", "state", "verification_scope"]),
              message["kind"] as? String == "action_presentation",
              message["task_generation_id"] as? String == generationID,
              message["state"] as? String == "confirmed",
              let actionID = message["action_id"] as? String,
              let uuid = UUID(uuidString: actionID), uuid.uuidString.lowercased() == actionID,
              knownActionIDs.contains(actionID),
              let scope = message["verification_scope"] as? String,
              supportedScopes.contains(scope) else { return nil }
        return Self(actionID: actionID, generationID: generationID, verificationScope: scope)
    }
}

enum RuntimeProcessError: LocalizedError {
    case runtimeMissing
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The bundled OpenClaw bridge executable is missing"
        case .alreadyRunning: return "An agent task is already running"
        }
    }
}

final class AgentRuntimeProcess {
    var onEvent: (@MainActor (RuntimeEvent) -> Void)?

    private let bridge: AgentAutomationBridge
    private let bridgeHandler: (([String: Any]) async -> [String: Any])?
    private let drainReportingDelay: TimeInterval
    private let ioQueue = DispatchQueue(label: "com.orbitagent.runtime-io")
    private let ioQueueKey = DispatchSpecificKey<UInt8>()
    private let telemetry = BackendTelemetry.current
    private var pressureRegistration: MemoryPressureMonitor.Registration?
    private final class Invocation {
        let lease: TaskLease
        let process: SubprocessSupervisor
        let input: Pipe
        let handler: (@MainActor (RuntimeEvent) -> Void)?
        let metricsDecoder: JSONDecoder
        var outputBuffer = RuntimeLineBuffer()
        var writer: RuntimePipeWriter?
        var transportFailure: String?
        var receiptIDs: Set<String> = []
        var progressRevision: UInt64 = 0
        var inputRolesRevision: UInt64 = 0
        var exactInputReferences: [AgentTaskInputReference]
        var taskRequest: String
        var continuationRevision: UInt64 = 0
        var waitRevision: UInt64 = 0
        var destinationRevision: UInt64 = 0
        var queuedEventBytes = 0
        var queuedEventCount = 0
        var pendingBridgeBytes = 0
        var snapshots = RuntimeSnapshotFilter()
        var supportsMemoryPressure = false
        var startupSpan: BackendTelemetry.Span?
        var lastErrorLine = ""
        var requestedStop = false
        var receivedTerminalEvent = false
        var pendingTerminalEvent: RuntimeEvent?
        var operations: [UUID: Task<Void, Never>] = [:]
        var exited = false
        var pendingUserInputID: String?
        var pendingUserInputRevision: UInt64?
        var correctionIDs: Set<String> = []
        var corrections: [String: TaskInstructionCorrection] = [:]
        var workingDocumentIDs: Set<String> = []
        var pendingTargetChoice: AgentTargetChoiceRequest?
        var targetChoiceCandidates: Set<String> = []
        var pendingTargetChoiceApplying = false
        var resolvedTargetChoiceIDs: [String: UInt64] = [:]
        var resolvedTargetChoiceOrder: [String] = []
        var terminalDelivered = false
        var drainStarted: ContinuousClock.Instant?
        var drainReported = false
        init(lease: TaskLease, process: SubprocessSupervisor, input: Pipe,
             taskRequest: String, exactInputReferences: [AgentTaskInputReference],
             handler: (@MainActor (RuntimeEvent) -> Void)?) {
            self.lease = lease; self.process = process; self.input = input; self.handler = handler
            self.taskRequest = taskRequest
            self.exactInputReferences = exactInputReferences
            // Decode only on the owning runtime's serialized I/O queue.
            metricsDecoder = JSONDecoder()
            metricsDecoder.keyDecodingStrategy = .convertFromSnakeCase
        }
    }
    private var invocation: Invocation?

    init(bridge: AgentAutomationBridge, drainReportingDelay: TimeInterval = 5, memoryPressure: MemoryPressureMonitor = .shared, bridgeHandler: (([String: Any]) async -> [String: Any])? = nil) {
        self.bridge = bridge
        self.bridgeHandler = bridgeHandler
        self.drainReportingDelay = drainReportingDelay
        ioQueue.setSpecific(key: ioQueueKey, value: 1)
        pressureRegistration = memoryPressure.register { [weak self] in self?.evictRuntimeCaches() }
    }

    private func enqueueIO(_ work: @escaping () -> Void) {
        let wait = telemetry.beginQueueWait(.runtimeIO)
        ioQueue.async { wait.start(); work() }
    }

    private func syncIO<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil { return try work() }
        let wait = telemetry.beginQueueWait(.runtimeIO)
        return try ioQueue.sync { wait.start(); return try work() }
    }

    private func evictRuntimeCaches() {
        enqueueIO { [weak self] in
            guard let self, let run = self.invocation, run.supportsMemoryPressure,
                  run.lease.accepts(run.lease.id) else { return }
            self.send(["kind": "memory_pressure", "task_generation_id": run.lease.id,
                       "level": "warning"], for: run)
        }
    }

    func start(
        task: String,
        display: DisplayDescriptor,
        runtimeURL: URL,
        openClawURL: URL,
        geminiAPIKey: String,
        exactInputReferences: [AgentTaskInputReference] = [],
        continuationCheckpoint: AgentTaskContinuationCheckpoint? = nil,
        lease: TaskLease = TaskLease()
    ) throws {
        guard syncIO({ invocation == nil || invocation?.lease.state == .retired }) else { throw RuntimeProcessError.alreadyRunning }
        let startup = telemetry.begin(.startup)
        var startupTransferred = false
        defer { if !startupTransferred { startup.finish(.failed) } }
        guard FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
            throw RuntimeProcessError.runtimeMissing
        }

        let process = SubprocessSupervisor(descriptorOwner: lease.descriptorOwner)
        let input = try SubprocessSupervisor.makePrivatePipe(owner: lease.descriptorOwner, subsystem: .runtimeWritePipe)
        let output = try SubprocessSupervisor.makePrivatePipe(owner: lease.descriptorOwner, subsystem: .runtimeReadPipe)
        let error = try SubprocessSupervisor.makePrivatePipe(owner: lease.descriptorOwner, subsystem: .runtimeReadPipe)
        try bridge.bind(lease)
        process.executableURL = runtimeURL
        process.arguments = [
            "--task", task,
            "--display-id", String(display.id),
            "--openclaw-path", openClawURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["ORBIT_CONTROLLER_PID"] = String(getpid())
        environment["ORBIT_OPENCLAW_PATH"] = openClawURL.path
        // Fixture executables may omit the descriptor; shipped task launches
        // always resolve the same private instance used by readiness and setup.
        if let descriptor = try? ManagedOpenClawDescriptor.load(), descriptor.executable == openClawURL.path {
            environment = descriptor.environment
            environment["PYTHONUNBUFFERED"] = "1"
            environment["ORBIT_CONTROLLER_PID"] = String(getpid())
            environment["ORBIT_OPENCLAW_PATH"] = openClawURL.path
            lease.managedRuntimeRoot = ManagedOpenClawDescriptor.root
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        let run = Invocation(lease: lease, process: process, input: input,
                             taskRequest: task, exactInputReferences: exactInputReferences, handler: onEvent)
        run.startupSpan = startup
        startupTransferred = true
        syncIO {
            invocation = run
            run.writer = RuntimePipeWriter(handle: input.fileHandleForWriting, queue: ioQueue, descriptorOwner: lease.descriptorOwner, telemetry: telemetry) { [weak self, weak run] code in
                guard let self, let run else { return }
                self.failTransport(code, for: run)
            }
        }
        installOutputHandler(output.fileHandleForReading, for: run)
        installErrorHandler(error.fileHandleForReading, for: run)

        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.enqueueIO {
                terminated.terminationHandler = nil
                guard self.invocation === run, run.process === terminated, !run.exited else { return }
                // Parent exit is not tree exit. Keep readers installed while
                // remaining runtime children are terminated and drained.
                if !run.requestedStop && run.pendingTerminalEvent == nil {
                    self.drainAvailable(output.fileHandleForReading) { self.appendOutput($0, for: run) }
                    self.drainAvailable(error.fileHandleForReading) { self.appendError($0, for: run) }
                }
                self.beginDrain(run)
                run.process.beginTeardown()
                run.process.whenTreeExits {
                    self.enqueueIO {
                        guard self.invocation === run, !run.exited else { return }
                        output.fileHandleForReading.readabilityHandler = nil
                        error.fileHandleForReading.readabilityHandler = nil
                        self.drainAvailable(output.fileHandleForReading) { self.appendOutput($0, for: run) }
                        self.appendOutput(Data(), for: run, flush: true)
                        self.drainAvailable(error.fileHandleForReading) { self.appendError($0, for: run) }
                        // Tree exit and final reads precede controller-side closure.
                        try? output.fileHandleForReading.close()
                        try? error.fileHandleForReading.close()
                        try? input.fileHandleForWriting.close()
                        run.process.markOutputDrained()
                        run.exited = true
                        if !run.requestedStop && run.pendingTerminalEvent == nil {
                            run.pendingTerminalEvent = .failed(run.lastErrorLine.isEmpty ? "The OpenClaw bridge exited unexpectedly" : run.lastErrorLine)
                        }
                    }
                }
            }
        }

        var launched = false
        do {
            try lease.commit { try process.run() }
            launched = true
            // Pass the secret through the already-private controller pipe,
            // never through arguments, environment variables, or logs. The
            // runtime consumes this first line before it begins bridge calls.
            var configurationFields: [String: Any] = [
                "kind": "runtime_configuration",
                "gemini_api_key": geminiAPIKey,
                "action_contract_hash": ActionContract.fingerprint,
                "action_contract_version": ActionContract.version,
                "task_generation_id": lease.id,
                "instruction_revision": lease.currentInstructionRevision,
                "stop_boundary_policy_version": StopBoundaryPolicy.version,
                "working_document_protocol_version": WorkingDocumentUpdate.protocolVersion,
                "target_choice_protocol_version": AgentTargetChoiceProtocol.version,
                "task_protocol_version": ActionContract.taskProtocolVersion,
                "exact_input_reference_version": AgentTaskInputReferenceProtocol.version,
                "exact_input_references": exactInputReferences.map(\.wireValue),
                "continuation_checkpoint_version": AgentTaskContinuationCheckpoint.protocolVersion,
                "coordinate_mapping_version": ScreenCoordinateMapping.version,
                "observation_completeness_version": ObservationCollection<Int>.version,
                "text_recognition_version": LocalTextRecognition.version,
                "evidence_consistency_version": ControlEvidencePolicy.version,
                "command_capability_version": CommandCapabilities.version,
                "wait_presentation_version": AgentTaskWaitSnapshot.version
            ]
            if let continuationCheckpoint {
                configurationFields["continuation_checkpoint"] = continuationCheckpoint.startupPayload
            }
            var configuration = try telemetry.encodeJSON(configurationFields, recordSize: false)
            configuration.append(0x0A)
            let sendSpan = telemetry.begin(.ipcSend)
            syncIO {
                run.writer?.enqueue(configuration, priority: true) { delivered in
                    sendSpan.finish(delivered ? .succeeded : .failed)
                }
            }
        } catch let launchError {
            if launched {
                // A successfully spawned helper must drain like every other
                // invocation, even if writing its startup configuration fails.
                enqueueIO {
                    run.pendingTerminalEvent = .failed("Could not start the agent: \(launchError.localizedDescription)")
                    self.beginDrain(run)
                    process.beginTeardown()
                }
                return
            }
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            for pipe in [input, output, error] {
                try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            }
            lease.revoke()
            run.startupSpan?.finish(.failed)
            run.startupSpan = nil
            syncIO { run.writer?.cancel(); run.exited = true; run.pendingTerminalEvent = nil; run.lease.retire() }
            throw launchError
        }
    }

    func pause() {
        syncIO {
            invocation?.snapshots.invalidateStatus()
            invocation?.lease.pause()
        }
        bridge.pauseActiveTool()
        signalRuntime(SIGSTOP)
    }

    func resume() {
        syncIO {
            invocation?.snapshots.invalidateStatus()
            invocation?.lease.resume()
        }
        bridge.resumeActiveTool()
        signalRuntime(SIGCONT)
    }

    func stop() {
        let run = syncIO { () -> Invocation? in
            guard let run = invocation, run.lease.state != .retired else { return nil }
            run.lease.revoke(); run.requestedStop = true
            beginDrain(run)
            return run
        }
        guard let run else { return }
        bridge.cancelActiveTool()
        signalRuntime(SIGCONT)
        signalRuntime(SIGTERM)
        run.process.beginTeardown()
        enforceTermination(run)
    }

    @discardableResult
    func submitUserInput(requestID: String, value: String, taskGenerationID: String,
                         instructionRevision: UInt64, workingDocumentRevision: UInt64 = 0) -> Bool {
        // The credential crosses only the existing private stdin pipe. It is
        // never placed in arguments, environment variables, status text, or
        // the OpenClaw conversation.
        let run = syncIO { () -> Invocation? in
            guard let run = invocation, run.pendingUserInputID == requestID,
                  run.pendingUserInputRevision == instructionRevision,
                  run.lease.accepts(taskGenerationID) else { return nil }
            do { try run.lease.validateInstructionRevision(instructionRevision) }
            catch { return nil }
            do { try run.lease.validateWorkingDocumentRevision(workingDocumentRevision) }
            catch { return nil }
            run.pendingUserInputID = nil
            run.pendingUserInputRevision = nil
            run.snapshots.invalidateStatus()
            return run
        }
        guard let run, run.lease.accepts(taskGenerationID) else { return false }
        send([
            "task_generation_id": run.lease.id,
            "instruction_revision": instructionRevision,
            "working_document_revision": workingDocumentRevision,
            "kind": "user_input_response",
            "request_id": requestID,
            "value": value
        ], for: run)
        return true
    }

    @discardableResult
    func submitTargetChoice(request: AgentTargetChoiceRequest, candidateID: String? = nil,
                            inspectAgain: Bool = false) -> Bool {
        let run = syncIO { () -> Invocation? in
            guard let run = invocation, run.pendingTargetChoice?.id == request.id,
                  run.lease.accepts(request.taskGenerationID),
                  request.taskGenerationID == run.lease.id,
                  request.instructionRevision == run.lease.currentInstructionRevision,
                  request.workingDocumentRevision == run.lease.currentWorkingDocumentRevision,
                  request.bindingRevision == run.lease.currentTargetBindingRevision + 1,
                  !run.lease.hasPendingInstructionCorrection,
                  !run.lease.hasPendingWorkingDocumentUpdate,
                  run.lease.state == .running || run.lease.state == .paused else { return nil }
            if inspectAgain {
                guard candidateID == nil, request.inspectAgainAllowed,
                      run.lease.cancelTargetChoice(id: request.id, revision: request.bindingRevision) else { return nil }
                rememberResolvedTargetChoice(request, for: run)
                run.pendingTargetChoice = nil
                run.targetChoiceCandidates.removeAll()
                run.pendingTargetChoiceApplying = false
            } else {
                guard !run.pendingTargetChoiceApplying,
                      let candidateID, run.targetChoiceCandidates.contains(candidateID) else { return nil }
                run.pendingTargetChoiceApplying = true
            }
            return run
        }
        guard let run else { return false }
        send(["kind": "target_choice_response", "version": AgentTargetChoiceProtocol.version,
              "task_generation_id": run.lease.id, "request_id": request.id,
              "instruction_revision": request.instructionRevision,
              "working_document_revision": request.workingDocumentRevision,
              "binding_revision": request.bindingRevision,
              "candidate_id": candidateID as Any? ?? NSNull(), "inspect_again": inspectAgain], for: run)
        return true
    }

    func prepareInstructionCorrection(_ correction: TaskInstructionCorrection, generationID: String) throws {
        let run = try syncIO { () throws -> Invocation in
            guard let run = invocation, run.lease.id == generationID,
                  run.lease.state == .running || run.lease.state == .paused else {
                throw TaskInstructionCorrectionError.stale
            }
            guard correction.revision == run.lease.currentInstructionRevision + 1,
                  !run.correctionIDs.contains(correction.id.uuidString.lowercased()) else {
                throw TaskInstructionCorrectionError.stale
            }
            try run.lease.beginInstructionCorrection(id: correction.id.uuidString, revision: correction.revision)
            run.correctionIDs.insert(correction.id.uuidString.lowercased())
            run.corrections[correction.id.uuidString.lowercased()] = correction
            return run
        }
        _ = run
    }

    func sendInstructionCorrection(_ correction: TaskInstructionCorrection, generationID: String) throws {
        let run = try syncIO { () throws -> Invocation in
            guard let run = invocation, run.lease.id == generationID,
                  run.correctionIDs.contains(correction.id.uuidString.lowercased()),
                  run.lease.state == .running || run.lease.state == .paused else {
                throw TaskInstructionCorrectionError.stale
            }
            return run
        }
        var frame = try telemetry.encodeJSON([
            "kind": "instruction_correction",
            "task_generation_id": run.lease.id,
            "instruction_revision": correction.revision,
            "correction": correction.wireValue
        ], recordSize: false)
        frame.append(0x0A)
        run.writer?.enqueue(frame, priority: true) { [weak self, weak run] delivered in
            guard let self, let run else { return }
            if !delivered {
                self.enqueueIO { self.failTransport("transport_closed", for: run) }
            }
        }
    }

    func cancelInstructionCorrection(_ correctionID: UUID, generationID: String) {
        let run = syncIO { () -> Invocation? in
            guard let run = invocation, run.lease.id == generationID else { return nil }
            run.lease.cancelInstructionCorrection(id: correctionID.uuidString)
            return run
        }
        _ = run
    }

    func prepareWorkingDocumentUpdate(_ update: WorkingDocumentUpdate, generationID: String) throws {
        try syncIO {
            guard let run = invocation, run.lease.id == generationID,
                  run.lease.state == .running || run.lease.state == .paused else {
                throw WorkingDocumentUpdateError.stale
            }
            guard update.generationID == generationID,
                  update.revision == run.lease.currentWorkingDocumentRevision + 1,
                  !run.workingDocumentIDs.contains(update.id) else {
                throw WorkingDocumentUpdateError.stale
            }
            try run.lease.beginWorkingDocumentUpdate(id: update.id, revision: update.revision)
            if let choice = run.pendingTargetChoice { rememberResolvedTargetChoice(choice, for: run) }
            run.pendingTargetChoice = nil
            run.targetChoiceCandidates.removeAll()
            run.pendingTargetChoiceApplying = false
            run.workingDocumentIDs.insert(update.id)
        }
    }

    func sendWorkingDocumentUpdate(_ update: WorkingDocumentUpdate, generationID: String) throws {
        let run = try syncIO { () throws -> Invocation in
            guard let run = invocation, run.lease.id == generationID,
                  run.workingDocumentIDs.contains(update.id),
                  run.lease.state == .running || run.lease.state == .paused else {
                throw WorkingDocumentUpdateError.stale
            }
            return run
        }
        var frame = try telemetry.encodeJSON(update.wireValue.merging(["kind": "working_document_update"]) { _, new in new }, recordSize: false)
        frame.append(0x0A)
        run.writer?.enqueue(frame, priority: true) { [weak self, weak run] delivered in
            guard let self, let run else { return }
            if !delivered { self.enqueueIO { self.failTransport("transport_closed", for: run) } }
        }
    }

    func cancelWorkingDocumentUpdate(_ updateID: String, generationID: String) {
        syncIO {
            guard let run = invocation, run.lease.id == generationID else { return }
            run.lease.cancelWorkingDocumentUpdate(id: updateID)
            run.workingDocumentIDs.remove(updateID.lowercased())
        }
    }

    private func signalRuntime(_ signal: Int32) {
        let process = syncIO { invocation?.process }
        process?.signal(signal)
    }

    private func installOutputHandler(_ handle: FileHandle, for run: Invocation) {
        handle.readabilityHandler = { [weak self] handle in
            // Admit one read at a time. Leaving the handler enabled while a
            // read is queued can enqueue another blocking read ahead of a
            // bridge response and deadlock the controller pipe.
            handle.readabilityHandler = nil
            self?.enqueueIO { [weak self] in
                guard let self, self.invocation === run, !run.exited else { return }
                let eof = self.drainAvailable(handle) { self.appendOutput($0, for: run) }
                if !eof && !run.exited { self.installOutputHandler(handle, for: run) }
            }
        }
    }

    private func installErrorHandler(_ handle: FileHandle, for run: Invocation) {
        handle.readabilityHandler = { [weak self] handle in
            handle.readabilityHandler = nil
            self?.enqueueIO { [weak self] in
                guard let self, self.invocation === run, !run.exited else { return }
                let eof = self.drainAvailable(handle) { self.appendError($0, for: run) }
                if !eof && !run.exited { self.installErrorHandler(handle, for: run) }
            }
        }
    }

    private func appendError(_ data: Data, for run: Invocation) {
        guard let text = String(data: data.suffix(4096), encoding: .utf8), let last = text.split(whereSeparator: \.isNewline).last else { return }
        run.lastErrorLine = String(last)
    }

    @discardableResult
    private func drainAvailable(_ handle: FileHandle, consume: (Data) -> Void) -> Bool {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 65536)
        // Kernel pipes are bounded; do not follow a noisy surviving descendant
        // indefinitely after the originating helper has exited.
        var remaining = RuntimeLineBuffer.maximumBatchBytes
        while remaining > 0 {
            let count = Darwin.read(fd, &buffer, min(buffer.count, remaining))
            if count == 0 { return true }
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            consume(Data(buffer.prefix(count))); remaining -= count
        }
        return false
    }

    // Also used after process exit; the final event need not end with a newline.
    private func appendOutput(_ data: Data, for run: Invocation, flush: Bool = false) {
        let lines = run.outputBuffer.append(data, flush: flush)
        if let code = run.outputBuffer.failureCode {
            failTransport(code, for: run)
            return
        }
        for line in lines { processLine(line, for: run) }
    }

    private func processLine(_ data: Data, for run: Invocation) {
        let receive = telemetry.begin(.ipcReceive, inputBytes: data.count)
        var accepted = false
        defer { receive.finish(accepted ? .succeeded : .failed) }
        let message: [String: Any]
        do {
            message = try telemetry.measure(.jsonDecoding, inputBytes: data.count) { _ in
                try RuntimeMessageJSON.decode(data)
            }
        } catch RuntimeMessageJSON.Failure.duplicateField {
            failTransport("transport_duplicate_field", for: run); return
        } catch {
            failTransport("transport_malformed_frame", for: run); return
        }
        guard let kind = message["kind"] as? String else {
            failTransport("transport_malformed_frame", for: run); return
        }

        let finalDrain = run.process.snapshot.parentExited && !run.requestedStop && !run.receivedTerminalEvent && run.pendingTerminalEvent == nil &&
            ["complete", "error"].contains(kind) && message["task_generation_id"] as? String == run.lease.id
        guard invocation === run, finalDrain || run.lease.accepts(message["task_generation_id"] as? String) else {
            if !run.requestedStop && run.lease.state != .draining && run.lease.state != .retired {
                run.pendingTerminalEvent = .failed("TaskPilot runtime task ownership does not match; rebuild the bundled components together")
                beginDrain(run)
                run.process.terminate()
            }
            return
        }
        accepted = true
        if !["runtime_ready", "instruction_correction_applied", "working_document_applied", "bridge_request"].contains(kind) {
            guard let revision = exactRevision(message["instruction_revision"]) else {
                failTransport("instruction_revision_mismatch", for: run)
                return
            }
            // Late status, progress, secure-input, or output frames from an
            // earlier instruction must never replace the current task view.
            guard revision == run.lease.currentInstructionRevision else { return }
        }
        if !["runtime_ready", "working_document_applied", "bridge_request"].contains(kind) {
            guard let revision = exactRevision(message["working_document_revision"]),
                  revision == run.lease.currentWorkingDocumentRevision else { return }
        }
        // Older helpers lack runtime_ready; their first valid non-error frame
        // is the compatibility boundary. Current helpers announce readiness.
        if ["runtime_ready", "model_health", "request_metrics", "bridge_request", "status",
            "output", "user_input_required", "complete", "error"].contains(kind) {
            run.startupSpan?.finish(kind == "error" ? .failed : .succeeded)
            run.startupSpan = nil
        }
        switch kind {
        case "runtime_ready":
            // Negotiate this private control independently of older helpers.
            if let version = message["memory_pressure_version"] as? NSNumber,
               CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
               version.doubleValue == 1 { run.supportsMemoryPressure = true }
        case "model_health":
            emit(.modelHealth(message["model"] as? String ?? "", message["state"] as? String ?? "repair", message["detail"] as? String ?? ""), for: run, serializedByteCount: data.count)
        case "request_metrics":
            if let metrics = try? BackendTelemetry.DiagnosticSchema.decodeRequestMetrics(data, using: run.metricsDecoder) {
                emit(.diagnostics(metrics), for: run, serializedByteCount: data.count)
            }
        case "bridge_request":
            guard let method = message["method"] as? String,
                  let instructionRevision = exactRevision(message["instruction_revision"]),
                  let workingDocumentRevision = exactRevision(message["working_document_revision"]) else {
                failTransport("working_document_revision_mismatch", for: run); return
            }
            do {
                try run.lease.validateInstructionRevision(instructionRevision, allowDispatchedReceipt: method == "act")
                if method == "bind_working_document" {
                    let params = message["params"] as? [String: Any] ?? [:]
                    guard let id = params["update_id"] as? String,
                          let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id,
                          run.workingDocumentIDs.contains(id),
                          exactRevision(params["binding_revision"]) == workingDocumentRevision,
                          workingDocumentRevision == run.lease.currentWorkingDocumentRevision + 1 ||
                            run.lease.appliedWorkingDocumentRevision(id: id) == workingDocumentRevision else {
                        throw WorkingDocumentUpdateError.stale
                    }
                    try run.lease.validateWorkingDocumentRevision(workingDocumentRevision, allowPendingUpdate: true)
                } else {
                    try run.lease.validateWorkingDocumentRevision(workingDocumentRevision, allowDispatchedReceipt: method == "act")
                }
            } catch {
                failTransport(error is WorkingDocumentUpdateError ? "working_document_revision_mismatch" : "instruction_revision_mismatch", for: run)
                return
            }
            let requestBytes = data.count
            let receiptLookup = method == "action_receipt"
            let allowance = (receiptLookup ? 32 : 24) * 1024 * 1024
            guard run.operations.count < (receiptLookup ? 32 : 31) else { failTransport("transport_request_limit", for: run); return }
            guard run.pendingBridgeBytes + requestBytes <= allowance else { failTransport("transport_buffer_limit", for: run); return }
            if message["method"] as? String == "act",
               let params = message["params"] as? [String: Any], let id = params["action_id"] as? String {
                guard run.receiptIDs.count < 1024 || run.receiptIDs.contains(id) else {
                    failTransport("transport_request_limit", for: run); return
                }
                run.receiptIDs.insert(id)
            }
            let bridgeSpan = telemetry.begin(.ipcBridge, inputBytes: data.count)
            let bridgeWait = telemetry.beginQueueWait(method == "observe" ? .observationTask : .bridgeTask)
            let operationID = UUID()
            run.pendingBridgeBytes += requestBytes
            let operation = Task { [weak self] in
                guard let self else { bridgeWait.discard(.abandoned); bridgeSpan.finish(.cancelled); return }
                bridgeWait.start()
                var response = await BackendTelemetry.$current.withValue(self.telemetry) {
                    await TaskOwnership.$current.withValue(run.lease) {
                        await TaskOwnership.$instructionRevision.withValue(instructionRevision) {
                            await TaskOwnership.$workingDocumentRevision.withValue(workingDocumentRevision) {
                                if let handler = self.bridgeHandler {
                                    return await TaskOwnership.withCancellationWakeup { await handler(message) }
                                }
                                return await self.bridge.handle(message)
                            }
                        }
                    }
                }
                let changeLensCandidate = response.removeValue(forKey: "change_lens_candidate") as? [String: Any]
                response["instruction_revision"] = message["instruction_revision"]
                response["working_document_revision"] = message["working_document_revision"]
                self.enqueueIO {
                    if let changeLensCandidate,
                       let snapshot = AgentTaskChangeLensSnapshot.validatedCandidate(
                        changeLensCandidate, response: response, request: message, generationID: run.lease.id,
                        instructionRevision: instructionRevision, knownActionIDs: run.receiptIDs
                       ) {
                        self.emit(.taskChangeLens(snapshot), for: run)
                    }
                    self.send(response, for: run, bridgeSpan: bridgeSpan)
                    run.operations.removeValue(forKey: operationID)
                    run.pendingBridgeBytes -= requestBytes
                }
            }
            run.operations[operationID] = operation
        case "status":
            if let text = message["message"] as? String { emit(.status(text), for: run, serializedByteCount: data.count) }
        case "output":
            let output = AgentTaskOutput(
                shouldShow: message["show_output"] as? Bool ?? false,
                title: message["title"] as? String ?? "Output",
                content: message["content"] as? String ?? "",
                decidedByAgent: message["decided_by_agent"] as? Bool ?? false,
                kind: AgentTaskOutputKind(rawValue: message["output_kind"] as? String ?? "result") ?? .result
            )
            emit(.output(output), for: run, serializedByteCount: data.count)
        case "user_input_required":
            guard let requestID = message["request_id"] as? String,
                  let revision = exactRevision(message["instruction_revision"]) else { return }
            do { try run.lease.validateInstructionRevision(revision) }
            catch { return }
            run.pendingUserInputID = requestID
            run.pendingUserInputRevision = revision
            let request = AgentUserInputRequest(
                requestID: requestID,
                taskGenerationID: run.lease.id,
                instructionRevision: revision,
                workingDocumentRevision: exactRevision(message["working_document_revision"]) ?? 0,
                title: message["title"] as? String ?? "Password required",
                message: message["message"] as? String ?? "Enter the requested credential to continue.",
                kind: AgentUserInputKind(
                    rawValue: message["input_kind"] as? String ?? "password"
                ) ?? .password
            )
            emit(.userInputRequired(request), for: run, serializedByteCount: data.count)
        case "target_choice_required":
            let requiredKeys: Set<String> = ["kind", "task_generation_id", "instruction_revision",
                "working_document_revision", "version", "request_id", "binding_revision",
                "reference", "requirement_id", "scope", "candidates", "inspect_again_allowed"]
            guard Set(message.keys) == requiredKeys,
                  exactRevision(message["version"]) == UInt64(AgentTargetChoiceProtocol.version),
                  let requestID = message["request_id"] as? String,
                  let requestUUID = UUID(uuidString: requestID), requestUUID.uuidString.lowercased() == requestID,
                  let instructionRevision = exactRevision(message["instruction_revision"]),
                  let documentRevision = exactRevision(message["working_document_revision"]),
                  let bindingRevision = exactRevision(message["binding_revision"]) else {
                failTransport("transport_malformed_frame", for: run); return
            }
            guard message["task_generation_id"] as? String == run.lease.id else { return }
            if run.resolvedTargetChoiceIDs[requestID] == bindingRevision { return }
            if let pending = run.pendingTargetChoice, pending.id == requestID {
                let duplicate = AgentTargetChoiceRequest.parse(message, generationID: run.lease.id,
                    instructionRevision: pending.instructionRevision,
                    workingDocumentRevision: pending.workingDocumentRevision,
                    targetBindingRevision: pending.bindingRevision - 1)
                guard duplicate == pending else { failTransport("target_choice_revision_mismatch", for: run); return }
                return
            }
            // Late frames from a superseded instruction, document or binding
            // are discarded without disturbing the current task.
            if instructionRevision < run.lease.currentInstructionRevision ||
                documentRevision < run.lease.currentWorkingDocumentRevision ||
                bindingRevision <= run.lease.currentTargetBindingRevision { return }
            guard let request = AgentTargetChoiceRequest.parse(
                message, generationID: run.lease.id,
                instructionRevision: run.lease.currentInstructionRevision,
                workingDocumentRevision: run.lease.currentWorkingDocumentRevision,
                targetBindingRevision: run.lease.currentTargetBindingRevision) else {
                failTransport("transport_malformed_frame", for: run); return
            }
            guard run.pendingTargetChoice == nil else {
                failTransport("target_choice_revision_mismatch", for: run); return
            }
            do {
                try run.lease.beginTargetChoice(id: request.id, instructionRevision: request.instructionRevision,
                                                workingDocumentRevision: request.workingDocumentRevision,
                                                revision: request.bindingRevision,
                                                candidateIDs: Set(request.candidates.map(\.id)),
                                                reference: request.reference, requirementID: request.requirementID,
                                                scope: request.scope)
            } catch {
                failTransport("target_choice_revision_mismatch", for: run); return
            }
            run.pendingTargetChoice = request
            run.targetChoiceCandidates = Set(request.candidates.map(\.id))
            run.pendingTargetChoiceApplying = false
            emit(.targetChoiceRequired(request), for: run)
        case "target_choice_applied":
            guard message["task_generation_id"] as? String == run.lease.id,
                  let requestID = message["request_id"] as? String,
                  let request = run.pendingTargetChoice, request.id == requestID else { return }
            // A document selection advances the working-document revision as
            // part of the native commit. Compare against that expected next
            // revision before treating an acknowledgement as stale.
            guard let candidateID = message["candidate_id"] as? String,
                  let selectedCandidate = request.candidates.first(where: { $0.id == candidateID }),
                  exactRevision(message["instruction_revision"]) == request.instructionRevision,
                  exactRevision(message["binding_revision"]) == request.bindingRevision,
                  let reportedDocumentRevision = exactRevision(message["working_document_revision"]) else {
                failTransport("transport_malformed_frame", for: run); return
            }
            let isDocumentChoice = selectedCandidate.kind == .document
            let expectedDocumentRevision = request.workingDocumentRevision + (isDocumentChoice ? 1 : 0)
            var expectedKeys: Set<String> = ["kind", "task_generation_id", "instruction_revision",
                "working_document_revision", "version", "request_id", "candidate_id",
                "binding_revision", "label", "detail"]
            if isDocumentChoice { expectedKeys.insert("working_document") }
            guard Set(message.keys) == expectedKeys,
                  exactRevision(message["version"]) == UInt64(AgentTargetChoiceProtocol.version),
                  message["label"] as? String == selectedCandidate.label,
                  message["detail"] as? String == selectedCandidate.detail,
                  reportedDocumentRevision == expectedDocumentRevision else {
                failTransport("transport_malformed_frame", for: run); return
            }
            if request.instructionRevision != run.lease.currentInstructionRevision ||
                expectedDocumentRevision != run.lease.currentWorkingDocumentRevision ||
                request.bindingRevision != run.lease.currentTargetBindingRevision {
                if !run.lease.hasPendingTargetChoice {
                    rememberResolvedTargetChoice(request, for: run)
                    run.pendingTargetChoice = nil
                    run.targetChoiceCandidates.removeAll()
                    run.pendingTargetChoiceApplying = false
                }
                return
            }
            guard Set(message.keys) == expectedKeys,
                  run.pendingTargetChoiceApplying,
                  run.targetChoiceCandidates.contains(candidateID),
                  let revision = exactRevision(message["binding_revision"]), revision == request.bindingRevision,
                  run.lease.appliedTargetChoiceRevision(id: requestID) == revision,
                  let workingDocumentRevision = exactRevision(message["working_document_revision"]),
                  workingDocumentRevision == run.lease.currentWorkingDocumentRevision else {
                failTransport("transport_malformed_frame", for: run); return
            }
            let workingDocument = message["working_document"] as? [String: Any]
            if selectedCandidate.kind == .document {
                guard workingDocumentRevision == request.workingDocumentRevision + 1,
                      workingDocument?["state"] as? String == "active",
                      exactRevision(workingDocument?["revision"]) == workingDocumentRevision,
                      workingDocument?["application"] as? String != nil,
                      workingDocument?["title"] as? String != nil else { return }
            } else {
                guard workingDocumentRevision == request.workingDocumentRevision,
                      workingDocument == nil else { return }
            }
            run.pendingTargetChoice = nil
            run.targetChoiceCandidates.removeAll()
            run.pendingTargetChoiceApplying = false
            rememberResolvedTargetChoice(request, for: run)
            emit(.targetChoiceApplied(requestID: requestID, candidateID: candidateID,
                label: selectedCandidate.label, detail: selectedCandidate.detail,
                taskGenerationID: run.lease.id, bindingRevision: revision,
                workingDocumentRevision: workingDocumentRevision, workingDocument: workingDocument), for: run)
        case "target_choice_rejected":
            guard message["task_generation_id"] as? String == run.lease.id,
                  let requestID = message["request_id"] as? String,
                  let request = run.pendingTargetChoice, request.id == requestID else { return }
            if request.instructionRevision != run.lease.currentInstructionRevision ||
                request.workingDocumentRevision != run.lease.currentWorkingDocumentRevision {
                rememberResolvedTargetChoice(request, for: run)
                run.pendingTargetChoice = nil
                run.targetChoiceCandidates.removeAll()
                run.pendingTargetChoiceApplying = false
                return
            }
            guard Set(message.keys) == Set(["kind", "task_generation_id", "instruction_revision",
                    "working_document_revision", "version", "request_id", "binding_revision", "message"]),
                  exactRevision(message["version"]) == UInt64(AgentTargetChoiceProtocol.version),
                  exactRevision(message["instruction_revision"]) == request.instructionRevision,
                  exactRevision(message["working_document_revision"]) == request.workingDocumentRevision,
                  let revision = exactRevision(message["binding_revision"]), revision == request.bindingRevision,
                  let rejection = message["message"] as? String, rejection.utf8.count <= 240,
                  run.lease.cancelTargetChoice(id: requestID, revision: revision) else {
                failTransport("transport_malformed_frame", for: run); return
            }
            run.pendingTargetChoice = nil
            run.targetChoiceCandidates.removeAll()
            run.pendingTargetChoiceApplying = false
            rememberResolvedTargetChoice(request, for: run)
            emit(.targetChoiceRejected(requestID: requestID, taskGenerationID: run.lease.id,
                bindingRevision: revision, instructionRevision: request.instructionRevision,
                workingDocumentRevision: request.workingDocumentRevision,
                message: String(rejection.prefix(240))), for: run)
        case "task_progress":
            guard let progress = AgentTaskProgressSnapshot.parse(message, generationID: run.lease.id),
                  progress.revision > run.progressRevision else { return }
            run.progressRevision = progress.revision
            emit(.taskProgress(progress), for: run, serializedByteCount: data.count)
        case "task_input_roles":
            guard let roles = AgentTaskInputRolesSnapshot.parse(message, generationID: run.lease.id,
                  instructionRevision: run.lease.currentInstructionRevision,
                  exactReferences: run.exactInputReferences),
                  roles.revision > run.inputRolesRevision else { return }
            run.inputRolesRevision = roles.revision
            emit(.taskInputRoles(roles), for: run, serializedByteCount: data.count)
        case "task_continuation_checkpoint":
            guard let checkpoint = AgentTaskContinuationCheckpoint.parse(message, generationID: run.lease.id),
                  checkpoint.instructionRevision == run.lease.currentInstructionRevision,
                  checkpoint.revision > run.continuationRevision else { return }
            run.continuationRevision = checkpoint.revision
            emit(.taskContinuationCheckpoint(checkpoint), for: run, serializedByteCount: data.count)
        case "task_wait":
            guard let wait = AgentTaskWaitSnapshot.parse(message, generationID: run.lease.id),
                  wait.revision > run.waitRevision else { return }
            run.waitRevision = wait.revision
            emit(.taskWait(wait), for: run, serializedByteCount: data.count)
        case "task_destination":
            guard let destination = AgentTaskDestinationSnapshot.parse(message, generationID: run.lease.id),
                  destination.instructionRevision == run.lease.currentInstructionRevision,
                  destination.revision > run.destinationRevision else { return }
            run.destinationRevision = destination.revision
            emit(.taskDestination(destination), for: run, serializedByteCount: data.count)
        case "instruction_correction_applied":
            guard message["task_generation_id"] as? String == run.lease.id,
                  let id = message["correction_id"] as? String,
                  let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id,
                  let revision = exactRevision(message["instruction_revision"]) else { return }
            do {
                guard let correction = run.corrections[id] else { throw TaskInstructionCorrectionError.stale }
                try run.lease.applyInstructionCorrection(id: id, revision: revision, correction: correction)
                var updatedReferences = run.exactInputReferences
                if let amendment = correction.roleAmendment {
                    guard let index = updatedReferences.firstIndex(where: { $0.id == amendment.occurrenceID &&
                        $0.kind == amendment.kind && $0.utf8Start == amendment.utf8Start &&
                        $0.utf8Length == amendment.utf8Length && $0.value == amendment.value }) else {
                        throw TaskInstructionCorrectionError.stale
                    }
                    let reference = updatedReferences[index]
                    updatedReferences[index] = AgentTaskInputReference(kind: reference.kind,
                        utf8Start: reference.utf8Start, utf8Length: reference.utf8Length,
                        value: reference.value, userRole: amendment.role)
                }
                var updatedRequest = run.taskRequest
                if !correction.request.isEmpty || !correction.exactInputReferences.isEmpty {
                    let correctionHeader = "\n\nUser correction: "
                    let correctionStart = run.taskRequest.utf8.count + correctionHeader.utf8.count
                    updatedReferences.append(contentsOf: correction.exactInputReferences.map {
                        AgentTaskInputReference(version: $0.version, kind: $0.kind,
                            utf8Start: correctionStart + $0.utf8Start, utf8Length: $0.utf8Length,
                            value: $0.value, userRole: $0.userRole)
                    })
                    updatedRequest += correctionHeader + correction.request
                }
                try AgentTaskSubmission(request: updatedRequest, exactInputReferences: updatedReferences)
                    .validateExactInputReferences()
                run.taskRequest = updatedRequest
                run.exactInputReferences = updatedReferences
                if let choice = run.pendingTargetChoice { rememberResolvedTargetChoice(choice, for: run) }
                run.pendingTargetChoice = nil
                run.targetChoiceCandidates.removeAll()
                run.pendingTargetChoiceApplying = false
                if run.pendingUserInputRevision != revision {
                    run.pendingUserInputID = nil
                    run.pendingUserInputRevision = nil
                }
                emit(.instructionCorrectionApplied(id: id, taskGenerationID: run.lease.id, revision: revision), for: run)
            } catch {
                failTransport("instruction_revision_mismatch", for: run)
            }
        case "working_document_applied":
            guard message["task_generation_id"] as? String == run.lease.id,
                  let id = message["update_id"] as? String,
                  let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id,
                  run.workingDocumentIDs.contains(id),
                  let revision = exactRevision(message["binding_revision"]),
                  revision == run.lease.currentWorkingDocumentRevision,
                  run.lease.appliedWorkingDocumentRevision(id: id) == revision else { return }
            let rawDocument = message["working_document"]
            let document = rawDocument as? [String: Any]
            if let document {
                guard document["state"] as? String == "active",
                      document["revision"] as? Int == Int(revision),
                      let application = document["application"] as? String,
                      let title = document["title"] as? String,
                      Set(document.keys).isSubset(of: ["state", "application", "title", "location", "revision", "selection_state", "selection_description"]),
                      (document["selection_state"] == nil || ["active", "needs_reselection"].contains(document["selection_state"] as? String ?? "")),
                      (document["selection_description"] == nil || document["selection_description"] is String) else { return }
                _ = application; _ = title
            } else if !(rawDocument is NSNull) { return }
            run.workingDocumentIDs.remove(id)
            emit(.workingDocumentApplied(id: id, taskGenerationID: run.lease.id,
                                         revision: revision, document: document), for: run)
        case "working_document_needs_reselection":
            guard message["task_generation_id"] as? String == run.lease.id,
                  exactRevision(message["binding_revision"]) == run.lease.currentWorkingDocumentRevision,
                  exactRevision(message["working_document_revision"]) == run.lease.currentWorkingDocumentRevision,
                  let application = message["application"] as? String,
                  let title = message["title"] as? String,
                  let selection = message["selection"] as? Bool else { return }
            emit(.workingDocumentNeedsReselection(taskGenerationID: run.lease.id,
                revision: run.lease.currentWorkingDocumentRevision,
                application: String(application.prefix(120)), title: String(title.prefix(240)), selection: selection), for: run)
        case "working_document_update_rejected":
            guard message["task_generation_id"] as? String == run.lease.id,
                  let id = message["update_id"] as? String,
                  run.workingDocumentIDs.contains(id),
                  let revision = exactRevision(message["binding_revision"]),
                  revision == run.lease.currentWorkingDocumentRevision + 1,
                  !run.lease.hasPendingWorkingDocumentUpdate else { return }
            run.workingDocumentIDs.remove(id)
            emit(.workingDocumentUpdateRejected(id: id, taskGenerationID: run.lease.id,
                revision: revision, message: String((message["message"] as? String ?? "Choose the working document again.").prefix(240))), for: run)
        case "action_presentation":
            guard let presentation = AgentActionPresentationMessage.parse(
                message, generationID: run.lease.id, knownActionIDs: run.receiptIDs
            ) else {
                failTransport("transport_malformed_frame", for: run)
                return
            }
            emit(.actionPresentation(actionID: presentation.actionID,
                                     taskGenerationID: presentation.generationID,
                                     verificationScope: presentation.verificationScope), for: run)
        case "complete":
            guard run.lease.claimCompletion(instructionRevision: exactRevision(message["instruction_revision"]) ?? 0) else {
                // Python always acquires this gate before publishing output.
                // A correction that won the shared lease lock keeps the task alive.
                failTransport("completion_gate_missing", for: run)
                return
            }
            if message["show_output"] as? Bool == true {
                let output = AgentTaskOutput(
                    shouldShow: true,
                    title: message["title"] as? String ?? "Output",
                    content: message["content"] as? String ?? message["message"] as? String ?? "",
                    decidedByAgent: message["decided_by_agent"] as? Bool ?? false,
                    kind: AgentTaskOutputKind(rawValue: message["output_kind"] as? String ?? "result") ?? .result
                )
                emit(.output(output), for: run, serializedByteCount: data.count)
            }
            run.receivedTerminalEvent = true
            run.pendingTerminalEvent = .completed(message["message"] as? String ?? "Task complete")
            beginDrain(run)
            enforceTermination(run, after: 5)
        case "error":
            run.receivedTerminalEvent = true
            run.pendingTerminalEvent = .failed(message["message"] as? String ?? "The task failed")
            beginDrain(run)
            enforceTermination(run, after: 5)
        default:
            break
        }
    }

    private func exactRevision(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return UInt64(number.stringValue)
    }

    /// Remember a bounded set of completed choice request IDs so duplicate
    /// required/acknowledgement frames cannot reopen or overwrite a binding.
    /// Call only on the invocation's serial I/O queue.
    private func rememberResolvedTargetChoice(_ request: AgentTargetChoiceRequest, for run: Invocation) {
        if run.resolvedTargetChoiceIDs[request.id] == nil {
            run.resolvedTargetChoiceOrder.append(request.id)
        }
        run.resolvedTargetChoiceIDs[request.id] = request.bindingRevision
        while run.resolvedTargetChoiceOrder.count > 64 {
            let oldest = run.resolvedTargetChoiceOrder.removeFirst()
            run.resolvedTargetChoiceIDs.removeValue(forKey: oldest)
        }
    }

    private func send(_ object: [String: Any], for run: Invocation, bridgeSpan: BackendTelemetry.Span? = nil) {
        let budget = LocalOperationBudget.current
        enqueueIO { [weak self] in
            guard let self, self.invocation === run, run.lease.accepts(object["task_generation_id"] as? String) else {
                bridgeSpan?.finish(.cancelled); return
            }
            // Reject before JSON serialization allocates a potentially large
            // frame. Already-dispatched bridge results retain their existing
            // receipt/reconciliation path; a deadline is never effect evidence.
            do { try budget?.check(phase: "pipe_queue") }
            catch {
                bridgeSpan?.finish(.cancelled)
                self.failTransport("transport_local_deadline", for: run); return
            }
            let recordSize = object["kind"] as? String != "user_input_response"
            guard var data = try? self.telemetry.encodeJSON(object, recordSize: recordSize) else { bridgeSpan?.finish(.failed); return }
            data.append(0x0A)
            let span = self.telemetry.begin(.ipcSend, inputBytes: recordSize ? data.count : nil)
            let count = data.count
            let priority = ["bridge_response", "user_input_response"].contains(object["kind"] as? String ?? "")
            run.writer?.enqueue(data, priority: priority, budget: budget) { delivered in
                if recordSize && delivered { span.record(outputBytes: count) }
                span.finish(delivered ? .succeeded : .failed)
                if delivered { bridgeSpan?.record(outputBytes: count) }
                bridgeSpan?.finish(delivered ? .succeeded : .failed)
            }
        }
    }

    private func failTransport(_ code: String, for run: Invocation) {
        guard invocation === run, run.transportFailure == nil, !run.requestedStop, !run.receivedTerminalEvent else { return }
        run.transportFailure = code
        run.pendingTerminalEvent = .failed("TaskPilot transport failure (\(code)). Pending actions are being reconciled and will not be repeated.")
        beginDrain(run)
        run.process.beginTeardown()
        enforceTermination(run)
    }

    private func enforceTermination(_ run: Invocation, after delay: TimeInterval = 2) {
        ioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.invocation === run, !run.process.snapshot.treeFinished else { return }
            run.process.beginTeardown()
            run.process.signal(SIGKILL)
        }
    }

    private func beginDrain(_ run: Invocation) {
        guard run.drainStarted == nil else { return }
        run.startupSpan?.finish(run.requestedStop ? .cancelled : .failed)
        run.startupSpan = nil
        run.drainStarted = .now
        run.lease.revoke()
        run.writer?.cancel()
        for operation in run.operations.values { operation.cancel() }
        bridge.cancelActiveTool()
        enforceTermination(run, after: run.receivedTerminalEvent ? 5 : 2)
        pollDrain(run)
    }

    private func pollDrain(_ run: Invocation) {
        guard invocation === run, !run.terminalDelivered else { return }
        let servicesDrained = run.lease.drainPersistentProcesses()
        if run.exited && run.operations.isEmpty && servicesDrained {
            if let code = run.transportFailure {
                // Receipt inspection happens after owned execution has drained.
                // A dispatched/uncertain GUI effect never authorizes a replay
                // or task completion, even when its response could not be sent.
                let uncertain = run.receiptIDs.contains { id in
                    let receipt = run.lease.actionReceipts.lookup(id)
                    return ["unknown", "pending", "dispatched", "unconfirmed"].contains(receipt["state"] as? String ?? "unknown")
                }
                run.pendingTerminalEvent = .failed("TaskPilot transport failure (\(code)). " +
                    (uncertain ? "An action’s effect could not be confirmed; it was not repeated." : "Action receipts were checked; no action was repeated."))
            }
            run.terminalDelivered = true
            emit(run.requestedStop ? .stopped : (run.pendingTerminalEvent ?? .failed("Runtime ended without a result")), for: run, terminal: true, retireAfterDelivery: true)
            return
        }
        if !run.drainReported, ContinuousClock.now >= (run.drainStarted ?? .now).advanced(by: .seconds(drainReportingDelay)) {
            run.drainReported = true
            emit(.status("Waiting for the previous task’s native work to finish safely…"), for: run, terminal: true)
        }
        ioQueue.asyncAfter(deadline: .now() + 0.025) { [weak self] in self?.pollDrain(run) }
    }

    private func emit(_ event: RuntimeEvent, for run: Invocation, serializedByteCount: Int? = nil, terminal: Bool = false, retireAfterDelivery: Bool = false) {
        // Suppress redundant snapshots before they allocate main-queue work.
        // Invocation ownership and terminal delivery guards remain unchanged.
        guard terminal || run.snapshots.shouldSchedule(event) else { return }
        let bytes: Int
        switch event {
        case .status(let text), .completed(let text), .failed(let text): bytes = text.utf8.count
        case .output(let output): bytes = output.content.utf8.count + output.title.utf8.count
        case .modelHealth(let model, let state, let detail): bytes = model.utf8.count + state.utf8.count + detail.utf8.count
        case .userInputRequired(let request): bytes = request.title.utf8.count + request.message.utf8.count
        case .taskProgress(let progress): bytes = progress.estimatedByteCount
        case .taskInputRoles(let roles): bytes = roles.estimatedByteCount
        case .taskContinuationCheckpoint(let checkpoint): bytes = checkpoint.estimatedByteCount
        case .taskWait(let wait):
            bytes = wait.lastConfirmed.utf8.count + wait.waitingFor.utf8.count + 256
        case .taskChangeLens(let snapshot): bytes = snapshot.estimatedByteCount + 512
        default: bytes = 1024
        }
        guard terminal || (run.queuedEventCount < 4096 && run.queuedEventBytes + bytes <= 8 * 1024 * 1024) else {
            // Progress is a replaceable presentation projection. Dropping it
            // under pressure must never turn into a task transport failure.
            if case .taskProgress = event { return }
            if case .taskInputRoles = event { return }
            if case .taskWait = event { return }
            failTransport("transport_event_limit", for: run); return
        }
        #if DEBUG
        // Exact incoming JSON bytes (excluding LF), not a heap-size measurement.
        // Sampling cannot change the estimate or the admission decision above.
        run.snapshots.auditSerializedSize(estimatedBytes: bytes, serializedBytes: serializedByteCount, telemetry: telemetry)
        #endif
        run.queuedEventCount += 1; run.queuedEventBytes += bytes
        let deliveryWait = telemetry.beginQueueWait(.eventDelivery)
        let snapshotMemory = run.snapshots.beginInFlightSnapshot(byteCount: bytes, telemetry: telemetry)
        DispatchQueue.main.async { [weak self] in
            defer { snapshotMemory.finish() }
            deliveryWait.start()
            guard let self else { return }
            let delivery = self.syncIO {
                run.queuedEventCount -= 1; run.queuedEventBytes -= bytes
                let checkpointDuringDrain: Bool
                if case .taskContinuationCheckpoint = event { checkpointDuringDrain = true }
                else { checkpointDuringDrain = false }
                return (self.invocation === run && (terminal || checkpointDuringDrain || !run.requestedStop), retireAfterDelivery && run.requestedStop)
            }
            guard delivery.0 else { return }
            run.handler?(delivery.1 ? .stopped : event)
            if retireAfterDelivery { run.lease.retire() }
        }
    }
}
