#if DEBUG
import AppKit
import ApplicationServices
import Foundation

/// Opt-in stdio host for integration tests. It uses the signed app's actual
/// capture permissions and native bridge; normal app launch never enters here.
enum AutomationIntegrationBridge {
    private final class Placements {
        var windows: [WindowPlacement] = []
        var lease: TaskLease?
    }
    static func startIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--automation-test-bridge") else { return false }
        let accessibility = AccessibilityController()
        let bridge = AgentAutomationBridge(displayService: DisplayService(), accessibility: accessibility,
                                           capture: ScreenCaptureService())
        let placements = Placements()
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                FileHandle.standardError.write(Data("integration request: \(request["method"] ?? "unknown")\n".utf8))
                let finished = DispatchSemaphore(value: 0)
                Task {
                    let result: [String: Any]
                    if request["method"] as? String == "test_displays" {
                        result = ["kind": "bridge_response", "request_id": request["request_id"] ?? "", "ok": true,
                                  "result": ["accessibility": AXIsProcessTrusted(), "capture": CGPreflightScreenCaptureAccess(),
                                             "displays": DisplayService().displays().map { ["id": $0.id, "name": $0.name, "main": $0.isMain] as [String: Any] }]]
                    } else if request["method"] as? String == "test_begin",
                       let id = (request["params"] as? [String: Any])?["display_id"] as? UInt32,
                       let display = DisplayService().displays().first(where: { $0.id == id }) {
                        placements.windows = accessibility.captureWindowPlacements()
                        if let old = placements.lease {
                            old.revoke()
                            _ = accessibility.finishTaskResourceTracking(closeOpenedResources: false)
                            old.retire()
                        }
                        placements.lease = TaskLease()
                        try? bridge.bind(placements.lease!)
                        accessibility.beginTaskResourceTracking(on: display, lease: placements.lease)
                        result = ["kind": "bridge_response", "request_id": request["request_id"] ?? "", "ok": true,
                                  "result": ["task_generation_id": placements.lease!.id, "displays": DisplayService().displays().map { ["id": $0.id, "name": $0.name, "main": $0.isMain] as [String: Any] }]]
                    } else if request["method"] as? String == "test_end" {
                        placements.lease?.revoke()
                        _ = accessibility.finishTaskResourceTracking(closeOpenedResources: false)
                        accessibility.restoreWindows(placements.windows)
                        placements.windows = []
                        placements.lease?.retire(); placements.lease = nil
                        result = ["kind": "bridge_response", "request_id": request["request_id"] ?? "", "ok": true, "result": [:]]
                    } else {
                        var ownedRequest = request
                        ownedRequest["task_generation_id"] = placements.lease?.id
                        result = await bridge.handleOwned(ownedRequest, lease: placements.lease)
                    }
                    if let output = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                        FileHandle.standardOutput.write(output)
                        FileHandle.standardOutput.write(Data([10]))
                    }
                    finished.signal()
                }
                finished.wait()
            }
            FileHandle.standardError.write(Data("integration input closed\n".utf8))
            placements.lease?.revoke()
            accessibility.cancelInputDelivery()
            accessibility.restoreWindows(placements.windows)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }
}
#endif
