import AppKit

#if DEBUG
final class IntegrationAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AutomationIntegrationBridge.startIfRequested()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

if CommandLine.arguments.contains("--automation-test-bridge") {
    let application = NSApplication.shared
    let delegate = IntegrationAppDelegate()
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    application.run()
} else {
    TaskPilotApp.main()
}
#else
TaskPilotApp.main()
#endif
