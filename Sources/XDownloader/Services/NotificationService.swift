import AppKit
import UserNotifications

/// Posts a user notification when a download reaches a terminal state while
/// the app is in the background, so a queued-and-forgotten download announces
/// itself. Per-app delivery (banners, sounds, off) stays under the user's
/// control in System Settings → Notifications.
///
/// Every entry point no-ops when the process is not running from a real .app
/// bundle: UNUserNotificationCenter requires a bundle identifier and traps
/// without one (`swift run` executes the bare SPM binary).
@MainActor
enum NotificationService {
    private static var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }
    private static var authorizationRequested = false

    /// Ask for permission lazily on the first enqueue — the user has just
    /// interacted with the app, which is the moment the prompt makes sense
    /// (never at launch).
    static func requestAuthorizationIfNeeded() {
        guard hasBundle, !authorizationRequested else { return }
        authorizationRequested = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Announce a finished download. Skipped while the app is frontmost —
    /// the row's status badge is already visible.
    static func downloadFinished(_ item: DownloadItem) {
        guard hasBundle, !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        switch item.status {
        case .completed:
            content.title = "Download complete"
        case .failed(let message):
            content.title = "Download failed"
            content.subtitle = message
        default:
            return  // not a terminal state — nothing to announce
        }
        content.body = item.title ?? item.url
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
