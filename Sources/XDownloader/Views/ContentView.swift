import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var manager: DownloadManager
    @State private var urlInput: String = ""
    @State private var isHoveringDrop = false
    @State private var showInstallSheet = false
    @State private var bannerDismissed = false
    @FocusState private var isInputFocused: Bool

    private var showBanner: Bool {
        !manager.missingTools.isEmpty && !bannerDismissed
    }

    var body: some View {
        VStack(spacing: 0) {
            if showBanner {
                RequirementsBannerView(
                    tools: manager.missingTools,
                    onSetup: { showInstallSheet = true },
                    onDismiss: { bannerDismissed = true }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            urlInputSection
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()
                .opacity(0.5)

            if manager.items.isEmpty {
                emptyState
            } else {
                downloadList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showInstallSheet, onDismiss: { bannerDismissed = manager.missingTools.isEmpty }) {
            InstallToolsSheet(tools: manager.missingTools)
                .environmentObject(manager)
        }
        .onDrop(of: [.plainText, .url], isTargeted: $isHoveringDrop) { providers in
            for provider in providers {
                // Prefer the URL representation; only fall back to plain text if a
                // URL isn't available — otherwise both handlers fire and the same
                // link gets queued twice.
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let u = url {
                            Task { @MainActor in manager.addDownload(urlString: u.absoluteString) }
                        }
                    }
                } else {
                    _ = provider.loadObject(ofClass: String.self) { str, _ in
                        if let s = str {
                            Task { @MainActor in manager.addDownload(urlString: s) }
                        }
                    }
                }
            }
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(Color.blue.opacity(0.5), lineWidth: isHoveringDrop ? 3 : 0)
                .animation(.easeInOut(duration: 0.2), value: isHoveringDrop)
        )
    }

    // MARK: - URL Input

    private var urlInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(urlInput.isEmpty ? .secondary : .blue)

                    TextField("Paste an X.com URL...", text: $urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isInputFocused)
                        .onSubmit { submitURL() }

                    if !urlInput.isEmpty {
                        Button { urlInput = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    isInputFocused ? Color.blue.opacity(0.6) : Color.primary.opacity(0.1),
                                    lineWidth: 1.5
                                )
                        )
                )
                .animation(.easeInOut(duration: 0.15), value: isInputFocused)

                Button(action: submitURL) {
                    Text("Download")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(urlInput.isEmpty ? Color.blue.opacity(0.4) : Color.blue)
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(urlInput.isEmpty)
            }

            HStack(spacing: 6) {
                Button(action: pasteFromClipboard) {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Text("·").foregroundColor(.secondary)

                Text("or drag & drop a URL here")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Download List

    private var downloadList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)

                Spacer()

                if manager.items.contains(where: { $0.status == .completed }) {
                    Button("Clear done") {
                        withAnimation(.easeOut(duration: 0.2)) { manager.clearCompleted() }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(manager.items) { item in
                        DownloadRowView(
                            item: item,
                            onReveal: { manager.revealInFinder(item) },
                            onRemove: {
                                withAnimation(.easeOut(duration: 0.2)) { manager.removeItem(item) }
                            },
                            onRetry:    { manager.retryItem(item) },
                            onCopyLink: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.url, forType: .string)
                            },
                            onOpen: { openFile(item) }
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom)
                )
                .symbolEffect(.pulse.byLayer)

            VStack(spacing: 6) {
                Text("No downloads yet")
                    .font(.system(size: 16, weight: .semibold))

                Text("Paste an X.com post URL above to\ndownload videos or images.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func submitURL() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            manager.addDownload(urlString: trimmed)
        }
        urlInput = ""
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        if manager.autoDownloadOnPaste {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                manager.addDownload(urlString: text)
            }
        } else {
            urlInput = text
            isInputFocused = true
        }
    }

    private func openFile(_ item: DownloadItem) {
        func exists(_ p: String?) -> Bool {
            guard let p else { return false }
            return FileManager.default.fileExists(atPath: p)
        }
        let path: String?
        if manager.openPreference == .audio {
            path = exists(item.audioPath) ? item.audioPath
                 : exists(item.videoPath) ? item.videoPath
                 : item.outputPath
        } else {
            path = exists(item.videoPath) ? item.videoPath
                 : exists(item.audioPath) ? item.audioPath
                 : item.outputPath
        }
        if let p = path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }
}
