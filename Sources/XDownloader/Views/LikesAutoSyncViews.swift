import SwiftUI

/// The automatic-sync rows of Settings → X Likes Sync. Its own view so the
/// grouped Form in SettingsView stays within what the type checker handles.
struct LikesAutoSyncSettingsRows: View {
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        Group {
            Toggle("Automatically sync new Likes", isOn: $manager.likesAutoSyncEnabled)
            Picker("Check every", selection: $manager.likesAutoSyncInterval) {
                ForEach(LikesAutoSyncInterval.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(!manager.likesAutoSyncEnabled)

            if manager.likesAutoSyncEnabled, let reason = manager.likesAutoSyncStatus.pauseReason {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill").foregroundColor(.orange)
                    Text(reason.message)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Text(
                "While XDownloader is running, it checks the newest Likes on this schedule and downloads anything not saved yet. A check stops at already-saved media, so it is light on your X login; Sync Likes still scans everything."
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .onChange(of: manager.likesAutoSyncEnabled) { manager.likesAutoSyncSettingsChanged() }
        .onChange(of: manager.likesAutoSyncInterval) { manager.likesAutoSyncSettingsChanged() }
    }
}

/// One line on the Likes card while automatic sync is on: the interval, the
/// last and next check, or why it is paused.
struct LikesAutoSyncStatusLine: View {
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        if manager.likesAutoSyncEnabled {
            HStack(spacing: 5) {
                Image(systemName: status.pauseReason == nil ? "arrow.triangle.2.circlepath" : "pause.circle")
                    .foregroundColor(status.pauseReason == nil ? .secondary : .orange)
                text
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
    }

    private var status: LikesAutoSyncStatus { manager.likesAutoSyncStatus }

    private var text: Text {
        if let reason = status.pauseReason { return Text(reason.message) }
        var line = Text("Auto-sync every \(manager.likesAutoSyncInterval.displayName)")
        if status.backoffLevel > 0 { line = line + Text(" (slowed down after errors)") }
        if let last = status.lastCheckAt {
            line = line + Text(" · last checked ") + Text(last, style: .time)
        }
        if let next = status.nextCheckAt {
            line = line + Text(" · next ") + Text(next, style: .time)
        } else if manager.likesSyncSnapshot.status.isActive {
            line = line + Text(" · checking now")
        }
        return line
    }
}
