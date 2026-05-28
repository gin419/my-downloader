import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var manager: DownloadManager

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

                Button("Open in Finder") {
                    manager.openDownloadsFolder()
                }
                .foregroundColor(.secondary)
            }

            Section("Cookies") {
                Picker("Browser", selection: $manager.cookieBrowser) {
                    ForEach(CookieBrowser.allCases) { browser in
                        Text(browser.displayName).tag(browser)
                    }
                }
                .pickerStyle(.segmented)

                Text("yt-dlp will use cookies from the selected browser to access your X.com session. Make sure you're logged in to X.com in that browser.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Download Format") {
                Picker("Format", selection: $manager.youtubeFormat) {
                    ForEach(YouTubeFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)

                if manager.youtubeFormat != .audioOnly {
                    Picker("Subtitles", selection: $manager.subtitleLanguage) {
                        ForEach(SubtitleLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
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

                Text("Format applies to all downloads. Subtitle settings apply to YouTube URLs only.")
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

            Section("Behavior") {
                Toggle("Auto-download on clipboard paste", isOn: $manager.autoDownloadOnPaste)
                Text("When enabled, clicking \"Paste from Clipboard\" starts the download immediately without filling the URL field first.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Display") {
                Toggle("Show download date & time", isOn: $manager.showDownloadDate)

                Picker("Open completed file as", selection: $manager.openPreference) {
                    ForEach(OpenPreference.allCases) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
                Text("\"Audio\" opens the audio stream when available (e.g. Audio Only downloads). Falls back to the video file if the audio file no longer exists.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onChange(of: manager.cookieBrowser) { manager.saveSettings() }
        .onChange(of: manager.maxConcurrent) { manager.saveSettings() }
        .onChange(of: manager.youtubeFormat) { manager.saveSettings() }
        .onChange(of: manager.subtitleLanguage) { manager.saveSettings() }
        .onChange(of: manager.embedSubtitles) { manager.saveSettings() }
        .onChange(of: manager.showDownloadDate) { manager.saveSettings() }
        .onChange(of: manager.openPreference) { manager.saveSettings() }
        .onChange(of: manager.autoDownloadOnPaste) { manager.saveSettings() }
    }
}
