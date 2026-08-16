import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var manager: DownloadManager
    @EnvironmentObject var updater: UpdaterViewModel
    @State private var showClearHistoryConfirm = false
    @State private var lastImportMessage: String?

    var body: some View {
        Form {
            Section("Download Location") {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 16))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(manager.outputDirectory.lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(manager.outputDirectory.path)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Change…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.title = "Choose Download Folder"
                        panel.prompt = "Select"
                        if panel.runModal() == .OK, let url = panel.url {
                            manager.outputDirectory = url
                            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            manager.saveSettings()
                        }
                    }
                }

                Button("Open in Finder") { manager.openDownloadsFolder() }
                    .foregroundColor(.secondary)
            }

            Section("Cookies") {
                Picker("Browser", selection: $manager.cookieBrowser) {
                    ForEach(CookieBrowser.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                if !manager.availableCookieBrowserProfiles.isEmpty {
                    Picker("Profile", selection: $manager.cookieBrowserProfile) {
                        ForEach(manager.availableCookieBrowserProfiles) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }

                    Text("Choose the browser profile where you are signed in to X.com.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(
                    "yt-dlp and gallery-dl use cookies from the selected browser to access your X.com session. Make sure you're logged in to X.com in that browser."
                )
                .font(.caption)
                .foregroundColor(.secondary)

                HStack {
                    if let path = manager.cookiesFilePath, !path.isEmpty {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                        Button("Clear") {
                            manager.clearCookiesFile()
                        }
                    } else {
                        Button("Choose cookies.txt...") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.text, .plainText]
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.prompt = "Choose"
                            if panel.runModal() == .OK, let url = panel.url {
                                manager.setCookiesFile(from: url)
                            }
                        }
                    }
                }

                Text(
                    "Direct browser access is recommended because it does not create a separate copy of your session. A Netscape-format cookies.txt remains available only as a fallback and takes precedence when selected."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section("X Likes Sync") {
                HStack {
                    TextField("@handle", text: $manager.twitterHandle)
                        .textFieldStyle(.roundedBorder)
                        .disabled(manager.likesSyncSnapshot.status.isActive)
                    Button("Verify") { manager.verifyLikesAccess() }
                        .disabled(
                            manager.twitterHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || manager.likesSyncSnapshot.status.isActive
                                || manager.likesAccessVerification == .verifying)
                }

                HStack(spacing: 6) {
                    switch manager.likesAccessVerification {
                    case .idle:
                        Image(systemName: "person.crop.circle")
                        Text("Enter the account whose Likes you want to sync.")
                    case .verifying:
                        ProgressView().controlSize(.small)
                        Text("Checking the selected X session…")
                    case .verified(let handle):
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Verified access for \(handle.displayName)")
                    case .noLikesVisible(let handle):
                        Image(systemName: "questionmark.circle.fill").foregroundColor(.orange)
                        Text(LikesAccessVerification.noLikesVisibleMessage(for: handle))
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(message)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Text(
                    "XDownloader never stores your X password or cookie contents. Sync is manual and downloads X-hosted images, videos, and GIFs; unliking a post never deletes local files."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section("Download Format") {
                Picker("Format", selection: $manager.youtubeFormat) {
                    ForEach(YouTubeFormat.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                if manager.youtubeFormat == .audioOnly {
                    Picker("Quality", selection: $manager.audioQuality) {
                        ForEach(AudioQuality.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Picker("Quality", selection: $manager.videoQuality) {
                        ForEach(VideoQuality.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Picker("Subtitles", selection: $manager.subtitleLanguage) {
                        ForEach(SubtitleLanguage.allCases) { Text($0.displayName).tag($0) }
                    }

                    if manager.subtitleLanguage != .none {
                        Toggle("Embed subtitles in video file", isOn: $manager.embedSubtitles)
                        if !manager.embedSubtitles {
                            Text("Subtitle file will be saved alongside the video.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Text("Format and quality apply to all downloads. Subtitle settings apply to YouTube URLs only.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Concurrency") {
                HStack {
                    Text("Max simultaneous downloads")
                    Spacer()
                    Stepper("\(manager.maxConcurrent)", value: $manager.maxConcurrent, in: 1...5)
                }
            }

            Section("History") {
                Toggle("Save download history to database", isOn: $manager.saveHistoryEnabled)
                Text(
                    "Records completed and failed downloads to a local SQLite file. When enabled, you'll be warned before re-downloading a link that's already in your history."
                )
                .font(.caption)
                .foregroundColor(.secondary)

                if manager.saveHistoryEnabled {
                    HStack(spacing: 6) {
                        Text("\(manager.historyCount) \(manager.historyCount == 1 ? "download" : "downloads") on file")
                        Text("·").foregroundColor(.secondary)
                        Text(Self.formatSize(manager.historySizeBytes))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .font(.system(size: 12))

                    HStack {
                        Button("Reveal in Finder") { manager.revealHistoryFile() }
                        Spacer()
                        Button("Clear History…") { showClearHistoryConfirm = true }
                            .foregroundColor(manager.historyCount == 0 ? .secondary : .red)
                            .disabled(manager.historyCount == 0)
                    }

                    Divider().padding(.vertical, 2)

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import current task list")
                                .font(.system(size: 13))
                            Text("Adds the completed and failed items already in your task list to the database. Safe to run more than once.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button("Import \(manager.importableTaskCount)") {
                            let n = manager.importTaskListToHistory()
                            lastImportMessage =
                                n == 0
                                ? "Nothing to import."
                                : "Imported \(n) \(n == 1 ? "entry" : "entries")."
                        }
                        .disabled(manager.importableTaskCount == 0)
                    }
                    if let msg = lastImportMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .confirmationDialog(
                "Delete all history?",
                isPresented: $showClearHistoryConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete \(manager.historyCount) \(manager.historyCount == 1 ? "entry" : "entries")", role: .destructive) {
                    manager.clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only deletes the history records — your downloaded files stay where they are.")
            }

            Section("Display") {
                Toggle("Show XDownloader in menu bar", isOn: $manager.showMenuBarExtra)
                Text("A live count of active downloads next to the icon; failures raise a small warning triangle.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Show download date & time", isOn: $manager.showDownloadDate)

                Picker("Open completed file as", selection: $manager.openPreference) {
                    ForEach(OpenPreference.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(
                    "\"Audio\" opens the audio stream when available (e.g. Audio Only downloads). Falls back to the video file if the audio file no longer exists."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            UpdatesSettingsSection(updater: updater)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onChange(of: manager.cookieBrowser) { manager.cookieBrowserChanged() }
        .onChange(of: manager.cookieBrowserProfile) { manager.cookieBrowserProfileChanged() }
        .onChange(of: manager.cookiesFilePath) { manager.saveSettings() }
        .onChange(of: manager.twitterHandle) {
            manager.likesHandleChanged()
            manager.saveSettings()
        }
        .onChange(of: manager.maxConcurrent) { manager.saveSettings() }
        .onChange(of: manager.youtubeFormat) { manager.saveSettings() }
        .onChange(of: manager.videoQuality) { manager.saveSettings() }
        .onChange(of: manager.audioQuality) { manager.saveSettings() }
        .onChange(of: manager.subtitleLanguage) { manager.saveSettings() }
        .onChange(of: manager.embedSubtitles) { manager.saveSettings() }
        .onChange(of: manager.showDownloadDate) { manager.saveSettings() }
        .onChange(of: manager.showMenuBarExtra) { manager.saveSettings() }
        .onChange(of: manager.openPreference) { manager.saveSettings() }
        .onChange(of: manager.saveHistoryEnabled) {
            manager.saveSettings()
            manager.refreshHistoryStats()
        }
        .onAppear { manager.refreshHistoryStats() }
    }

    private static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Its own view (not inline in SettingsView.body) — the grouped Form is at the
/// edge of what the type checker handles in one expression.
private struct UpdatesSettingsSection: View {
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        Section("Updates") {
            if updater.isEnabled, let version = UpdaterViewModel.installedVersion {
                versionRow(
                    title: "XDownloader \(version)",
                    detail: statusLine,
                    checkEnabled: updater.canCheckForUpdates
                )
                Toggle("Check for updates automatically", isOn: autoUpdateBinding)
                Text("Checks GitHub once a day. Updates are never installed without your click.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                versionRow(
                    title: "XDownloader (development build)",
                    detail: "Version 0.0.0 — not a tagged release",
                    checkEnabled: false
                )
                Text("Update checks work only in tagged release builds installed as an app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func versionRow(title: String, detail: String, checkEnabled: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            Button("Check Now") { updater.checkForUpdates() }
                .disabled(!checkEnabled)
        }
    }

    private var statusLine: String {
        if let available = updater.availableVersion {
            return "Version \(available) available"
        }
        if let last = updater.lastCheckDate {
            let relative = Self.relativeDateFormatter.localizedString(for: last, relativeTo: Date())
            return "Last checked \(relative)"
        }
        return "Checks daily in the background"
    }

    /// Sparkle owns this preference, so it can't be a plain @Published binding.
    private var autoUpdateBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }
        )
    }

    private static let relativeDateFormatter = RelativeDateTimeFormatter()
}
