import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--managed-openclaw-check"),
   CommandLine.arguments.count > index + 2 {
    exit(ManagedGatewayHost.headlessCheck(descriptorURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                         runtimeURL: URL(fileURLWithPath: CommandLine.arguments[index + 2])))
}
if let index = CommandLine.arguments.firstIndex(of: "--managed-openclaw-host"),
   CommandLine.arguments.count > index + 2 {
    exit(ManagedGatewayHost.run(descriptorURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                runtimeURL: URL(fileURLWithPath: CommandLine.arguments[index + 2])))
}

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
