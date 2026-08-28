import Foundation

final class AgentAutomationBridge {
    private let displayService: DisplayService
    private let accessibility: AccessibilityController
    private let capture: ScreenCaptureService
    private let taskTools = TaskToolExecutor()

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
        taskTools.cancelActiveCommand()
    }

    func handle(_ request: [String: Any]) async -> [String: Any] {
        let requestID = request["request_id"] as? String ?? UUID().uuidString
        do {
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
                async let screenshotURLTask = capture.capture(display: display)
                let snapshot = accessibility.snapshot(on: display)
                let screenshotURL = try await screenshotURLTask
                result = [
                    "screenshot_path": screenshotURL.path,
                    "display": displayDictionary(display),
                    "applications": snapshot.applications,
                    "installed_applications": snapshot.installedApplications,
                    "system_context": snapshot.systemContext,
                    "elements": snapshot.elements,
                    "agent_tools": [
                        "read_file": "Read a text or binary file by path; binary content is returned as base64.",
                        "write_file": "Create, overwrite, or append a file by path.",
                        "run_command": "Run a zsh command with a working directory, timeout, exit code, stdout, and stderr.",
                        "browser_control": "Navigate Safari, Chrome, or another browser to a URL/search, then control the rendered page through visible Accessibility actions.",
                        "app_automation": "Launch and control installed apps through visible Accessibility actions."
                    ],
                    "controller_protected": true,
                    "coordinate_space": "x and y actions use 0…1000 relative to this display",
                    "agent_cursor": "The blue TaskPilot pointer appears only during a validated pointer action on this display; it is not a clickable UI element"
                ]

            case "act":
                guard let action = params["action"] as? [String: Any] else {
                    throw BridgeError.invalidRequest("Missing action payload")
                }
                if let type = action["type"] as? String,
                   TaskToolExecutor.supportedActions.contains(type) {
                    result = try await taskTools.perform(action: action)
                } else {
                    let message = try await accessibility.perform(action: action, on: display)
                    result = ["message": message]
                }

            default:
                throw BridgeError.invalidRequest("Unknown bridge method: \(method)")
            }
            return [
                "kind": "bridge_response",
                "request_id": requestID,
                "ok": true,
                "result": result
            ]
        } catch {
            return [
                "kind": "bridge_response",
                "request_id": requestID,
                "ok": false,
                "error": error.localizedDescription
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
