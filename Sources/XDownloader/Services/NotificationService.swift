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

    /// Set by the link check, whose test downloads are nobody's news.
    static var isMuted = false

    /// Announce a finished download. Skipped while the app is frontmost —
    /// the row's status badge is already visible.
    ///
    /// Permission is requested lazily on the FIRST finished download — the
    /// first moment a notification could matter, and safely clear of capture
    /// time, where the macOS 15.4+ pasteboard consent prompt may already be
    /// on screen. The request chains into delivery, so even that first
    /// notification arrives once the user grants.
    static func downloadFinished(_ item: DownloadItem) {
        // No application object (a test host has a bundle identifier but
        // never starts one): nobody to notify, and `NSApp` must not be
        // unwrapped.
        guard hasBundle, !isMuted, let app = NSApp, !app.isActive else { return }

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

        deliver(
            UNNotificationRequest(
                identifier: item.id.uuidString, content: content, trigger: nil))
    }

    /// Announce what an automatic Likes sync run found: new media, new
    /// failed items, or a pause that needs the user. The caller decides
    /// whether the run is worth announcing at all; an automatic run with
    /// nothing new stays silent. Same rules as `downloadFinished`: skipped
    /// while the app is frontmost (the Likes card shows the result).
    static func likesAutoSyncFinished(title: String, body: String) {
        guard hasBundle, !isMuted, let app = NSApp, !app.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // One identifier: a newer automatic-run notice replaces the older
        // one in Notification Center instead of stacking up.
        deliver(
            UNNotificationRequest(
                identifier: "likes-auto-sync", content: content, trigger: nil))
    }

    private static func deliver(_ request: UNNotificationRequest) {
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
