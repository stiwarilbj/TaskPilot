import AppKit
import SwiftUI

final class TaskPilotAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum ControllerWindowLayout {
    static let minimumWidth: CGFloat = 520
    static let minimumHeight: CGFloat = 575
    static let defaultWidth: CGFloat = 720
    static let defaultHeight: CGFloat = 720
    static let supportsHorizontalAndVerticalResizing = true
}

@main
struct TaskPilotApp: App {
    @NSApplicationDelegateAdaptor(TaskPilotAppDelegate.self) private var appDelegate
    @StateObject private var model = TaskPilotCoordinator()

    var body: some Scene {
        Window(TaskPilotIdentity.displayName, id: "controller") {
            TaskPilotMainView(model: model)
                .frame(
                    minWidth: ControllerWindowLayout.minimumWidth,
                    minHeight: ControllerWindowLayout.minimumHeight
                )
        }
        .windowResizability(.contentSize)
        .defaultSize(
            width: ControllerWindowLayout.defaultWidth,
            height: ControllerWindowLayout.defaultHeight
        )
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Window(TaskPilotIdentity.liveScreenWindowTitle, id: "agent-viewer") {
            AgentScreenViewer(
                model: model.viewer,
                display: model.agentDisplay
            )
            .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 960, height: 620)

        Window(TaskPilotIdentity.queueWindowTitle, id: "task-center") {
            TaskQueueHistoryView(model: model)
        }
        .defaultSize(width: 760, height: 720)
    }
}
