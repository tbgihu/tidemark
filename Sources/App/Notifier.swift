import AppKit
import UserNotifications

/// Posts meter notifications and reports whether macOS allows them.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Permission { case unknown, allowed, denied }

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    /// Set as early as possible at launch, as Apple requires, so a notification shows even while Tidemark is active.
    func install() { center.delegate = self }

    func permission() async -> Permission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        default: .unknown
        }
    }

    /// Asks once; afterwards macOS answers from the user's choice without asking.
    func request() async -> Permission {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await permission()
    }

    func post(title: String, body: String, account: String, meter: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = account
        // One per account and meter: a newer threshold replaces the older banner in Notification Center.
        let request = UNNotificationRequest(identifier: "\(account).\(meter)", content: content, trigger: nil)
        center.add(request)
    }

    /// Every notification of an account: its thread.
    func removeDelivered(account: String) {
        let center = center
        Task {
            let ids = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == account }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// System Settings → Notifications, at Tidemark's entry.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Paths.identifier)")!
        NSWorkspace.shared.open(url)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
}
