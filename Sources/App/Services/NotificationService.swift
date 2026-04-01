import Foundation
import UserNotifications
import Core

@MainActor
public final class NotificationService {
    public static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()
    private let categoryIdentifier = "AGENT_DEV_PILOT_EVENT"

    private init() {}

    public func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted { registerCategories() }
            return granted
        } catch { return false }
    }

    public func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    public func post(_ notification: NotificationBatcher.Notification, playSound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = categoryIdentifier
        if playSound && notification.event?.attentionTier == .action {
            content.sound = .default
        }
        content.userInfo = [
            "sessionId": notification.sessionId,
            "isBatched": notification.isBatched,
            "isSummary": notification.isSummary
        ]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    private func registerCategories() {
        let openTerminal = UNNotificationAction(
            identifier: "OPEN_TERMINAL",
            title: "Open Terminal",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [openTerminal],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }
}
