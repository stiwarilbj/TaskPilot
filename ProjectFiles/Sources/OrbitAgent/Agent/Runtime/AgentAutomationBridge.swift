import CoreFoundation
import Foundation
import OSLog

final class AgentAutomationBridge {
    private let displayService: DisplayService
    private let accessibility: AccessibilityController
    private let capture: ScreenCaptureService
    private let taskTools = TaskToolExecutor()
    private let ownershipLock = NSLock()
    private var activeLease: TaskLease?
    // Aggregate numbers only; no capture/target contents or generation IDs.
    private var observationDiagnostics = ObservationConsistencyDiagnostics()
    private let observationLogger = Logger(subsystem: "com.orbitagent.controller", category: "ObservationConsistency")
    func bind(_ lease: TaskLease) throws {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        try lease.check()
        guard activeLease == nil || activeLease?.state == .retired else { throw RuntimeProcessError.alreadyRunning }
        activeLease = lease
        taskTools.resetCommandCapabilities()
        observationDiagnostics = ObservationConsistencyDiagnostics()
    }
    private func owns(_ lease: TaskLease) -> Bool {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        return activeLease === lease
    }

    init(
        displayService: DisplayService,
        accessibility: AccessibilityController,
        capture: ScreenCaptureService
    ) {
        self.displayService = displayService
        self.accessibility = accessibility
        self.capture = capture
    }

    func pauseActiveTool() {
        taskTools.pauseActiveCommand()
    }

    func resumeActiveTool() {
        taskTools.resumeActiveCommand()
    }

    func cancelActiveTool() {
        accessibility.cancelInputDelivery()
        taskTools.cancelActiveCommand()
    }

    func handleOwned(_ request: [String: Any], lease: TaskLease?) async -> [String: Any] {
        await TaskOwnership.$current.withValue(lease) { await handle(request) }
    }

    func handle(_ request: [String: Any]) async -> [String: Any] {
        await TaskOwnership.withCancellationWakeup { await handleRequest(request) }
    }

    private func handleRequest(_ request: [String: Any]) async -> [String: Any] {
        let requestID = request["request_id"] as? String ?? UUID().uuidString
        let lease = TaskOwnership.current
        var receiptToken: ActionReceiptStore.Token?
        do {
            guard let lease, owns(lease), lease.accepts(request["task_generation_id"] as? String) else { throw CancellationError() }
            try await lease.checkpoint()
            guard let method = request["method"] as? String else {
                throw BridgeError.invalidRequest("Missing bridge method")
            }
            let params = request["params"] as? [String: Any] ?? [:]
            if LocalOperationBudget.current == nil {
                let seconds = try localBudgetSeconds(method: method, params: params)
                return await LocalOperationBudget.$current.withValue(LocalOperationBudget(seconds: seconds, phase: method)) {
                    await self.handleRequest(request)
                }
            }
            try LocalOperationBudget.check(method)
            if method == "inspect_command" {
                guard let action = params["action"] as? [String: Any] else { throw BridgeError.invalidRequest("Missing command inspection payload") }
                let result = try await taskTools.inspectCommand(action: action)
                try TaskOwnership.check()
                return ["task_generation_id": lease.id, "kind": "bridge_response", "request_id": requestID,
                        "ok": true, "result": result]
            }
            if method == "wait_file_effect" {
                guard let input = params["check"] else { throw BridgeError.invalidRequest("Missing expected effect check") }
                let check = try ActionContract.validateOutcomeCheck(input)
                guard let path = check["path"] as? String else { throw BridgeError.invalidRequest("A local wait requires a file check") }
                let budget = try localWaitMilliseconds(params["timeout_ms"], maximum: 2000, defaultValue: 2000)
                let deadline = ProcessInfo.processInfo.systemUptime + LocalOperationBudget.allowance(Double(budget) / 1000)
                let signal = LocalChangeSignal(lease: lease)
                let source = await NativeChangeSubscription.file(TaskToolExecutor.expandedFileURL(path), signal: signal)
                var last: [String: Any] = [:]
                let wait = try await LocalChangeWait.run(signal: signal, source: source, deadline: deadline, check: {
                    last = try await self.taskTools.checkOutcome(check)
                    return (last["checks"] as? [[String: Any]])?.first?["verified"] as? Bool == true
                })
                try TaskOwnership.check()
                if wait.reason == "resumed" {
                    // A readback completed across Pause/Resume cannot become
                    // current proof. Reconcile afresh; never replay the action.
                    last = ["requested_checks": [check], "checks": [["type": check["type"]!,
                        "path": TaskToolExecutor.expandedFileURL(path).path, "verified": false,
                        "outcome": "delivered_unconfirmed", "verification_scope": check["type"]!]],
                        "outcome": "delivered_unconfirmed", "verified": false, "verification_scope": "requested_outcomes"]
                }
                last = try ActionContract.validateCheckBatch(last.merging(["local_wait": wait.dictionary]) { _, new in new })
                return ["task_generation_id": lease.id, "kind": "bridge_response", "request_id": requestID,
                        "ok": true, "result": last]
            }
            // Lookup and replay never require a connected display or a current
            // element map, and never dispatch the original operation again.
            if method == "action_receipt" {
                let id = try ActionReceiptStore.validateID(params["action_id"] as? String)
                let receipt = try ActionContract.validateNativeReceipt(lease.actionReceipts.lookup(id), actionID: id)
                return ["task_generation_id": lease.id, "kind": "bridge_response",
                        "request_id": requestID, "ok": true, "result": receipt]
            }
            if method == "check_effect" {
                guard let check = params["check"] else { throw BridgeError.invalidRequest("Missing expected effect check") }
                let result = try await taskTools.checkOutcome(check)
                try TaskOwnership.check()
                return ["task_generation_id": lease.id, "kind": "bridge_response", "request_id": requestID,
                        "ok": true, "result": result]
            }
            var validatedAction: [String: Any]?
            if method == "act" {
                guard let input = params["action"] as? [String: Any] else {
                    throw BridgeError.invalidRequest("Missing action payload")
                }
                let action = try ActionContract.validate(input)
                let id = try ActionReceiptStore.validateID(params["action_id"] as? String)
                var identity = params
                identity.removeValue(forKey: "action_id")
                identity.removeValue(forKey: "local_budget_ms")
                identity["action"] = action
                switch try lease.commit({ try lease.actionReceipts.begin(id: id, payload: identity) }) {
                case .existing(let receipt):
                    return try receiptResponse(receipt, requestID: requestID, generation: lease.id)
                case .new(let token): receiptToken = token
                }
                validatedAction = action
            }
            let display = try targetDisplay(from: params)
            let result: [String: Any]

            switch method {
            case "wait_for_change":
                let budget = try localWaitMilliseconds(params["timeout_ms"], maximum: 500, defaultValue: 500)
                let delay = try localWaitMilliseconds(params["minimum_delay_ms"], maximum: 300, defaultValue: 50, allowZero: true)
                let deadline = ProcessInfo.processInfo.systemUptime + LocalOperationBudget.allowance(Double(budget) / 1000)
                let target = try accessibility.localChangeTarget(params)
                let signal = LocalChangeSignal(lease: lease)
                let source = await NativeChangeSubscription.accessibility(pid: target.pid, elements: target.elements, signal: signal, deadline: deadline)
                let wait = try await LocalChangeWait.run(signal: signal, source: source, deadline: deadline,
                    minimumDelay: Double(delay) / 1000, check: { try target.check() })
                result = wait.dictionary

            case "observe":
                let inspectionPID = try ControlEvidencePolicy.inspectionPID(params["evidence_inspection_pid"])
                // The visual pointer is an action-only indicator. Hide it
                // before every screenshot so an idle cursor never obscures
                // page text or becomes part of the model's visual context.
                accessibility.hideAgentCursor()
                try accessibility.invalidateObservation()
                try lease.bindScreenText(nil)
                let budget: Double
                if let supplied = params["consistency_budget_ms"] {
                    guard let number = supplied as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                          (1...5000).contains(number.intValue) else {
                        throw BridgeError.invalidRequest("consistency_budget_ms must be an integer from 1 to 5000")
                    }
                    budget = number.doubleValue / 1000
                } else { budget = 5 }
                let keywords: [String]
                if let supplied = params["observation_keywords"] {
                    guard let values = supplied as? [String], values.count <= 48,
                          values.allSatisfy({ !$0.isEmpty && $0.count <= 64 && $0.allSatisfy({ $0.isLetter || $0.isNumber }) }) else {
                        throw BridgeError.invalidRequest("observation_keywords must be at most 48 bounded words")
                    }
                    keywords = values
                } else { keywords = [] }
                var observationDisplay = display
                var encodedScreen: CapturedScreen?
                var recognitionDeadline = ProcessInfo.processInfo.systemUptime
                var screenText = ScreenTextSnapshot()
                var textMetadata: [String: Any] = [:]
                let (accepted, acceptedFrame) = try await ObservationConsistency.collect(
                    budget: LocalOperationBudget.allowance(budget),
                    checkpoint: { try await TaskOwnership.checkpoint() },
                    suspensionRevision: { lease.suspensionRevision },
                    scene: {
                        let current = try self.targetDisplay(from: params)
                        return try self.accessibility.observationScene(on: current)
                    },
                    stage: { remaining in
                        try LocalOperationBudget.check("accessibility_collection")
                        observationDisplay = try self.targetDisplay(from: params)
                        recognitionDeadline = ProcessInfo.processInfo.systemUptime + remaining
                        let staged = try self.accessibility.stageSnapshot(on: observationDisplay, keywords: keywords, budget: remaining, forceFreshTopology: false)
                        return staged
                    },
                    stageAfter: { remaining in
                        try self.accessibility.stageSnapshot(on: self.targetDisplay(from: params),
                            keywords: keywords, budget: remaining, forceFreshTopology: true)
                    },
                    signature: { $0.consistencySignature },
                    capture: { refresh in
                        try LocalOperationBudget.check("capture_acquisition")
                        return try await self.capture.acquire(display: observationDisplay, forceRefresh: refresh)
                    },
                    discard: { frame in
                        if let encoded = encodedScreen, encoded.frameID == frame.id {
                            lease.discardArtifact(encoded.url); encodedScreen = nil
                        }
                    },
                    prepare: { candidate, frame, pairedScene in
                        try LocalOperationBudget.check("text_recognition")
                        screenText = try await LocalTextRecognition.supplement(image: frame.image,
                            coordinates: frame.coordinates, snapshot: candidate.snapshot, scene: pairedScene,
                            keywords: keywords, budget: recognitionDeadline - ProcessInfo.processInfo.systemUptime,
                            inspectionPID: inspectionPID)
                        try LocalOperationBudget.check("capture_encoding")
                        encodedScreen = try await self.capture.encode(frame)
                    },
                    publish: { candidate in
                        guard let encoded = encodedScreen else { throw ScreenCoordinateError.invalidGeometry }
                        let coordinates = encoded.coordinates
                        let metadata = try screenText.metadata(revision: candidate.snapshot.revision, coordinates: coordinates)
                        // Text evidence, AX IDs and image coordinates become
                        // authoritative together, under the same epoch check.
                        try lease.commit {
                            try candidate.publish()
                            try self.accessibility.bindCoordinates(coordinates, revision: candidate.snapshot.revision, on: observationDisplay)
                            try lease.bindScreenText(screenText, revision: candidate.snapshot.revision)
                        }
                        textMetadata = metadata
                    },
                    report: { summary in
                        self.observationLogger.debug("Capture attempts: \(summary.attempts), rejected: \(summary.rejected.values.reduce(0, +)), elapsed seconds: \(summary.elapsedSeconds)")
                        self.ownershipLock.withLock {
                            self.observationDiagnostics.attempts += summary.attempts
                            self.observationDiagnostics.elapsedSeconds += summary.elapsedSeconds
                            for (reason, count) in summary.rejected {
                                self.observationDiagnostics.rejected[reason, default: 0] += count
                            }
                        }
                    })
                guard let encoded = encodedScreen, encoded.frameID == acceptedFrame.id else {
                    if let encoded = encodedScreen { lease.discardArtifact(encoded.url) }
                    throw ScreenCoordinateError.invalidGeometry
                }
                let screenshotURL = encoded.url
                let coordinates = acceptedFrame.coordinates
                let snapshot = accepted.snapshot
                try TaskOwnership.check()
                let expansion = snapshot.completeness["local_expansion"] as? [String: Int] ?? [:]
                let gaps = snapshot.completeness["reason_counts"] as? [String: Int] ?? [:]
                observationLogger.debug("Collected controls: \(snapshot.elements.count), gap scopes: \(gaps.values.reduce(0, +)), expanded subtrees: \(expansion["subtrees_attempted", default: 0]), read retries: \(expansion["read_retries", default: 0])")
                observationLogger.debug("Local text candidates: \(screenText.targets.count), detail crops: \(screenText.crops.count)")
                result = [
                    "task_generation_id": lease.id,
                    "local_change_notifications": true,
                    "command_capability_version": CommandCapabilities.version,
                    "observation_revision": snapshot.revision,
                    "screenshot_path": screenshotURL.path,
                    "display": displayDictionary(observationDisplay),
                    "coordinate_mapping": coordinates.metadata(revision: snapshot.revision),
                    "applications": snapshot.applications,
                    "installed_applications": snapshot.installedApplications,
                    "system_context": snapshot.systemContext,
                    "elements": snapshot.elements,
                    "observation_completeness": snapshot.completeness,
                    "text_recognition": textMetadata,
                    "agent_tools": [
                        "read_file": "Read a text or binary file by path; binary content is returned as base64.",
                        "write_file": "Create, overwrite, or append a file by path.",
                        "run_command": "Run literal argv or syntax-checked zsh source in a validated working directory; verify requested file/output checks. Exit zero alone proves execution only.",
                        "browser_control": "Navigate Safari, Chrome, or another browser to a URL/search, then control the rendered page through visible Accessibility actions.",
                        "app_automation": "Launch and control installed apps through visible Accessibility actions."
                    ],
                    "controller_protected": true,
                    "coordinate_space": "Actions use 0…1000 over the FULL display, x right/y down. Image pixels use coordinate_mapping.image_to_global; never use pixel values as action coordinates.",
                    "agent_cursor": "The blue TaskPilot pointer appears only during a validated pointer action on this display; it is not a clickable UI element"
                ]

            case "recheck":
                guard let action = params["action"] as? [String: Any] else {
                    throw BridgeError.invalidRequest("Missing readback payload")
                }
                result = try ActionContract.validateNativeReadback(try await taskTools.recheck(action: action), action: action)

            case "act":
                let action = validatedAction!
                let kind = ActionKind(rawValue: action["type"] as! String)!
                result = try await TaskOwnership.$actionReceipt.withValue(receiptToken) {
                    if kind.owner == .task_tool {
                        return try await taskTools.perform(action: action, commandBindingID: params["command_inspection_id"] as? String)
                    } else {
                        guard kind.owner == .desktop else {
                            throw BridgeError.invalidRequest("Runtime-local actions cannot be dispatched to the native bridge")
                        }
                        try accessibility.validateObservation(params["observation_revision"] as? String)
                        try accessibility.validateCoordinates(on: display)
                        return try await accessibility.performStructured(action: action, on: display,
                            privateInput: params["private_input"] as? Bool == true,
                            verifyScreenshotTarget: {
                                try await self.verifyTextTarget(action, display: display, lease: lease,
                                    revision: params["observation_revision"] as? String ?? "")
                            })
                    }
                }
                try LocalOperationBudget.check()
                try receiptToken?.complete(result)

            default:
                throw BridgeError.invalidRequest("Unknown bridge method: \(method)")
            }
            try TaskOwnership.check()
            if let receiptToken {
                return try receiptResponse(receiptToken.receipt, requestID: requestID, generation: lease.id)
            }
            return [
                "task_generation_id": lease.id,
                "kind": "bridge_response",
                "request_id": requestID,
                "ok": true,
                "result": result
            ]
        } catch {
            let code = error is LocalOperationBudget.Exhausted ? "local_budget_exhausted" : error is ActionContract.NativeProtocolError ? "protocol_error" : error is CancellationError ? "cancelled" : error is ObservationConsistencyError ? "observation_unstable" : error is ActionContract.ValidationError ? "invalid_action" :
                (error as? ActionReceiptStore.ReceiptError)?.code ?? (error as? AccessibilityActionError)?.code ?? (error as? TaskToolError)?.code ?? (error is BoundFileOperation.Conflict ? "file_conflict" : "action_rejected")
            receiptToken?.fail(error, code: code)
            // Cancellation must remain a stop even if an acknowledged result
            // raced with revocation. The receipt still retains that result.
            if let receiptToken, code != "cancelled" {
                if let response = try? receiptResponse(receiptToken.receipt, requestID: requestID, generation: lease?.id ?? "") { return response }
            }
            return [
                "task_generation_id": lease?.id ?? "",
                "kind": "bridge_response",
                "request_id": requestID,
                "ok": false
            ].merging(ActionContract.nativeFailure(error, code: code,
                outcome: receiptToken?.receipt["state"] as? String == "unconfirmed" || code == "delivery_uncertain" || (error as? BoundFileOperation.Conflict)?.delivered == true ? "delivered_unconfirmed" : "rejected")) { _, new in new }
        }
    }

    private func verifyTextTarget(_ action: [String: Any], display: DisplayDescriptor, lease: TaskLease,
                                  revision: String) async throws -> (() throws -> Void)? {
        guard action["element_id"] == nil, ["click", "double_click"].contains(action["type"] as? String ?? ""),
              let x = action["x"] as? NSNumber, let y = action["y"] as? NSNumber, let pid = action["pid"] as? Int,
              let text = try lease.screenTextSnapshot(revision: revision) else { return nil }
        let point = try ScreenCoordinateMapping.displayOnly(display).eventPoint(fromNormalized:
            CGPoint(x: x.doubleValue, y: y.doubleValue))
        guard let target = try text.target(at: point, pid: pid) else { return nil }
        let suspension = lease.suspensionRevision
        try accessibility.validateTextPointer(action: action, on: display)
        let scene = try accessibility.observationScene(on: display)
        guard LocalTextRecognition.windows(scene: scene).contains(target.window) else {
            throw AccessibilityActionError.staleObservation
        }
        // Read-only text reconciliation needs pixels, not a PNG artifact.
        let captured = try await capture.acquire(display: display, forceRefresh: true)
        let region = target.match.frame.insetBy(dx: -40, dy: -25).intersection(target.window.frame).intersection(display.frame)
        guard let (image, mapping) = try LocalTextRecognition.crop(captured.image, coordinates: captured.coordinates, frame: region) else {
            throw AccessibilityActionError.staleObservation
        }
        let matches: [ScreenTextMatch]
        do { matches = try await LocalTextRecognition.recognize(image, mapping, 1) }
        catch { try TaskOwnership.check(); throw AccessibilityActionError.staleObservation }
        try LocalTextRecognition.validate(target, matches: matches, point: point)
        guard suspension == lease.suspensionRevision, try accessibility.observationScene(on: display) == scene else {
            throw AccessibilityActionError.staleObservation
        }
        return { [self] in
            try lease.check()
            try accessibility.validateObservation(revision)
            guard suspension == lease.suspensionRevision, try accessibility.observationScene(on: display) == scene else {
                throw AccessibilityActionError.staleObservation
            }
            try accessibility.validateTextPointer(action: action, on: display)
        }
    }

    private func receiptResponse(_ receipt: [String: Any], requestID: String, generation: String) throws -> [String: Any] {
        try ActionContract.validateNativeReceipt(receipt)
        var response: [String: Any] = ["task_generation_id": generation, "kind": "bridge_response", "request_id": requestID,
                                     "action_receipt": receipt.filter { ["action_id", "state", "terminal"].contains($0.key) }]
        if let result = receipt["result"] as? [String: Any] {
            response["ok"] = true; response["result"] = result
        } else {
            response["ok"] = false
            if receipt["terminal"] as! Bool {
                response.merge(receipt.filter { ActionContract.nativeErrorFields.contains($0.key) }) { _, new in new }
            } else {
                response.merge(ActionContract.nativeFailure(BridgeError.invalidRequest("The action is still pending; inspect its receipt before further work"),
                    code: "action_pending", outcome: "dispatched")) { _, new in new }
            }
        }
        return response
    }

    private func targetDisplay(from params: [String: Any]) throws -> DisplayDescriptor {
        let displays = displayService.displays()
        if let number = params["display_id"] as? NSNumber,
           let display = displays.first(where: { $0.id == number.uint32Value }) {
            return accessibility.resolvedTaskDisplay(
                preferred: display,
                availableDisplays: displays
            )
        }
        if let id = params["display_id"] as? UInt32,
           let display = displays.first(where: { $0.id == id }) {
            return accessibility.resolvedTaskDisplay(
                preferred: display,
                availableDisplays: displays
            )
        }
        guard let display = displayService.agentDisplay() else {
            throw BridgeError.displayMissing
        }
        return accessibility.resolvedTaskDisplay(
            preferred: display,
            availableDisplays: displays
        )
    }

    private func localBudgetSeconds(method: String, params: [String: Any]) throws -> TimeInterval {
        var limit: Double = method == "act" ? 30 : 5
        if method == "act", let action = params["action"] as? [String: Any], action["type"] as? String == "run_command" {
            let validated = try ActionContract.validate(action)
            limit += (validated["timeout_seconds"] as? NSNumber)?.doubleValue ?? (ActionContract.defaultValue(.run_command, "timeout_seconds") as! NSNumber).doubleValue
        }
        if let supplied = params["local_budget_ms"] {
            guard let number = supplied as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue > 0, number.doubleValue <= 3_600_000 else {
                throw BridgeError.invalidRequest("local_budget_ms must be an integer from 1 to 3600000")
            }
            limit = min(limit, number.doubleValue / 1000)
        }
        return limit
    }

    private func localWaitMilliseconds(_ input: Any?, maximum: Int, defaultValue: Int, allowZero: Bool = false) throws -> Int {
        guard let input else { return defaultValue }
        guard let number = input as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              ((allowZero ? 0 : 1)...maximum).contains(number.intValue) else {
            throw BridgeError.invalidRequest("Local wait milliseconds must be an integer from \(allowZero ? 0 : 1) to \(maximum)")
        }
        return number.intValue
    }

    private func displayDictionary(_ display: DisplayDescriptor) -> [String: Any] {
        [
            "id": display.id,
            "name": display.name,
            "x": display.x,
            "y": display.y,
            "width": display.width,
            "height": display.height,
            "is_main": display.isMain
        ]
    }
}

private enum BridgeError: LocalizedError {
    case invalidRequest(String)
    case displayMissing

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        case .displayMissing: return "The agent screen disconnected"
        }
    }
}
