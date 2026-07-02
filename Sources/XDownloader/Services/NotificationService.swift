import AppKit

// UNUserNotificationCenter/UNNotificationRequest predate Sendable; their
// completion handlers are safe here (no shared mutable state is captured).
@preconcurrency import UserNotifications

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

    /// Announce a finished download. Skipped while the app is frontmost —
    /// the row's status badge is already visible.
    ///
    /// Permission is requested lazily on the FIRST finished download — the
    /// first moment a notification could matter, and safely clear of capture
    /// time, where the macOS 15.4+ pasteboard consent prompt may already be
    /// on screen. The request chains into delivery, so even that first
    /// notification arrives once the user grants.
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
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            case .authorized, .provisional:
                center.add(request)
            default:
                break  // denied — the user said no, respect it silently
            }
        }
    }
}
