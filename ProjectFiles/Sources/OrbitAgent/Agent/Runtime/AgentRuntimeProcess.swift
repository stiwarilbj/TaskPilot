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
    let title: String
    let message: String
    let kind: AgentUserInputKind

    var id: String { requestID }
}

enum RuntimeEvent {
    case status(String)
    case modelHealth(String, String, String)
    case diagnostics(AgentRequestMetrics)
    case output(AgentTaskOutput)
    case userInputRequired(AgentUserInputRequest)
    case completed(String)
    case failed(String)
    case stopped
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
    private final class Invocation {
        let lease: TaskLease
        let process: Process
        let input: Pipe
        let handler: (@MainActor (RuntimeEvent) -> Void)?
        var outputBuffer = Data()
        var lastErrorLine = ""
        var requestedStop = false
        var receivedTerminalEvent = false
        var pendingTerminalEvent: RuntimeEvent?
        var operations: [UUID: Task<Void, Never>] = [:]
        var exited = false
        var pendingUserInputID: String?
        var terminalDelivered = false
        var drainStarted: ContinuousClock.Instant?
        var drainReported = false
        init(lease: TaskLease, process: Process, input: Pipe, handler: (@MainActor (RuntimeEvent) -> Void)?) {
            self.lease = lease; self.process = process; self.input = input; self.handler = handler
        }
    }
    private var invocation: Invocation?

    init(bridge: AgentAutomationBridge, drainReportingDelay: TimeInterval = 5, bridgeHandler: (([String: Any]) async -> [String: Any])? = nil) {
        self.bridge = bridge
        self.bridgeHandler = bridgeHandler
        self.drainReportingDelay = drainReportingDelay
    }

    func start(
        task: String,
        display: DisplayDescriptor,
        runtimeURL: URL,
        openClawURL: URL,
        geminiAPIKey: String,
        lease: TaskLease = TaskLease()
    ) throws {
        guard ioQueue.sync(execute: { invocation == nil || invocation?.lease.state == .retired }) else { throw RuntimeProcessError.alreadyRunning }
        guard FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
            throw RuntimeProcessError.runtimeMissing
        }

        try bridge.bind(lease)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
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
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        let run = Invocation(lease: lease, process: process, input: input, handler: onEvent)
        ioQueue.sync { invocation = run }
        installOutputHandler(output.fileHandleForReading, for: run)
        installErrorHandler(error.fileHandleForReading, for: run)

        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.ioQueue.async {
                terminated.terminationHandler = nil
                guard self.invocation === run, run.process === terminated else { return }
                output.fileHandleForReading.readabilityHandler = nil
                error.fileHandleForReading.readabilityHandler = nil
                self.appendOutput(output.fileHandleForReading.readDataToEndOfFile(), for: run, flush: true)
                self.appendError(error.fileHandleForReading.readDataToEndOfFile(), for: run)
                run.exited = true
                if !run.requestedStop && run.pendingTerminalEvent == nil {
                    run.pendingTerminalEvent = .failed(run.lastErrorLine.isEmpty ? "The OpenClaw bridge exited unexpectedly" : run.lastErrorLine)
                }
                self.beginDrain(run)
            }
        }

        var launched = false
        do {
            try lease.commit { try process.run() }
            launched = true
            // Pass the secret through the already-private controller pipe,
            // never through arguments, environment variables, or logs. The
            // runtime consumes this first line before it begins bridge calls.
            var configuration = try JSONSerialization.data(withJSONObject: [
                "kind": "runtime_configuration",
                "gemini_api_key": geminiAPIKey,
                "action_contract_hash": ActionContract.fingerprint,
                "action_contract_version": ActionContract.version,
                "task_generation_id": lease.id,
                "task_protocol_version": ActionContract.taskProtocolVersion,
                "coordinate_mapping_version": ScreenCoordinateMapping.version,
                "observation_completeness_version": ObservationCollection<Int>.version,
                "text_recognition_version": LocalTextRecognition.version,
                "evidence_consistency_version": ControlEvidencePolicy.version,
                "command_capability_version": CommandCapabilities.version
            ])
            configuration.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: configuration)
        } catch let launchError {
            if launched {
                // A successfully spawned helper must drain like every other
                // invocation, even if writing its startup configuration fails.
                ioQueue.async {
                    run.pendingTerminalEvent = .failed("Could not start the agent: \(launchError.localizedDescription)")
                    self.beginDrain(run)
                    if process.isRunning { process.terminate() }
                }
                return
            }
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            lease.revoke()
            ioQueue.sync { run.exited = true; run.pendingTerminalEvent = nil; run.lease.retire() }
            throw launchError
        }
    }

    func pause() {
        ioQueue.sync { invocation?.lease.pause() }
        bridge.pauseActiveTool()
        signalRuntime(SIGSTOP)
    }

    func resume() {
        ioQueue.sync { invocation?.lease.resume() }
        bridge.resumeActiveTool()
        signalRuntime(SIGCONT)
    }

    func stop() {
        let run = ioQueue.sync { () -> Invocation? in
            guard let run = invocation, run.lease.state != .retired else { return nil }
            run.lease.revoke(); run.requestedStop = true
            beginDrain(run)
            return run
        }
        guard let run else { return }
        bridge.cancelActiveTool()
        signalRuntime(SIGCONT)
        signalRuntime(SIGTERM)
        if run.process.isRunning { run.process.terminate() }
    }

    func submitUserInput(requestID: String, value: String, taskGenerationID: String) {
        // The credential crosses only the existing private stdin pipe. It is
        // never placed in arguments, environment variables, status text, or
        // the OpenClaw conversation.
        let run = ioQueue.sync { () -> Invocation? in
            guard let run = invocation, run.pendingUserInputID == requestID, run.lease.accepts(taskGenerationID) else { return nil }
            run.pendingUserInputID = nil
            return run
        }
        guard let run, run.lease.accepts(taskGenerationID) else { return }
        send([
            "task_generation_id": run.lease.id,
            "kind": "user_input_response",
            "request_id": requestID,
            "value": value
        ], for: run)
    }

    private func signalRuntime(_ signal: Int32) {
        guard let pid = ioQueue.sync(execute: { invocation?.process.processIdentifier }) else { return }
        // The packaged Python helper makes itself a process-group leader, so
        // pause/stop applies to its OpenClaw ACP child as well. Fall back to the
        // helper pid during the brief startup window before setpgrp completes.
        if kill(-pid, signal) != 0 {
            kill(pid, signal)
        }
    }

    private func installOutputHandler(_ handle: FileHandle, for run: Invocation) {
        handle.readabilityHandler = { [weak self] handle in
            // Admit one read at a time. Leaving the handler enabled while a
            // read is queued can enqueue another blocking read ahead of a
            // bridge response and deadlock the controller pipe.
            handle.readabilityHandler = nil
            self?.ioQueue.async { [weak self] in
                guard let self, self.invocation === run else { return }
                self.appendOutput(handle.availableData, for: run)
                if run.process.isRunning { self.installOutputHandler(handle, for: run) }
            }
        }
    }

    private func installErrorHandler(_ handle: FileHandle, for run: Invocation) {
        handle.readabilityHandler = { [weak self] handle in
            handle.readabilityHandler = nil
            self?.ioQueue.async { [weak self] in
                guard let self, self.invocation === run else { return }
                self.appendError(handle.availableData, for: run)
                if run.process.isRunning { self.installErrorHandler(handle, for: run) }
            }
        }
    }

    private func appendError(_ data: Data, for run: Invocation) {
        guard let text = String(data: data, encoding: .utf8), let last = text.split(whereSeparator: \.isNewline).last else { return }
        run.lastErrorLine = String(last)
    }

    // Also used after process exit; the final event need not end with a newline.
    private func appendOutput(_ data: Data, for run: Invocation, flush: Bool = false) {
        run.outputBuffer.append(data)
        let lines = Self.extractOutputLines(from: &run.outputBuffer, flush: flush)
        for line in lines { processLine(line, for: run) }
    }

    static func extractOutputLines(from buffer: inout Data, flush: Bool = false) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        if flush, !buffer.isEmpty { lines.append(buffer); buffer.removeAll() }
        return lines
    }

    private func processLine(_ data: Data, for run: Invocation) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any],
              let kind = message["kind"] as? String else { return }

        guard invocation === run, run.lease.accepts(message["task_generation_id"] as? String) else {
            if !run.requestedStop && run.lease.state != .draining && run.lease.state != .retired {
                run.pendingTerminalEvent = .failed("TaskPilot runtime task ownership does not match; rebuild the bundled components together")
                beginDrain(run)
                run.process.terminate()
            }
            return
        }
        switch kind {
        case "model_health":
            emit(.modelHealth(message["model"] as? String ?? "", message["state"] as? String ?? "repair", message["detail"] as? String ?? ""), for: run)
        case "request_metrics":
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let metrics = try? decoder.decode(AgentRequestMetrics.self, from: data) { emit(.diagnostics(metrics), for: run) }
        case "bridge_request":
            let operationID = UUID()
            let operation = Task { [weak self] in
                guard let self else { return }
                let response = await TaskOwnership.$current.withValue(run.lease) {
                    if let handler = self.bridgeHandler { return await handler(message) }
                    return await self.bridge.handle(message)
                }
                self.ioQueue.async {
                    self.send(response, for: run)
                    run.operations.removeValue(forKey: operationID)
                }
            }
            run.operations[operationID] = operation
        case "status":
            if let text = message["message"] as? String { emit(.status(text), for: run) }
        case "output":
            let output = AgentTaskOutput(
                shouldShow: message["show_output"] as? Bool ?? false,
                title: message["title"] as? String ?? "Output",
                content: message["content"] as? String ?? "",
                decidedByAgent: message["decided_by_agent"] as? Bool ?? false,
                kind: AgentTaskOutputKind(rawValue: message["output_kind"] as? String ?? "result") ?? .result
            )
            emit(.output(output), for: run)
        case "user_input_required":
            guard let requestID = message["request_id"] as? String else { return }
            run.pendingUserInputID = requestID
            let request = AgentUserInputRequest(
                requestID: requestID,
                taskGenerationID: run.lease.id,
                title: message["title"] as? String ?? "Password required",
                message: message["message"] as? String ?? "Enter the requested credential to continue.",
                kind: AgentUserInputKind(
                    rawValue: message["input_kind"] as? String ?? "password"
                ) ?? .password
            )
            emit(.userInputRequired(request), for: run)
        case "complete":
            run.receivedTerminalEvent = true
            run.pendingTerminalEvent = .completed(message["message"] as? String ?? "Task complete")
            beginDrain(run)
        case "error":
            run.receivedTerminalEvent = true
            run.pendingTerminalEvent = .failed(message["message"] as? String ?? "The task failed")
            beginDrain(run)
        default:
            break
        }
    }

    private func send(_ object: [String: Any], for run: Invocation) {
        ioQueue.async { [weak self] in
            guard let self, self.invocation === run, run.lease.accepts(object["task_generation_id"] as? String),
                  var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(0x0A)
            do { try run.input.fileHandleForWriting.write(contentsOf: data) }
            catch {
                run.pendingTerminalEvent = .failed("Lost contact with the native screen controller")
                self.beginDrain(run)
                if run.process.isRunning { run.process.terminate() }
            }
        }
    }

    private func beginDrain(_ run: Invocation) {
        guard run.drainStarted == nil else { return }
        run.drainStarted = .now
        run.lease.revoke()
        for operation in run.operations.values { operation.cancel() }
        bridge.cancelActiveTool()
        pollDrain(run)
    }

    private func pollDrain(_ run: Invocation) {
        guard invocation === run, !run.terminalDelivered else { return }
        if run.exited && run.operations.isEmpty {
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

    private func emit(_ event: RuntimeEvent, for run: Invocation, terminal: Bool = false, retireAfterDelivery: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let delivery = self.ioQueue.sync {
                (self.invocation === run && (terminal || !run.requestedStop), retireAfterDelivery && run.requestedStop)
            }
            guard delivery.0 else { return }
            run.handler?(delivery.1 ? .stopped : event)
            if retireAfterDelivery { run.lease.retire() }
        }
    }
}
