import AppKit
import CoreGraphics
import Foundation

struct DisplayDescriptor: Codable, Equatable, Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isMain: Bool

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

final class DisplayService {
    static let preferredDisplayName = TaskPilotIdentity.compatibilityAgentScreenName

    func displays() -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            let frame = CGDisplayBounds(id)
            return DisplayDescriptor(
                id: id,
                name: screen.localizedName,
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height,
                isMain: CGDisplayIsMain(id) != 0
            )
        }
    }

    func agentDisplay() -> DisplayDescriptor? {
        let all = displays()
        if let preferred = preferredAgentDisplay(in: all) {
            return preferred
        }
        return all.first(where: { !$0.isMain })
    }

    func preferredAgentDisplay() -> DisplayDescriptor? {
        preferredAgentDisplay(in: displays())
    }

    func mainDisplay() -> DisplayDescriptor? {
        displays().first(where: \.isMain)
    }

    private func preferredAgentDisplay(in displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        displays.first {
            $0.name.localizedCaseInsensitiveContains(Self.preferredDisplayName)
        }
    }
}

enum BetterDisplayError: LocalizedError {
    case unavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "BetterDisplay is not installed"
        case .commandFailed(let message): return message
        }
    }
}

final class BetterDisplayService {
    private struct IntegrationRequest: Encodable {
        let uuid: String
        let commands: [String]
        let parameters: [String: String]
    }

    private let bundleURL = URL(fileURLWithPath: "/Applications/BetterDisplay.app", isDirectory: true)
    private let bundleIdentifier = "pro.betterdisplay.BetterDisplay"
    private let requestNotification = Notification.Name("pro.betterdisplay.BetterDisplay.request")

    static let createAgentScreenParameters = [
        "type": "VirtualScreen",
        "virtualScreenName": DisplayService.preferredDisplayName,
        "aspectWidth": "16",
        "aspectHeight": "10",
        "virtualScreenHiDPI": "on"
    ]

    static let connectAgentScreenParameters = [
        "name": DisplayService.preferredDisplayName,
        "connected": "on"
    ]

    static let disconnectAgentScreenParameters = [
        "name": DisplayService.preferredDisplayName,
        "connected": "off"
    ]

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: bundleURL.path)
    }

    func openDownloadPage() {
        guard let url = URL(string: "https://github.com/waydabber/BetterDisplay/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }

    func createAgentScreen() async throws {
        guard isInstalled else { throw BetterDisplayError.unavailable }
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
            try? await Task.sleep(for: .seconds(2))
        }

        try sendIntegrationRequest(commands: ["set"], parameters: Self.connectAgentScreenParameters)
        try? await Task.sleep(for: .seconds(1.5))
        if DisplayService().agentDisplay() != nil { return }

        try sendIntegrationRequest(commands: ["create"], parameters: Self.createAgentScreenParameters)
        try? await Task.sleep(for: .seconds(1))
        try sendIntegrationRequest(commands: ["set"], parameters: Self.connectAgentScreenParameters)
    }

    func disconnectAgentScreen() async throws {
        guard isInstalled else { throw BetterDisplayError.unavailable }
        guard DisplayService().preferredAgentDisplay() != nil else { return }
        try sendIntegrationRequest(commands: ["set"], parameters: Self.disconnectAgentScreenParameters)
        try? await Task.sleep(for: .milliseconds(800))
    }

    private func sendIntegrationRequest(commands: [String], parameters: [String: String]) throws {
        let request = IntegrationRequest(
            uuid: UUID().uuidString,
            commands: commands,
            parameters: parameters
        )
        let data = try JSONEncoder().encode(request)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw BetterDisplayError.commandFailed("Could not encode the BetterDisplay request")
        }
        DistributedNotificationCenter.default().postNotificationName(
            requestNotification,
            object: encoded,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
