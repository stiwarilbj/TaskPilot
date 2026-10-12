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
            // Lookup and replay never require a connected display or a current
            // element map, and never dispatch the original operation again.
            if method == "action_receipt" {
                let id = try ActionReceiptStore.validateID(params["action_id"] as? String)
                return ["task_generation_id": lease.id, "kind": "bridge_response",
                        "request_id": requestID, "ok": true, "result": lease.actionReceipts.lookup(id)]
            }
            if method == "check_effect" {
                guard let check = params["check"] else { throw BridgeError.invalidRequest("Missing expected effect check") }
                let result = try await taskTools.checkOutcome(check)
                try lease.check()
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
                identity["action"] = action
                switch try lease.commit({ try lease.actionReceipts.begin(id: id, payload: identity) }) {
                case .existing(let receipt):
                    return receiptResponse(receipt, requestID: requestID, generation: lease.id)
                case .new(let token): receiptToken = token
                }
                validatedAction = action
            }
            let display = try targetDisplay(from: params)
            let result: [String: Any]

            switch method {
            case "observe":
                // The visual pointer is an action-only indicator. Hide it
                // before every screenshot so an idle cursor never obscures
                // page text or becomes part of the model's visual context.
                accessibility.hideAgentCursor()
                try accessibility.invalidateObservation()
                let budget: Double
                if let supplied = params["consistency_budget_ms"] {
                    guard let number = supplied as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                          (1...5000).contains(number.intValue) else {
                        throw BridgeError.invalidRequest("consistency_budget_ms must be an integer from 1 to 5000")
                    }
                    budget = number.doubleValue / 1000
                } else { budget = 5 }
                var observationDisplay = display
                let (accepted, screenshotURL) = try await ObservationConsistency.collect(
                    budget: budget,
                    checkpoint: { try await TaskOwnership.checkpoint() },
                    suspensionRevision: { lease.suspensionRevision },
                    scene: {
                        let current = try self.targetDisplay(from: params)
                        return try self.accessibility.observationScene(on: current)
                    },
                    stage: {
                        observationDisplay = try self.targetDisplay(from: params)
                        return try self.accessibility.stageSnapshot(on: observationDisplay)
                    },
                    signature: { $0.consistencySignature },
                    capture: { refresh in try await self.capture.capture(display: observationDisplay, forceRefresh: refresh) },
                    discard: { lease.discardArtifact($0) },
                    publish: { try $0.publish() },
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
                let snapshot = accepted.snapshot
                try TaskOwnership.check()
                result = [
                    "task_generation_id": lease.id,
                    "observation_revision": snapshot.revision,
                    "screenshot_path": screenshotURL.path,
                    "display": displayDictionary(observationDisplay),
                    "applications": snapshot.applications,
                    "installed_applications": snapshot.installedApplications,
                    "system_context": snapshot.systemContext,
                    "elements": snapshot.elements,
                    "agent_tools": [
                        "read_file": "Read a text or binary file by path; binary content is returned as base64.",
                        "write_file": "Create, overwrite, or append a file by path.",
                        "run_command": "Run literal argv or syntax-checked zsh source in a validated working directory; verify requested file/output checks. Exit zero alone proves execution only.",
                        "browser_control": "Navigate Safari, Chrome, or another browser to a URL/search, then control the rendered page through visible Accessibility actions.",
                        "app_automation": "Launch and control installed apps through visible Accessibility actions."
                    ],
                    "controller_protected": true,
                    "coordinate_space": "x and y actions use 0…1000 relative to this display",
                    "agent_cursor": "The blue TaskPilot pointer appears only during a validated pointer action on this display; it is not a clickable UI element"
                ]

            case "recheck":
                guard let action = params["action"] as? [String: Any] else {
                    throw BridgeError.invalidRequest("Missing readback payload")
                }
                result = try await taskTools.recheck(action: action)

            case "act":
                let action = validatedAction!
                let kind = ActionKind(rawValue: action["type"] as! String)!
                result = try await TaskOwnership.$actionReceipt.withValue(receiptToken) {
                    if kind.owner == .task_tool {
                        return try await taskTools.perform(action: action)
                    } else {
                        guard kind.owner == .desktop else {
                            throw BridgeError.invalidRequest("Runtime-local actions cannot be dispatched to the native bridge")
                        }
                        try accessibility.validateObservation(params["observation_revision"] as? String)
                        return try await accessibility.performStructured(action: action, on: display,
                            privateInput: params["private_input"] as? Bool == true)
                    }
                }
                receiptToken?.complete(result)

            default:
                throw BridgeError.invalidRequest("Unknown bridge method: \(method)")
            }
            try TaskOwnership.check()
            if let receiptToken {
                return receiptResponse(receiptToken.receipt, requestID: requestID, generation: lease.id)
            }
            return [
                "task_generation_id": lease.id,
                "kind": "bridge_response",
                "request_id": requestID,
                "ok": true,
                "result": result
            ]
        } catch {
            let code = error is CancellationError ? "cancelled" : error is ObservationConsistencyError ? "observation_unstable" : error is ActionContract.ValidationError ? "invalid_action" :
                (error as? ActionReceiptStore.ReceiptError)?.code ?? (error as? AccessibilityActionError)?.code ?? (error as? TaskToolError)?.code ?? "action_rejected"
            receiptToken?.fail(error, code: code)
            // Cancellation must remain a stop even if an acknowledged result
            // raced with revocation. The receipt still retains that result.
            if let receiptToken, code != "cancelled" {
                return receiptResponse(receiptToken.receipt, requestID: requestID, generation: lease?.id ?? "")
            }
            return [
                "task_generation_id": lease?.id ?? "",
                "kind": "bridge_response",
                "request_id": requestID,
                "ok": false,
                "error": error.localizedDescription,
                "error_code": code,
                "outcome": code == "delivery_uncertain" ? "delivered_unconfirmed" : "rejected"
            ]
        }
    }

    private func receiptResponse(_ receipt: [String: Any], requestID: String, generation: String) -> [String: Any] {
        var response: [String: Any] = ["task_generation_id": generation, "kind": "bridge_response", "request_id": requestID,
                                     "action_receipt": receipt.filter { ["action_id", "state", "terminal"].contains($0.key) }]
        if let result = receipt["result"] as? [String: Any] {
            response["ok"] = true; response["result"] = result
        } else {
            response["ok"] = false
            response["error"] = receipt["error"] ?? "The action is still pending; inspect its receipt before further work"
            response["error_code"] = receipt["error_code"] ?? "action_pending"
            response["outcome"] = receipt["state"] as? String == "rejected" ? "rejected" : "delivered_unconfirmed"
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
