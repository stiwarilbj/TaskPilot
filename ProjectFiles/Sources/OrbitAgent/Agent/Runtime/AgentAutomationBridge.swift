import Foundation

final class AgentAutomationBridge {
    private let displayService: DisplayService
    private let accessibility: AccessibilityController
    private let capture: ScreenCaptureService
    private let taskTools = TaskToolExecutor()
    private let ownershipLock = NSLock()
    private var activeLease: TaskLease?
    func bind(_ lease: TaskLease) throws {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        try lease.check()
        guard activeLease == nil || activeLease?.state == .retired else { throw RuntimeProcessError.alreadyRunning }
        activeLease = lease
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
        do {
            guard let lease, owns(lease), lease.accepts(request["task_generation_id"] as? String) else { throw CancellationError() }
            try await lease.checkpoint()
            guard let method = request["method"] as? String else {
                throw BridgeError.invalidRequest("Missing bridge method")
            }
            let params = request["params"] as? [String: Any] ?? [:]
            let display = try targetDisplay(from: params)
            let result: [String: Any]

            switch method {
            case "observe":
                // The visual pointer is an action-only indicator. Hide it
                // before every screenshot so an idle cursor never obscures
                // page text or becomes part of the model's visual context.
                accessibility.hideAgentCursor()
                // Capture first, then bind element IDs to the immediately
                // following tree instead of racing an older tree with pixels.
                let screenshotURL = try await capture.capture(display: display)
                try await TaskOwnership.checkpoint()
                let snapshot = accessibility.snapshot(on: display)
                try TaskOwnership.check()
                result = [
                    "task_generation_id": lease.id,
                    "observation_revision": snapshot.revision,
                    "screenshot_path": screenshotURL.path,
                    "display": displayDictionary(display),
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

            case "act":
                guard let inputAction = params["action"] as? [String: Any] else {
                    throw BridgeError.invalidRequest("Missing action payload")
                }
                let action: [String: Any]
                action = try ActionContract.validate(inputAction)
                let kind = ActionKind(rawValue: action["type"] as! String)!
                if kind.owner == .task_tool {
                    result = try await taskTools.perform(action: action)
                } else {
                    guard kind.owner == .desktop else {
                        throw BridgeError.invalidRequest("Runtime-local actions cannot be dispatched to the native bridge")
                    }
                    try accessibility.validateObservation(params["observation_revision"] as? String)
                    result = try await accessibility.performStructured(action: action, on: display,
                        privateInput: params["private_input"] as? Bool == true)
                }

            default:
                throw BridgeError.invalidRequest("Unknown bridge method: \(method)")
            }
            try TaskOwnership.check()
            return [
                "task_generation_id": lease.id,
                "kind": "bridge_response",
                "request_id": requestID,
                "ok": true,
                "result": result
            ]
        } catch {
            let code = error is CancellationError ? "cancelled" : error is ActionContract.ValidationError ? "invalid_action" :
                (error as? AccessibilityActionError)?.code ?? (error as? TaskToolError)?.code ?? "action_rejected"
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
