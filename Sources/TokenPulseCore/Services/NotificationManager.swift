import Foundation
import UserNotifications

public final class NotificationManager: @unchecked Sendable {
    public static let shared = NotificationManager()

    private var canUseUserNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private init() {}

    public func requestAuthorization() async -> Bool {
        guard canUseUserNotifications else { return false }
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    public func sendAlert(_ alert: SurplusAlert) async {
        await deliverNotification(id: alert.id, title: alert.title, body: alert.body)
    }

    public func sendTestNotification() async {
        await deliverNotification(
            id: "tokenpulse-test-\(UUID().uuidString)",
            title: "TokenPulse Surplus Alert",
            body: "Claude still has 78% of its 7d Weekly quota left (resets in 14h). Great time to put those tokens to work!"
        )
    }

    private func deliverNotification(id: String, title: String, body: String) async {
        if canUseUserNotifications {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = await requestAuthorization()
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            do {
                try await center.add(request)
                return
            } catch {
                // Fall back to osascript below if UNUserNotificationCenter fails
            }
        }

        // Fallback via AppleScript display notification for swift run / unbundled execution
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
