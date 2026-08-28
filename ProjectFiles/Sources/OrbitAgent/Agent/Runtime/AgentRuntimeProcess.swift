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
    let title: String
    let message: String
    let kind: AgentUserInputKind

    var id: String { requestID }
}

enum RuntimeEvent {
    case status(String)
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
    var onEvent: ((RuntimeEvent) -> Void)?

    private let bridge: AgentAutomationBridge
    private let ioQueue = DispatchQueue(label: "com.orbitagent.runtime-io")
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputBuffer = Data()
    private var lastErrorLine = ""
    private var requestedStop = false
    private var receivedTerminalEvent = false
    private var pendingTerminalEvent: RuntimeEvent?

    init(bridge: AgentAutomationBridge) {
        self.bridge = bridge
    }

    func start(
        task: String,
        display: DisplayDescriptor,
        runtimeURL: URL,
        openClawURL: URL,
        geminiAPIKey: String
    ) throws {
        guard process == nil else { throw RuntimeProcessError.alreadyRunning }
        guard FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
            throw RuntimeProcessError.runtimeMissing
        }

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

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeOutput(data)
        }
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.ioQueue.async {
                let lines = text.split(whereSeparator: \.isNewline)
                if let last = lines.last { self?.lastErrorLine = String(last) }
            }
        }

        requestedStop = false
        receivedTerminalEvent = false
        pendingTerminalEvent = nil
        outputBuffer.removeAll(keepingCapacity: true)
        lastErrorLine = ""
        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.ioQueue.async {
                output.fileHandleForReading.readabilityHandler = nil
                error.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.inputPipe = nil
                if self.requestedStop {
                    self.emit(.stopped)
                } else if let pendingTerminalEvent = self.pendingTerminalEvent {
                    self.pendingTerminalEvent = nil
                    self.emit(pendingTerminalEvent)
                } else if !self.receivedTerminalEvent {
                    let detail = self.lastErrorLine.isEmpty
                        ? "The OpenClaw bridge exited unexpectedly"
                        : self.lastErrorLine
                    self.emit(.failed(detail))
                }
            }
        }

        self.process = process
        self.inputPipe = input
        do {
            try process.run()
            // Pass the secret through the already-private controller pipe,
            // never through arguments, environment variables, or logs. The
            // runtime consumes this first line before it begins bridge calls.
            var configuration = try JSONSerialization.data(withJSONObject: [
                "kind": "runtime_configuration",
                "gemini_api_key": geminiAPIKey
            ])
            configuration.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: configuration)
        } catch let launchError {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            self.process = nil
            self.inputPipe = nil
            pendingTerminalEvent = nil
            throw launchError
        }
    }

    func pause() {
        bridge.pauseActiveTool()
        signalRuntime(SIGSTOP)
    }

    func resume() {
        bridge.resumeActiveTool()
        signalRuntime(SIGCONT)
    }

    func stop() {
        requestedStop = true
        bridge.cancelActiveTool()
        guard let process else { return }
        signalRuntime(SIGCONT)
        signalRuntime(SIGTERM)
        if process.isRunning {
            process.terminate()
        }
    }

    func submitUserInput(requestID: String, value: String) {
        // The credential crosses only the existing private stdin pipe. It is
        // never placed in arguments, environment variables, status text, or
        // the OpenClaw conversation.
        send([
            "kind": "user_input_response",
            "request_id": requestID,
            "value": value
        ])
    }

    private func signalRuntime(_ signal: Int32) {
        guard let pid = process?.processIdentifier else { return }
        // The packaged Python helper makes itself a process-group leader, so
        // pause/stop applies to its OpenClaw ACP child as well. Fall back to the
        // helper pid during the brief startup window before setpgrp completes.
        if kill(-pid, signal) != 0 {
            kill(pid, signal)
        }
    }

    private func consumeOutput(_ data: Data) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.outputBuffer.append(data)
            while let newline = self.outputBuffer.firstIndex(of: 0x0A) {
                let lineData = self.outputBuffer[..<newline]
                self.outputBuffer.removeSubrange(...newline)
                guard !lineData.isEmpty else { continue }
                self.processLine(Data(lineData))
            }
        }
    }

    private func processLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any],
              let kind = message["kind"] as? String else { return }

        switch kind {
        case "bridge_request":
            Task { [weak self] in
                guard let self else { return }
                let response = await self.bridge.handle(message)
                self.send(response)
            }
        case "status":
            if let text = message["message"] as? String { emit(.status(text)) }
        case "output":
            let output = AgentTaskOutput(
                shouldShow: message["show_output"] as? Bool ?? false,
                title: message["title"] as? String ?? "Output",
                content: message["content"] as? String ?? "",
                decidedByAgent: message["decided_by_agent"] as? Bool ?? false,
                kind: AgentTaskOutputKind(rawValue: message["output_kind"] as? String ?? "result") ?? .result
            )
            emit(.output(output))
        case "user_input_required":
            guard let requestID = message["request_id"] as? String else { return }
            let request = AgentUserInputRequest(
                requestID: requestID,
                title: message["title"] as? String ?? "Password required",
                message: message["message"] as? String ?? "Enter the requested credential to continue.",
                kind: AgentUserInputKind(
                    rawValue: message["input_kind"] as? String ?? "password"
                ) ?? .password
            )
            emit(.userInputRequired(request))
        case "complete":
            receivedTerminalEvent = true
            pendingTerminalEvent = .completed(message["message"] as? String ?? "Task complete")
        case "error":
            receivedTerminalEvent = true
            pendingTerminalEvent = .failed(message["message"] as? String ?? "The task failed")
        default:
            break
        }
    }

    private func send(_ object: [String: Any]) {
        ioQueue.async { [weak self] in
            guard let self, let handle = self.inputPipe?.fileHandleForWriting,
                  var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(0x0A)
            do {
                try handle.write(contentsOf: data)
            } catch {
                self.receivedTerminalEvent = true
                self.pendingTerminalEvent = .failed(
                    "Lost contact with the native screen controller"
                )
                if let process = self.process, process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    private func emit(_ event: RuntimeEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
