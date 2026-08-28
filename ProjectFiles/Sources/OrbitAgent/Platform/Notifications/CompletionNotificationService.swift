import AppKit
import Foundation
import UserNotifications

@MainActor
final class CompletionNotificationService {
    enum AuthorizationState: Equatable {
        case allowed
        case notDetermined
        case denied
    }

    struct Payload: Equatable {
        let title: String
        let body: String
    }

    nonisolated static let preferenceKey = "OrbitAgent.notifications.taskCompletion"
    nonisolated static let maximumBodyLength = 240
    nonisolated static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!

    nonisolated static func shouldDeliver(
        enabled: Bool,
        appIsActive: Bool,
        controllerWindowIsKey: Bool
    ) -> Bool {
        enabled && !appIsActive && !controllerWindowIsKey
    }

    nonisolated static func conciseBody(_ value: String) -> String {
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > maximumBodyLength else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maximumBodyLength - 1)
        return String(collapsed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    nonisolated static func payload(
        output: AgentTaskOutput?,
        completionMessage: String
    ) -> Payload {
        let hasVisibleOutput = output?.shouldShow == true &&
            output?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let title = hasVisibleOutput
            ? (output?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Task complete")
            : "Task complete"
        let rawBody = hasVisibleOutput ? (output?.content ?? completionMessage) : completionMessage
        return Payload(
            title: title.isEmpty ? "Task complete" : title,
            body: conciseBody(rawBody)
        )
    }

    nonisolated static func queueFinishedBody(completedCount: Int) -> String {
        completedCount == 1
            ? "The queued request is finished."
            : "All \(completedCount) queued requests are finished."
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
        } catch {
            return false
        }
    }

    func authorizationState() async -> AuthorizationState {
        let settings = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings {
                continuation.resume(returning: $0)
            }
        }
        return Self.authorizationState(for: settings.authorizationStatus)
    }

    nonisolated static func authorizationState(
        for status: UNAuthorizationStatus
    ) -> AuthorizationState {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .allowed
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    @discardableResult
    func openNotificationSettings() -> Bool {
        NSWorkspace.shared.open(Self.notificationSettingsURL)
    }

    func deliverSuccessfulCompletion(
        enabled: Bool,
        outputTitle: String,
        outputBody: String
    ) {
        let controllerWindowIsKey = Self.controllerWindowIsKey()
        guard Self.shouldDeliver(
            enabled: enabled,
            appIsActive: NSApp.isActive,
            controllerWindowIsKey: controllerWindowIsKey
        ) else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(TaskPilotIdentity.displayName) finished"
        content.subtitle = outputTitle
        content.body = Self.conciseBody(outputBody)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "orbit-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func deliverQueuedTaskFinished(
        enabled: Bool,
        title: String,
        body: String
    ) {
        guard Self.shouldDeliver(
            enabled: enabled,
            appIsActive: NSApp.isActive,
            controllerWindowIsKey: Self.controllerWindowIsKey()
        ) else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(TaskPilotIdentity.displayName) queue"
        content.subtitle = title
        content.body = Self.conciseBody(body)
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "orbit-queue-item-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    func deliverQueueFinished(
        enabled: Bool,
        completedCount: Int
    ) {
        guard completedCount > 0,
              Self.shouldDeliver(
                enabled: enabled,
                appIsActive: NSApp.isActive,
                controllerWindowIsKey: Self.controllerWindowIsKey()
              ) else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(TaskPilotIdentity.displayName) queue complete"
        content.body = Self.queueFinishedBody(completedCount: completedCount)
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "orbit-queue-finished-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    func deliverUserActionRequired(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(TaskPilotIdentity.displayName) needs you"
        content.subtitle = title
        content.body = Self.conciseBody(message)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "orbit-user-input-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        NSApp.requestUserAttention(.criticalRequest)
    }

    private static func controllerWindowIsKey() -> Bool {
        NSApp.windows.contains { window in
            window.isKeyWindow && [
                TaskPilotIdentity.displayName,
                TaskPilotIdentity.compatibilityAgentScreenName,
                TaskPilotIdentity.queueWindowTitle,
                TaskPilotIdentity.liveScreenWindowTitle
            ].contains(window.title)
        }
    }
}
