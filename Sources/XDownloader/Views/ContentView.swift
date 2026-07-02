import AppKit
import SwiftUI

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all, downloading, queued, completed, failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .downloading: return "Downloading"
        case .queued: return "Queued"
        case .completed: return "Done"
        case .failed: return "Failed"
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
        case .queued: if case .queued = status { return true } else { return false }
        case .completed: if case .completed = status { return true } else { return false }
        case .failed: if case .failed = status { return true } else { return false }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var urlInput: String = ""
    @State private var isHoveringDrop = false
    @State private var showInstallSheet = false
    @State private var bannerDismissed = false
    @State private var statusFilter: DownloadFilter = .all
    /// "Already in your list": the row to scroll to and pulse.
    @State private var scrollTarget: UUID?
    @State private var pulseID: UUID?
    @State private var pulseVisible = false
    @State private var pulseTask: Task<Void, Never>?
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
        .onChange(of: manager.captureFeedback) { _, feedback in
            guard let feedback else { return }
            // The status line must never lie: if it says "Queued 3", the list
            // has to show them — so a successful capture resets the filter.
            if feedback.kind == .success || feedback.highlightItemID != nil {
                statusFilter = .all
            }
            if let id = feedback.highlightItemID {
                scrollTarget = id
                if !reduceMotion { pulse(id) }
            }
            AccessibilityNotification.Announcement(feedback.message).post()
        }
        .sheet(isPresented: $showInstallSheet, onDismiss: { bannerDismissed = manager.missingTools.isEmpty }) {
            InstallToolsSheet(tools: manager.missingTools)
                .environmentObject(manager)
        }
        .onDrop(of: [.plainText, .url], isTargeted: $isHoveringDrop) { providers in
            // Collect every provider first so one drop gesture is ONE capture —
            // one status line, one merged duplicate dialog — instead of N.
            Task { @MainActor in
                var tokens: [String] = []
                for provider in providers {
                    // Prefer the URL representation; only fall back to plain
                    // text if a URL isn't available — otherwise both handlers
                    // fire and the same link gets queued twice.
                    if provider.canLoadObject(ofClass: URL.self) {
                        if let url = await loadDropped(URL.self, from: provider) {
                            tokens.append(url.absoluteString)
                        }
                    } else if let text = await loadDropped(String.self, from: provider) {
                        tokens.append(text)
                    }
                }
                guard !tokens.isEmpty else { return }
                manager.capture(text: tokens.joined(separator: "\n"), source: .drop)
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
                get: { manager.pendingDuplicates != nil },
                set: { if !$0 { manager.dismissDuplicates() } }
            ),
            presenting: manager.pendingDuplicates
        ) { batch in
            if let dup = batch.single {
                Button("Cancel", role: .cancel) { manager.dismissDuplicates() }
                if dup.priorFileExists {
                    Button("Show in Finder") { manager.revealDuplicatePriorFile(dup) }
                }
                Button("Download again") { manager.confirmDuplicateDownloads(batch) }
            } else {
                Button("Skip All", role: .cancel) { manager.dismissDuplicates() }
                Button("Download All Again") { manager.confirmDuplicateDownloads(batch) }
            }
        } message: { batch in
            Text(duplicateMessage(batch))
        }
    }

    private func duplicateMessage(_ batch: DuplicateBatch) -> String {
        guard let dup = batch.single else {
            return "\(batch.confirmations.count) of these links are already in your download history."
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(urlInput.isEmpty ? .secondary : .blue)

                    TextField("Type or paste a URL...", text: $urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isInputFocused)
                        .onSubmit { submitURL() }

                    if !urlInput.isEmpty {
                        Button {
                            urlInput = ""
                        } label: {
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

                captureButton
            }

            statusLine
        }
    }

    /// The hero button: one fixed-width slot whose label always tells the
    /// truth. Empty field → "Paste & Download" reads the clipboard and
    /// downloads; field has text → the same slot morphs to "Download".
    /// Deliberately NOT the window's default button — Enter on an empty
    /// field must never trigger a clipboard read.
    private var captureButton: some View {
        Button {
            if urlInput.isEmpty {
                manager.captureFromClipboard()
            } else {
                submitURL()
            }
        } label: {
            HStack(spacing: 6) {
                if urlInput.isEmpty {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(urlInput.isEmpty ? "Paste & Download" : "Download")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(width: 150)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue))
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .help(
            urlInput.isEmpty
                ? "Download the link(s) on the clipboard"
                : "Download this link")
    }

    /// Fixed-height feedback slot under the capture row — messages fade in
    /// place and never push the layout (unlike the old orange banner).
    private var statusLine: some View {
        HStack(spacing: 6) {
            if let feedback = manager.captureFeedback {
                Image(systemName: feedbackSymbol(feedback))
                    .font(.system(size: 11))
                Text(feedback.message)
                    .lineLimit(1)
                if feedback.offersPrivacySettings {
                    Button("Open System Settings") { manager.openPasteboardPrivacySettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                        )
                        .foregroundColor(.primary)
                }
            } else {
                Text("Drop links anywhere · multiple links OK")
            }
        }
        .font(.system(size: 12))
        .foregroundColor(manager.captureFeedback.map(feedbackColor) ?? .secondary)
        .frame(height: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private func feedbackSymbol(_ feedback: CaptureFeedback) -> String {
        if feedback.offersPrivacySettings { return "nosign" }
        switch feedback.kind {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func feedbackColor(_ feedback: CaptureFeedback) -> Color {
        switch feedback.kind {
        case .success: return .green
        case .info: return .blue
        case .warning: return .orange
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filtered) { item in
                                DownloadRowView(
                                    item: item,
                                    onReveal: { manager.revealInFinder(item) },
                                    onRemove: {
                                        withAnimation(.easeOut(duration: 0.2)) { manager.removeItem(item) }
                                    },
                                    onRetry: { manager.retryItem(item) },
                                    onCopyLink: {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(item.url, forType: .string)
                                    },
                                    onOpen: { openFile(item) },
                                    onPause: { manager.pauseItem(item) },
                                    onResume: { manager.resumeItem(item) }
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.blue, lineWidth: 2)
                                        .opacity(pulseID == item.id && pulseVisible ? 1 : 0)
                                )
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    // initial: true — when the highlight lands while a filter
                    // shows the empty state, this ScrollViewReader is inserted
                    // in the same render pass that sets scrollTarget, and a
                    // plain onChange would never fire for it.
                    .onChange(of: scrollTarget, initial: true) { _, target in
                        guard let target else { return }
                        // No scroll animation — the pulse is the attention cue.
                        proxy.scrollTo(target, anchor: .center)
                        scrollTarget = nil
                    }
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

                Text("Paste a link above to download\nvideos or images.")
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
        let result = manager.capture(text: trimmed, source: .field)
        // Clear only once the text actually landed (queued, or already in the
        // list). "No link" keeps it for fixing in place; a pending duplicate
        // confirmation keeps it so Cancel doesn't swallow the URL.
        if result.queued > 0 || result.alreadyPresent > 0 { urlInput = "" }
    }

    private func loadDropped(_ type: URL.Type, from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private func loadDropped(_ type: String.Type, from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
    }

    /// Pulse the row's border twice, then clear. Skipped entirely under
    /// Reduce Motion (the scroll-to still happens). A newer pulse cancels the
    /// older task so two never fight over the shared blink state.
    private func pulse(_ id: UUID) {
        pulseTask?.cancel()
        pulseID = id
        pulseVisible = false
        pulseTask = Task { @MainActor in
            for _ in 0..<2 {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { pulseVisible = true }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { pulseVisible = false }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if !Task.isCancelled, pulseID == id { pulseID = nil }
        }
    }

    private func openFile(_ item: DownloadItem) {
        func exists(_ p: String?) -> Bool {
            guard let p else { return false }
            return FileManager.default.fileExists(atPath: p)
        }
        let path: String?
        if manager.openPreference == .audio {
            path =
                exists(item.audioPath)
                ? item.audioPath
                : exists(item.videoPath)
                    ? item.videoPath
                    : item.outputPath
        } else {
            path =
                exists(item.videoPath)
                ? item.videoPath
                : exists(item.audioPath)
                    ? item.audioPath
                    : item.outputPath
        }
        guard let p = path else { return }
        let url = URL(fileURLWithPath: p)

        if (item.imageCount ?? 0) > 1 {
            let siblings = siblingImageURLs(forImageAt: url)
            if siblings.count > 1,
                let appURL = NSWorkspace.shared.urlForApplication(toOpen: url)
            {
                NSWorkspace.shared.open(
                    siblings,
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
        let imageExts = MediaExtensions.image

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
