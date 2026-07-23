import AppKit
import SwiftUI

/// The status item itself: download-arrow template icon, a live count of
/// unfinished items ("9+" capped), and a warning triangle while failures are
/// unseen — attention by shape, never color.
struct MenuBarLabelView: View {
    @ObservedObject var manager: DownloadManager

    var body: some View {
        composedLabel(manager.menuBarState)
    }

    /// One interpolated Text keeps icon/count/⚠ on a shared baseline — the
    /// system renders it monochrome (template) in the menu bar automatically.
    private func composedLabel(_ state: MenuBarState) -> Text {
        var label = Text(Image(systemName: "arrow.down.circle"))
        if let count = state.countLabel {
            label = label + Text(" \(count)").monospacedDigit()
        }
        if state.showsAttention {
            label = label + Text(" ") + Text(Image(systemName: "exclamationmark.triangle"))
        }
        return label
    }
}

/// Time Machine-style status menu: verb first, then a dim aggregate, a few
/// live item rows, paused/failed summaries, and the app commands. No ⌘ hints
/// here by design — the status menu is a glance surface, not a shortcut sheet.
struct MenuBarMenuView: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var updater: UpdaterViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let state = manager.menuBarState

        Button("Paste and Download") {
            let result = manager.captureFromClipboard()
            // Warnings, "already in your list", and duplicate confirmations
            // all render in the main window — raise it unless links quietly
            // queued (there, the ticking count IS the feedback).
            let quietSuccess = (result?.queued ?? 0) > 0 && (result?.toConfirm ?? 0) == 0
            if !quietSuccess { openMainWindow() }
        }

        if state.unfinishedCount > 0 {
            Divider()
            Text(aggregateLine(state))
            ForEach(state.rows) { row in
                Button(shortTitle(row.title)) { openMainWindow() }
                    .badge(badgeText(row))
            }
            if state.overflowCount > 0 {
                Button("\(state.overflowCount) more…") { openMainWindow() }
            }
        }

        if state.pausedCount > 0 {
            Text("\(state.pausedCount) paused")
        }

        if state.failedCount > 0 {
            Divider()
            // Opening the window from here counts as seeing the failures.
            Button(failureLine(state)) {
                manager.markFailuresSeen()
                openMainWindow()
            }
            Button("Retry All Failed") { manager.retryAllFailed() }
        }

        Divider()
        // Present only while an update is actually known — no update, no row.
        if let version = updater.availableVersion {
            Button("Update Available (\(version))…") {
                NSApp.activate(ignoringOtherApps: true)
                updater.checkForUpdates()
            }
        }
        Button("Open XDownloader") { openMainWindow() }
        // Not SettingsLink: it opens the window without activating the app,
        // leaving Settings behind whatever is frontmost.
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        Divider()
        Button("Quit XDownloader") { NSApp.terminate(nil) }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func aggregateLine(_ state: MenuBarState) -> String {
        var parts: [String] = []
        if state.downloadingCount > 0 { parts.append("\(state.downloadingCount) downloading") }
        if state.queuedCount > 0 { parts.append("\(state.queuedCount) queued") }
        if let speed = state.aggregateSpeed { parts.append(speed) }
        return parts.joined(separator: " · ")
    }

    private func failureLine(_ state: MenuBarState) -> String {
        var line = "⚠ \(state.failedCount) failed"
        if let message = state.firstFailureMessage {
            line += " — \(String(message.prefix(40)))"
        }
        return line
    }

    private func badgeText(_ row: MenuBarState.Row) -> String {
        switch row.detail {
        case .downloading(let percent?): return "\(percent)%"
        case .downloading(nil): return "downloading"
        case .fetching: return "fetching…"  // never a misleading 0%
        case .queued: return "queued"
        }
    }

    private func shortTitle(_ title: String) -> String {
        title.count > 50 ? String(title.prefix(50)) + "…" : title
    }
}
