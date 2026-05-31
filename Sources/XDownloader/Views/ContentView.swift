import SwiftUI
import AppKit

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all, downloading, queued, completed, failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:         return "All"
        case .downloading: return "Downloading"
        case .queued:      return "Queued"
        case .completed:   return "Done"
        case .failed:      return "Failed"
        }
    }

    func matches(_ status: DownloadStatus) -> Bool {
        switch self {
        case .all: return true
        case .downloading:
            switch status {
            case .downloading, .fetching, .paused: return true
            default: return false
            }
        case .queued:    if case .queued    = status { return true } else { return false }
        case .completed: if case .completed = status { return true } else { return false }
        case .failed:    if case .failed    = status { return true } else { return false }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var manager: DownloadManager
    @State private var urlInput: String = ""
    @State private var isHoveringDrop = false
    @State private var showInstallSheet = false
    @State private var bannerDismissed = false
    @State private var statusFilter: DownloadFilter = .all
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
        .alert(
            "Already downloaded",
            isPresented: Binding(
                get: { manager.pendingDuplicate != nil },
                set: { if !$0 { manager.dismissDuplicate() } }
            ),
            presenting: manager.pendingDuplicate
        ) { dup in
            Button("Cancel", role: .cancel) { manager.dismissDuplicate() }
            if dup.priorFileExists {
                Button("Show in Finder") { manager.revealDuplicatePriorFile() }
            }
            Button("Download again") { manager.confirmDuplicateDownload() }
        } message: { dup in
            Text(duplicateMessage(dup))
        }
    }

    private func duplicateMessage(_ dup: DuplicateConfirmation) -> String {
        let dateStr = dup.priorEntry.finishedAt.formatted(date: .abbreviated, time: .shortened)
        var lines = ["You downloaded this link on \(dateStr)."]
        if let path = dup.priorEntry.outputPath {
            lines.append("")
            lines.append("Saved to: \(path)")
            if !dup.priorFileExists {
                lines.append("⚠ The file is no longer at that location.")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - URL Input

    private var urlInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = manager.notice {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

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
        let filtered = manager.items.filter { statusFilter.matches($0.status) }
        return VStack(spacing: 0) {
            filterBar
                .padding(.top, 12)
                .padding(.bottom, 8)

            if filtered.isEmpty {
                emptyFilterState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { item in
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
                                onOpen:   { openFile(item) },
                                onPause:  { manager.pauseItem(item) },
                                onResume: { manager.resumeItem(item) }
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
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(DownloadFilter.allCases) { filter in
                        filterPill(filter)
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 0)

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
    }

    private func filterPill(_ filter: DownloadFilter) -> some View {
        let count = manager.items.lazy.filter { filter.matches($0.status) }.count
        let isSelected = statusFilter == filter
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { statusFilter = filter }
        } label: {
            HStack(spacing: 5) {
                Text(filter.label)
                    .font(.system(size: 11, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(isSelected ? Color.white.opacity(0.25) : Color.primary.opacity(0.08))
                    )
            }
            .foregroundColor(isSelected ? .white : .primary.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isSelected ? Color.blue : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.clear : Color.primary.opacity(0.08),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyFilterState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.secondary)
            Text("No downloads match this filter")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
        let before = manager.items.count
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            manager.addDownload(urlString: trimmed)
        }
        if manager.items.count > before { urlInput = "" }
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
        guard let p = path else { return }
        let url = URL(fileURLWithPath: p)

        if (item.imageCount ?? 0) > 1 {
            let siblings = siblingImageURLs(forImageAt: url)
            if siblings.count > 1,
               let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
                NSWorkspace.shared.open(siblings,
                                        withApplicationAt: appURL,
                                        configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    /// Given any one image file from a gallery-dl multi-image download
    /// (named like `prefix #N.ext`), return all sibling images in number order.
    private func siblingImageURLs(forImageAt url: URL) -> [URL] {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let range = stem.range(of: #" #\d+$"#, options: .regularExpression) else {
            return [url]
        }
        let prefix = String(stem[..<range.lowerBound]) + " #"
        let dir = url.deletingLastPathComponent()
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif"]

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return [url]
        }
        let matches: [(Int, URL)] = entries.compactMap { name in
            let nameURL = URL(fileURLWithPath: name)
            guard imageExts.contains(nameURL.pathExtension.lowercased()) else { return nil }
            let s = nameURL.deletingPathExtension().lastPathComponent
            guard s.hasPrefix(prefix), let n = Int(s.dropFirst(prefix.count)) else { return nil }
            return (n, dir.appendingPathComponent(name))
        }
        return matches.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}
