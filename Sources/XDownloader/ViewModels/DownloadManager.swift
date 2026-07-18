import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
class DownloadManager: ObservableObject {

    // MARK: - Published state

    @Published var items: [DownloadItem] = [] {
        didSet {
            resubscribeItemObservation()
            recomputeMenuBarState()
        }
    }
    @Published var outputDirectory: URL
    @Published var cookieBrowser: CookieBrowser = .safari
    @Published var cookiesFilePath: String? = nil  // display / last resolved path
    private let cookieAccess = CookieAccessManager()  // security-scoped bookmark + per-download scope for cookies.txt
    @Published var maxConcurrent: Int = 2
    @Published var showDownloadDate: Bool = false
    @Published var youtubeFormat: YouTubeFormat = .videoAndAudio
    @Published var videoQuality: VideoQuality = .best
    @Published var audioQuality: AudioQuality = .best
    @Published var subtitleLanguage: SubtitleLanguage = .none
    @Published var embedSubtitles: Bool = true
    @Published var openPreference: OpenPreference = .video
    @Published var saveHistoryEnabled: Bool = true
    @Published var historyCount: Int = 0
    @Published var historySizeBytes: Int64 = 0
    @Published var pendingDuplicates: DuplicateBatch? = nil
    @Published var missingTools: [ToolRequirement] = []
    /// Result of the most recent capture, shown in the window's fixed status
    /// line. Non-persistent feedback clears itself after a few seconds.
    @Published var captureFeedback: CaptureFeedback? = nil
    /// Menu bar visibility — bound to both the Settings toggle and
    /// MenuBarExtra's isInserted (⌘-dragging the icon out flips it too).
    @Published var showMenuBarExtra: Bool = true
    /// Everything the menu bar extra renders, recomputed as one value struct —
    /// the scene can't observe each DownloadItem individually.
    @Published private(set) var menuBarState = MenuBarState.empty

    // MARK: - Private state

    private var activeProcesses: [UUID: Process] = [:]
    /// In-flight FxTwitterService fallbacks — URLSession Tasks, so they need
    /// Task.cancel() rather than Process.terminate() when the user hits Stop.
    private var activeFxTasks: [UUID: Task<Bool, Never>] = [:]
    private var downloadQueue: [DownloadItem] = []
    /// Overflow behind `pendingDuplicates`: each capture's duplicates present
    /// as ONE alert; a second capture while it's up waits its turn here.
    private var duplicateBatchQueue: [DuplicateBatch] = []
    private var activeCount: Int = 0
    private var feedbackTask: Task<Void, Never>?
    /// IDs of items the user explicitly paused — distinguishes a user-initiated
    /// `terminate()` from a real download failure when the process exits.
    private var pausedItemIDs: Set<UUID> = []
    /// Attention contract: set when a download fails while the app is in the
    /// background; cleared when the app comes frontmost, on retry/remove, or
    /// via the menu's failure row — never by merely opening the menu.
    private var hasUnseenFailures = false
    /// One merged subscription to every item's objectWillChange, throttled —
    /// progress ticks arrive many times a second and the menu bar only needs
    /// a 0.5s cadence.
    private var itemObservation: AnyCancellable?
    private var mainWindowKeyObserver: AnyCancellable?
    /// IDs whose `runDownload` Task is still running (including fallbacks) —
    /// a transient `.failed` mid-chain must not be retryable into a second
    /// concurrent download of the same item.
    private var inFlightItemIDs: Set<UUID> = []
    private let history = HistoryStore()
    private let queueStore = QueueStore()
    private let settingsStore = SettingsStore()

    // Resolved at runtime via RequirementsService so paths stay in one place.
    private var ytdlpPath: String { RequirementsService.ytdlp.installedPath ?? "yt-dlp" }
    private var galleryDlPath: String? { RequirementsService.galleryDl.installedPath }

    // MARK: - Init

    init() {
        let downloads =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = downloads.appendingPathComponent("X-Videos")
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        self.outputDirectory = defaultDir

        loadSettings()
        loadQueue()
        checkRequirements()
        refreshHistoryStats()
        drainQueue()

        resubscribeItemObservation()
        recomputeMenuBarState()
        // Spec contract: the ⚠ clears when the MAIN WINDOW becomes key — not
        // on mere app activation (⌘-tabbing onto a windowless app shows the
        // user nothing) and never by just opening the status menu.
        mainWindowKeyObserver = NotificationCenter.default
            .publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] note in
                // AppKit posts window notifications on the main thread.
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow, Self.isMainWindow(window)
                    else { return }
                    self?.markFailuresSeen()
                }
            }
    }

    // No deinit cleanup needed: security-scoped access is started and stopped
    // per download by CookieFileScope (paired via defer), never held long-lived.

    func checkRequirements() {
        missingTools = RequirementsService.missingTools()
    }

    // MARK: - Menu bar state

    /// `items` is `@Published`, but each DownloadItem is its own
    /// ObservableObject — the menu bar scene would never hear a progress or
    /// status change without merging every item's objectWillChange. Rebuilt
    /// whenever the array itself changes.
    private func resubscribeItemObservation() {
        itemObservation = Publishers.MergeMany(items.map(\.objectWillChange))
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.recomputeMenuBarState() }
    }

    /// Cheap enough to call eagerly at every queue transition (add, pause,
    /// resume, retry, remove, finalize) — the throttled item subscription only
    /// covers the in-between progress ticks.
    private func recomputeMenuBarState() {
        let state = MenuBarState.compute(
            items: items,
            showsAttention: hasUnseenFailures,
            wasOverflowing: menuBarState.isOverflowing)
        if state != menuBarState { menuBarState = state }
    }

    func markFailuresSeen() {
        guard hasUnseenFailures else { return }
        hasUnseenFailures = false
        recomputeMenuBarState()
    }

    func retryAllFailed() {
        for item in items {
            if case .failed = item.status { retryItem(item) }
        }
    }

    /// SwiftUI's `Window(id: "main")` stamps its NSWindow identifier with the
    /// scene id (e.g. "main-AppWindow-1").
    private static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    /// True only when the main queue window is actually in front of the user.
    /// App-active alone isn't enough: the window can be closed, miniaturized,
    /// or on another Space while the app stays frontmost.
    private var isMainWindowShowing: Bool {
        guard NSApp.isActive else { return false }
        return NSApp.windows.contains { window in
            Self.isMainWindow(window)
                && window.isVisible
                && window.isOnActiveSpace
                && window.occlusionState.contains(.visible)
        }
    }

    // MARK: - Capture funnel

    /// Every way links enter the app — the URL field, the Paste & Download
    /// button, ⌘D, a drop — lands here, so feedback and duplicate handling
    /// behave identically everywhere. Non-URL text never reaches yt-dlp; it
    /// surfaces as status-line feedback instead of a doomed download item.
    @discardableResult
    func capture(text: String, source: CaptureSource) -> CaptureResult {
        var urls: [String] = []
        var seen: Set<String> = []
        for url in Self.extractURLs(from: text).map(Self.stripTrackingParams)
        where seen.insert(url).inserted {
            urls.append(url)
        }
        guard !urls.isEmpty else {
            showFeedback(CaptureFeedback(kind: .warning, message: source.noLinkMessage))
            return CaptureResult(queued: 0, alreadyPresent: 0, toConfirm: 0, foundLinks: false)
        }

        var queued = 0
        var alreadyPresent: [UUID] = []
        var confirmations: [DuplicateConfirmation] = []
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            for url in urls {
                switch add(urlString: url, skipHistoryCheck: false) {
                case .queued?:
                    queued += 1
                case .alreadyInList(let id)?:
                    alreadyPresent.append(id)
                case .needsConfirmation(let confirmation)?:
                    confirmations.append(confirmation)
                case nil:
                    break
                }
            }
        }

        if !confirmations.isEmpty {
            presentDuplicates(DuplicateBatch(confirmations: confirmations))
        }
        if let feedback = composeFeedback(
            queued: queued, alreadyPresent: alreadyPresent, toConfirm: confirmations.count)
        {
            showFeedback(feedback)
        }
        return CaptureResult(
            queued: queued, alreadyPresent: alreadyPresent.count,
            toConfirm: confirmations.count, foundLinks: true)
    }

    /// Reads the clipboard and funnels it through `capture`. The read happens
    /// only inside this explicit user action (Paste & Download button, ⌘D,
    /// menu bar) — never on a timer or focus change — so macOS 15.4+
    /// pasteboard-privacy prompts stay tied to a gesture the user just made.
    /// Returns nil when the read itself failed (feedback already shown) —
    /// callers without a visible window use this to decide to raise one.
    @discardableResult
    func captureFromClipboard() -> CaptureResult? {
        if #available(macOS 15.4, *), NSPasteboard.general.accessBehavior == .alwaysDeny {
            showFeedback(
                CaptureFeedback(
                    kind: .warning,
                    message: "Clipboard access is off — ⌘V into the field still works",
                    isPersistent: true,
                    offersPrivacySettings: true))
            return nil
        }
        guard
            let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else {
            // Never silent: an empty read gets named, whether the clipboard
            // is empty or holds something with no text representation.
            let hasContent = !(NSPasteboard.general.pasteboardItems?.isEmpty ?? true)
            showFeedback(
                CaptureFeedback(
                    kind: .warning,
                    message: hasContent ? "No link found in the clipboard" : "The clipboard is empty"))
            return nil
        }
        return capture(text: text, source: .clipboard)
    }

    /// What an `xdownloader://` URL asks for.
    enum SchemeCommand: Equatable {
        case download(String)  // decoded text holding one or more links
    }

    /// Grammar (for Shortcuts, Raycast, scripts):
    ///   xdownloader://download?url=<link>[&url=<link>…]  — queue links
    /// `urls=` is accepted as an alias, and the host-less form
    /// `xdownloader:download?…` works too. There is deliberately NO verb that
    /// reads the clipboard: any webpage can fire a scheme URL, and clipboard
    /// reads must stay tied to an in-app user gesture.
    nonisolated static func schemeCommand(from url: URL) -> SchemeCommand? {
        // URL.host/path disagree across macOS versions for the opaque
        // hostless form (xdownloader:download?…) — normalize the string to
        // hierarchical and let URLComponents (stable RFC 3986 parsing on
        // every OS) extract both the verb and the query.
        var s = url.absoluteString
        let prefix = "xdownloader:"
        guard s.lowercased().hasPrefix(prefix) else { return nil }
        s.removeFirst(prefix.count)
        if !s.hasPrefix("//") { s = "//" + s }
        guard let components = URLComponents(string: prefix + s) else { return nil }

        switch (components.host ?? "").lowercased() {
        case "download":
            // URLComponents hands values back percent-decoded. An empty text
            // still counts as a download command — capture() then answers
            // with the truthful "carried no link" feedback.
            let text = (components.queryItems ?? [])
                .filter { ["url", "urls"].contains($0.name.lowercased()) }
                .compactMap(\.value)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .download(text)
        default:
            return nil
        }
    }

    /// Entry point for xdownloader:// URLs (delivered via the app delegate).
    @discardableResult
    func handleSchemeURL(_ url: URL) -> CaptureResult? {
        switch Self.schemeCommand(from: url) {
        case .download(let text):
            return capture(text: text, source: .urlScheme)
        case nil:
            showFeedback(
                CaptureFeedback(kind: .warning, message: "Unrecognized xdownloader:// command"))
            return nil
        }
    }

    /// File menu "Import Links…": read a plain-text file and run its contents
    /// through the capture funnel. Reads off the main actor — a link list is
    /// small, but nothing stops a user from picking a huge log file.
    func importLinks(from fileURL: URL) async -> CaptureResult? {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 10_000_000 else {
            showFeedback(
                CaptureFeedback(
                    kind: .warning,
                    message: "\(fileURL.lastPathComponent) is too large to import (over 10 MB)"))
            return nil
        }
        let text = await Task.detached {
            var encoding = String.Encoding.utf8
            return try? String(contentsOf: fileURL, usedEncoding: &encoding)
        }.value
        guard let text else {
            showFeedback(
                CaptureFeedback(
                    kind: .warning, message: "Couldn't read \(fileURL.lastPathComponent)"))
            return nil
        }
        return capture(text: text, source: .file)
    }

    /// macOS 15.4+ pasteboard privacy lives under Privacy & Security; there is
    /// no stable deep link to the Pasteboard row itself, so open the pane root.
    func openPasteboardPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Every whitespace-separated token that parses as an http(s) URL with a
    /// host, in input order. Punctuation that prose wraps around links —
    /// "(see https://x.com/a)", "https://x.com/b," — is trimmed first. As a
    /// convenience for hand-typed input, a single host-shaped bare token like
    /// "x.com/a/status/1" is accepted with https:// assumed.
    nonisolated static func extractURLs(from text: String) -> [String] {
        let tokens = text.split(whereSeparator: \.isWhitespace)
            .map { trimWrappingPunctuation(String($0)) }
        let urls = tokens.filter { token in
            guard let url = URL(string: token), url.host != nil,
                let scheme = url.scheme?.lowercased()
            else { return false }
            return scheme == "http" || scheme == "https"
        }
        if urls.isEmpty, tokens.count == 1, let bare = tokens.first, looksLikeBareURL(bare) {
            return ["https://" + bare]
        }
        return urls
    }

    /// Scheme-less but host-shaped WITH a path: "x.com/a/status/1" yes;
    /// "hello", emails, "1.2", and filename-shaped tokens like "node.js" no —
    /// requiring the "/" keeps file names from becoming doomed downloads, and
    /// a bare domain with no path has nothing to download anyway. Only
    /// consulted when the token is the entire input, so prose never sprouts
    /// accidental URLs.
    nonisolated private static func looksLikeBareURL(_ token: String) -> Bool {
        guard token.contains("/"), !token.contains("://"), !token.contains("@"),
            let url = URL(string: "https://" + token),
            let host = url.host, host.contains(".")
        else { return false }
        let tld = host.split(separator: ".").last ?? ""
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }

    /// Strips the punctuation prose wraps around a link — leading brackets and
    /// quotes, trailing stops (ASCII and CJK fullwidth). A trailing paren is
    /// only stripped while unbalanced, so Wikipedia-style "…_(film)" URLs
    /// keep theirs.
    nonisolated static func trimWrappingPunctuation(_ token: String) -> String {
        let leading: Set<Character> = ["(", "（", "「", "『", "【", "〈", "《", "<", "'", "\"", "‘", "“"]
        let trailing: Set<Character> = [
            ",", ".", ";", ":", "!", "?", "…", "'", "\"", "’", "”", ">",
            "，", "。", "、", "；", "：", "！", "？", "」", "』", "】", "〉", "》",
        ]
        var s = Substring(token)
        while let first = s.first, leading.contains(first) { s = s.dropFirst() }
        while let last = s.last {
            if trailing.contains(last) {
                s = s.dropLast()
            } else if last == ")" || last == "）" {
                let open: Character = last == ")" ? "(" : "（"
                if s.filter({ $0 == last }).count > s.filter({ $0 == open }).count {
                    s = s.dropLast()
                } else {
                    break
                }
            } else {
                break
            }
        }
        return String(s)
    }

    // MARK: - Queue management

    private enum AddOutcome {
        case queued
        case alreadyInList(UUID)
        case needsConfirmation(DuplicateConfirmation)
    }

    /// `skipHistoryCheck` is set by `confirmDuplicateDownloads` so the user's
    /// "Download again" choice doesn't re-trigger the same warning.
    private func add(urlString: String, skipHistoryCheck: Bool) -> AddOutcome? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let stripped = Self.stripTrackingParams(trimmed)

        if let existing = items.first(where: { $0.url == stripped }) {
            return .alreadyInList(existing.id)
        }

        if saveHistoryEnabled, !skipHistoryCheck, let prior = history.mostRecentCompleted(for: stripped) {
            let fileExists = prior.outputPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            return .needsConfirmation(
                DuplicateConfirmation(url: stripped, priorEntry: prior, priorFileExists: fileExists))
        }

        let item = DownloadItem(url: stripped)
        items.insert(item, at: 0)
        downloadQueue.append(item)
        saveQueue()
        drainQueue()
        return .queued
    }

    func confirmDuplicateDownloads(_ batch: DuplicateBatch) {
        advanceDuplicateBatchQueue()
        var queued = 0
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            for confirmation in batch.confirmations {
                if case .queued? = add(urlString: confirmation.url, skipHistoryCheck: true) {
                    queued += 1
                }
            }
        }
        if queued > 0, let feedback = composeFeedback(queued: queued, alreadyPresent: [], toConfirm: 0) {
            showFeedback(feedback)
        }
    }

    func dismissDuplicates() {
        // The alert's isPresented binding fires a trailing `false` after every
        // button action; by then the slot is already empty, so this no-ops
        // instead of eating the next queued batch.
        guard pendingDuplicates != nil else { return }
        advanceDuplicateBatchQueue()
    }

    func revealDuplicatePriorFile(_ dup: DuplicateConfirmation) {
        advanceDuplicateBatchQueue()
        guard let path = dup.priorEntry.outputPath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func presentDuplicates(_ batch: DuplicateBatch) {
        if pendingDuplicates == nil {
            pendingDuplicates = batch
        } else {
            duplicateBatchQueue.append(batch)
        }
    }

    /// Closes the current batch and re-presents the next queued one on the
    /// following runloop tick — the alert must finish its dismissal pass
    /// before `pendingDuplicates` becomes non-nil again, or SwiftUI won't
    /// re-present it.
    private func advanceDuplicateBatchQueue() {
        pendingDuplicates = nil
        guard !duplicateBatchQueue.isEmpty else { return }
        Task { @MainActor in
            if self.pendingDuplicates == nil, !self.duplicateBatchQueue.isEmpty {
                self.pendingDuplicates = self.duplicateBatchQueue.removeFirst()
            }
        }
    }

    /// One status line per capture: the single-outcome cases get the friendly
    /// copy; a mixed batch composes one truthful line ("Queued 2 · 1 already
    /// in list · 1 to confirm"). A capture that ONLY raised the duplicate
    /// dialog returns nil — the dialog is the feedback.
    private func composeFeedback(
        queued: Int, alreadyPresent: [UUID], toConfirm: Int
    ) -> CaptureFeedback? {
        switch (queued, alreadyPresent.count, toConfirm) {
        case (0, 0, _):
            return nil
        case (let q, 0, 0) where q > 0:
            return CaptureFeedback(kind: .success, message: "Queued \(q) link\(q == 1 ? "" : "s")")
        case (0, 1, 0):
            return CaptureFeedback(
                kind: .info,
                message: "Already in your list — highlighted below",
                highlightItemID: alreadyPresent.first)
        case (0, let a, 0):
            return CaptureFeedback(kind: .info, message: "All \(a) already in your list")
        default:
            var parts: [String] = []
            if queued > 0 { parts.append("Queued \(queued)") }
            if !alreadyPresent.isEmpty { parts.append("\(alreadyPresent.count) already in list") }
            if toConfirm > 0 { parts.append("\(toConfirm) to confirm") }
            return CaptureFeedback(
                kind: queued > 0 ? .success : .info,
                message: parts.joined(separator: " · "),
                highlightItemID: queued == 0 && alreadyPresent.count == 1 ? alreadyPresent.first : nil)
        }
    }

    private func showFeedback(_ feedback: CaptureFeedback) {
        withAnimation(.easeInOut(duration: 0.2)) { captureFeedback = feedback }
        feedbackTask?.cancel()
        guard !feedback.isPersistent else { return }
        feedbackTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.25)) { captureFeedback = nil }
            }
        }
    }

    func retryItem(_ item: DownloadItem) {
        // A `.failed` status can be transient — yt-dlp sets it mid-chain while
        // the fallback loop is still about to run. Re-queueing such an item
        // would start a second concurrent download of the same file.
        guard !inFlightItemIDs.contains(item.id) else { return }
        item.status = .queued
        item.resetForReattempt()
        item.subtitleDownloadFailed = false
        item.subtitlesDisabled = false
        downloadQueue.append(item)
        saveQueue()
        drainQueue()
        markFailuresSeen()
        recomputeMenuBarState()
    }

    func removeItem(_ item: DownloadItem) {
        activeProcesses[item.id]?.terminate()
        activeProcesses.removeValue(forKey: item.id)
        activeFxTasks[item.id]?.cancel()
        activeFxTasks.removeValue(forKey: item.id)
        pausedItemIDs.remove(item.id)
        downloadQueue.removeAll { $0.id == item.id }
        items.removeAll { $0.id == item.id }
        saveQueue()
        markFailuresSeen()
    }

    func pauseItem(_ item: DownloadItem) {
        switch item.status {
        case .downloading, .fetching:
            break
        default:
            return
        }
        pausedItemIDs.insert(item.id)
        // The post-exit branch in runDownload flips status to .paused once
        // the yt-dlp process actually finishes terminating.
        activeProcesses[item.id]?.terminate()
        // The fxtwitter fallback runs as a URLSession Task, not a Process —
        // cancel it too; runDownload consumes the pause after it returns.
        activeFxTasks[item.id]?.cancel()
    }

    func resumeItem(_ item: DownloadItem) {
        guard item.status == .paused else { return }
        item.status = .queued
        downloadQueue.append(item)
        saveQueue()
        drainQueue()
        recomputeMenuBarState()
    }

    func clearCompleted() {
        items.removeAll { $0.status == .completed }
        saveQueue()
    }

    // MARK: - File utilities

    func revealInFinder(_ item: DownloadItem) {
        if let path = item.outputPath {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.open(outputDirectory)
        }
    }

    func openDownloadsFolder() {
        NSWorkspace.shared.open(outputDirectory)
    }

    // MARK: - Cookies file (security-scoped bookmark for sandbox)
    /// Resolves the cookies file for a single download via `CookieAccessManager`.
    /// Returns the `--cookies` path + granted URL; for a plain path with no bookmark,
    /// falls back to the display path with no grant.
    func resolveCookiesForDownload() -> (path: String?, granted: URL?) {
        switch cookieAccess.resolveForDownload() {
        case .none:
            return (cookiesFilePath, nil)  // no bookmark: plain display path (or nil), no grant
        case .resolved(let path, let granted):
            cookiesFilePath = path  // keep the display path in sync with the resolved location
            return (path, granted)
        case .bookmarkFailed:
            // Stale/moved cookies.txt: don't hand yt-dlp an ungranted --cookies path that would
            // override and break browser cookies — fall back to --cookies-from-browser.
            return (nil, nil)
        }
    }

    func setCookiesFile(from url: URL) {
        cookieAccess.setFile(url)  // stores a security-scoped bookmark, or clears it (plain-path fallback)
        cookiesFilePath = url.path
        saveSettings()
    }

    func clearCookiesFile() {
        cookieAccess.clear()
        cookiesFilePath = nil
        saveSettings()
    }

    // MARK: - Settings

    func saveSettings() {
        settingsStore.save(currentSettings())
    }

    private func currentSettings() -> AppSettings {
        AppSettings(
            outputDirectory: outputDirectory,
            cookieBrowser: cookieBrowser,
            cookiesFilePath: cookiesFilePath,
            cookiesFileBookmarkData: cookieAccess.bookmarkForSaving,
            showDownloadDate: showDownloadDate,
            youtubeFormat: youtubeFormat,
            videoQuality: videoQuality,
            audioQuality: audioQuality,
            subtitleLanguage: subtitleLanguage,
            embedSubtitles: embedSubtitles,
            maxConcurrent: maxConcurrent,
            openPreference: openPreference,
            saveHistoryEnabled: saveHistoryEnabled,
            showMenuBarExtra: showMenuBarExtra
        )
    }

    // MARK: - Private

    private func loadSettings() {
        let s = settingsStore.load(fallback: currentSettings())
        outputDirectory = s.outputDirectory
        cookieBrowser = s.cookieBrowser
        cookiesFilePath = s.cookiesFilePath
        if let bm = s.cookiesFileBookmarkData { cookieAccess.loadBookmark(bm) }
        showDownloadDate = s.showDownloadDate
        youtubeFormat = s.youtubeFormat
        videoQuality = s.videoQuality
        audioQuality = s.audioQuality
        subtitleLanguage = s.subtitleLanguage
        embedSubtitles = s.embedSubtitles
        maxConcurrent = s.maxConcurrent
        openPreference = s.openPreference
        saveHistoryEnabled = s.saveHistoryEnabled
        showMenuBarExtra = s.showMenuBarExtra
    }

    private func drainQueue() {
        while activeCount < maxConcurrent, !downloadQueue.isEmpty {
            let item = downloadQueue.removeFirst()
            activeCount += 1
            inFlightItemIDs.insert(item.id)
            Task {
                await runDownload(item)
                inFlightItemIDs.remove(item.id)
                activeCount -= 1
                drainQueue()
            }
        }
    }

    /// True while the item is still in the visible list. `removeItem` is the
    /// only way an in-flight item leaves it, so false means the user hit the
    /// row's ✕ — nothing downstream (fallbacks, retries, history) should run.
    private func stillInList(_ item: DownloadItem) -> Bool {
        items.contains { $0.id == item.id }
    }

    private func runDownload(_ item: DownloadItem) async {
        guard stillInList(item) else { return }
        item.status = .fetching
        if youtubeFormat == .audioOnly { item.mediaCategory = .audio }

        // A prior run hit a subtitle 429 and aborted before saving the video —
        // drop subtitles on the retry so the video itself can download.
        let effectiveSubtitleLanguage: SubtitleLanguage = item.subtitlesDisabled ? .none : subtitleLanguage

        let cookies = resolveCookiesForDownload()
        var ytExitCode: Int32 = 0
        await cookieAccess.withScope(for: item.id, file: cookies.path, grantedURL: cookies.granted) {
            let args = YtDlpService.buildArguments(
                for: item,
                outputDirectory: outputDirectory,
                format: youtubeFormat,
                videoQuality: videoQuality,
                audioQuality: audioQuality,
                subtitleLanguage: effectiveSubtitleLanguage,
                embedSubtitles: embedSubtitles,
                cookieBrowser: cookieBrowser,
                cookiesFile: cookies.path
            )

            ytExitCode = await ProcessRunner.run(
                executablePath: ytdlpPath,
                arguments: args,
                item: item,
                register: { [weak self] p in self?.activeProcesses[item.id] = p },
                unregister: { [weak self] in self?.activeProcesses.removeValue(forKey: item.id) },
                lineParser: { [weak self] line, item in
                    YtDlpService.parseLine(line, item: item) {
                        self?.activeProcesses[item.id]?.terminate()
                    }
                }
            )
        }

        // The row's ✕ terminated this process mid-run: the user cancelled.
        // Don't complete, pause-freeze, retry, or fall back on their behalf.
        guard stillInList(item) else { return }

        // "Empty success": yt-dlp can exit 0 without writing any file. Seen on
        // Twitter for text-only tweets, quote-RTs whose referenced media yt-dlp
        // can't reach, and sensitive content the current cookies don't unlock.
        // Use a cookies.txt export (Settings) for X adult/NSFW media that browser cookies can't reach.
        // gallery-dl often picks these up, so treat it the same as a non-zero
        // exit and let the fallback below try.
        let mediaCaptured = item.outputPath != nil
        var hasFatalError = false
        if case .failed = item.status { hasFatalError = true }
        // Subtitles are best-effort: if the video already reached disk but yt-dlp
        // exited non-zero *only* because the (optional) subtitle download was
        // rate-limited, keep the video rather than failing. Scoped to the
        // subtitle case so other non-zero exits (e.g. a Twitter multi-video tweet
        // that partially downloaded) still fall through to the fallback below.
        let subtitleOnlyFailure = item.subtitleDownloadFailed && !hasFatalError
        if mediaCaptured && (ytExitCode == 0 || subtitleOnlyFailure) {
            item.markCompleted()
            finalize(item)
            return
        }

        // User pressed Stop: the non-zero exit was our own terminate(). Freeze the
        // row at its current progress so Resume can pick up from the .part file.
        if pausedItemIDs.remove(item.id) != nil {
            item.status = .paused
            item.speed = nil
            item.eta = nil
            saveQueue()
            return
        }

        // Subtitle download is best-effort. YouTube heavily rate-limits its
        // subtitle endpoint (HTTP 429), and yt-dlp writes subtitles *before* the
        // video — so that error aborts the item with no media saved. Retry once
        // with subtitles disabled so the video itself still downloads. (When subs
        // are fetched last instead, the success check above already keeps the
        // video, so this branch only fires when nothing landed on disk.)
        if item.subtitleDownloadFailed && !item.subtitlesDisabled && item.outputPath == nil {
            item.subtitlesDisabled = true
            item.status = .fetching
            item.progress = 0
            item.speed = nil
            item.eta = nil
            saveQueue()
            await runDownload(item)
            return
        }

        // yt-dlp failed or found no media — run the site's declared fallback
        // chain (data-driven from its SiteProfile) until one succeeds. Each tool
        // owns its own process/task + pause handling in a helper below; adding or
        // reordering a site's fallbacks is now a profile edit, not a change here.
        let profile = SiteRegistry.profile(for: item.url)
        var ranFallback = false
        for fallback in profile.fallbacks {
            guard stillInList(item) else { return }  // ✕ during a fallback run
            if case .completed = item.status { break }  // a prior fallback already won
            switch fallback {
            case .galleryDl:
                guard let gdlPath = galleryDlPath else { continue }  // tool not installed
                ranFallback = true
                await runGalleryDlFallback(item, executablePath: gdlPath)
            case .fxTwitter:
                guard case .failed = item.status else { continue }  // only as a rescue
                ranFallback = true
                if await runFxTwitterFallback(item) { return }  // user pressed Stop mid-run
            }
        }

        // No fallback ran (none declared for this site, or gallery-dl missing) —
        // finalize yt-dlp's own outcome.
        if !ranFallback {
            if case .failed = item.status {
                // already set by YtDlpService
            } else if ytExitCode == 0 {
                item.status = .failed("yt-dlp reported success but found no media to download.")
            } else {
                item.status = .failed("yt-dlp exited with code \(ytExitCode)")
            }
        }

        // Auto-retry once on "empty success" — yt-dlp or gallery-dl exited 0
        // without producing any media. Most often a transient X GraphQL
        // hiccup (token rotation, brief rate-limit, cache miss) that one
        // extra attempt clears. Genuinely-unreachable tweets just hit the
        // same outcome and stay Failed. Real errors (non-zero exit codes)
        // don't match the message check below and skip the retry, so we
        // don't waste time re-running obvious network/auth failures.
        let isEmptySuccess: Bool = {
            guard case .failed(let msg) = item.status else { return false }
            return msg.contains("found no media") || msg.contains("No media found") || msg.contains("cookies.txt")
        }()
        if isEmptySuccess && !item.autoRetryAttempted {
            item.autoRetryAttempted = true
            item.status = .fetching
            item.resetForReattempt()
            saveQueue()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await runDownload(item)
            return
        }

        finalize(item)
    }

    /// Resets yt-dlp's partial state, then runs the gallery-dl fallback (a
    /// Process — pause kills it via `activeProcesses`). On return `item.status`
    /// is `.completed` or `.failed`.
    private func runGalleryDlFallback(_ item: DownloadItem, executablePath: String) async {
        item.status = .fetching
        item.resetForReattempt()

        let cookies = resolveCookiesForDownload()
        await cookieAccess.withScope(for: item.id, file: cookies.path, grantedURL: cookies.granted) {
            await GalleryDlService.run(
                item: item,
                executablePath: executablePath,
                outputDirectory: outputDirectory,
                cookieBrowser: cookieBrowser,
                cookiesFile: cookies.path,
                register: { [weak self] p in self?.activeProcesses[item.id] = p },
                unregister: { [weak self] in self?.activeProcesses.removeValue(forKey: item.id) }
            )
        }
    }

    /// Last-resort fallback: X's GraphQL APIs sometimes hide tweets from
    /// spam-flagged accounts while the media stays publicly served from the twimg
    /// CDN — fxtwitter still resolves those. Runs as a cancellable Task (no
    /// Process to kill), so it registers in `activeFxTasks`. Keeps the prior
    /// (gallery-dl) failure message when it can't help. Returns true if the user
    /// pressed Stop mid-run — the item is set to .paused and the caller returns.
    private func runFxTwitterFallback(_ item: DownloadItem) async -> Bool {
        let fxTask = Task { await FxTwitterService.run(item: item, outputDirectory: outputDirectory) }
        activeFxTasks[item.id] = fxTask
        _ = await fxTask.value
        activeFxTasks.removeValue(forKey: item.id)

        if pausedItemIDs.remove(item.id) != nil, item.status != .completed {
            item.status = .paused
            item.speed = nil
            item.eta = nil
            saveQueue()
            return true
        }
        return false
    }

    private func finalize(_ item: DownloadItem) {
        saveQueue()
        // Skip items the user removed mid-download — their terminal state is
        // just the terminated process winding down, not news and not history.
        guard stillInList(item) else { return }
        recordHistory(for: item)
        NotificationService.downloadFinished(item)
        // Failures that land while the user isn't looking raise the menu bar
        // ⚠. Only a failure with the main window actually on screen (not
        // merely app-active — the window may be closed or on another Space)
        // is already visible as a red row and doesn't count as "unseen".
        if case .failed = item.status, !isMainWindowShowing {
            hasUnseenFailures = true
        }
        recomputeMenuBarState()
    }

    /// Only terminal states (completed/failed) are persisted. Crash recovery for
    /// in-progress downloads is queue.json's job — we don't duplicate that here.
    private func recordHistory(for item: DownloadItem) {
        guard saveHistoryEnabled else { return }
        writeHistoryEntry(for: item, finishedAt: Date())
        refreshHistoryStats()
    }

    /// Lower-level write — does NOT consult `saveHistoryEnabled`. Used both by
    /// the live finalize path (with `finishedAt = now`) and by the bulk import
    /// (with `finishedAt = item.addedAt` so historic dates aren't all "today").
    /// Returns true when a row was actually persisted.
    @discardableResult
    private func writeHistoryEntry(for item: DownloadItem, finishedAt: Date) -> Bool {
        let status: String
        let errorMessage: String?
        switch item.status {
        case .completed:
            status = "completed"
            errorMessage = nil
        case .failed(let msg):
            status = "failed"
            errorMessage = msg.isEmpty ? nil : msg
        default:
            return false
        }
        let outputPath = item.outputPath ?? item.videoPath ?? item.audioPath
        let fileSize: Int64? = {
            guard let p = outputPath,
                let attrs = try? FileManager.default.attributesOfItem(atPath: p)
            else { return nil }
            return attrs[.size] as? Int64
        }()
        let entry = HistoryEntry(
            id: item.id.uuidString,
            url: item.url,
            title: item.title,
            site: siteLabel(for: item.url),
            mediaCategory: item.mediaCategory == .unknown ? nil : item.mediaCategory.rawValue,
            outputPath: outputPath,
            fileSizeBytes: fileSize,
            status: status,
            errorMessage: errorMessage,
            startedAt: item.addedAt,
            finishedAt: finishedAt
        )
        history.record(entry)
        return true
    }

    private func siteLabel(for url: String) -> String {
        SiteRegistry.profile(for: url).id
    }

    // MARK: - History admin

    func refreshHistoryStats() {
        historyCount = history.count()
        historySizeBytes = history.fileSize()
    }

    func clearHistory() {
        history.clear()
        refreshHistoryStats()
    }

    /// Number of items in the current task list that are eligible for import
    /// (completed or failed). Used to disable/label the Settings import button.
    var importableTaskCount: Int {
        items.reduce(into: 0) { count, item in
            switch item.status {
            case .completed, .failed: count += 1
            default: break
            }
        }
    }

    /// Writes all completed/failed items from the current task list into the DB.
    /// Idempotent (INSERT OR REPLACE keyed on item id) so it's safe to run more
    /// than once. Returns the number of rows written.
    @discardableResult
    func importTaskListToHistory() -> Int {
        var written = 0
        for item in items {
            if writeHistoryEntry(for: item, finishedAt: item.addedAt) {
                written += 1
            }
        }
        refreshHistoryStats()
        return written
    }

    func revealHistoryFile() {
        NSWorkspace.shared.selectFile(history.fileURL.path, inFileViewerRootedAtPath: "")
    }

    // MARK: - Queue persistence

    private func saveQueue() {
        queueStore.save(items.map { $0.toPersisted() })
    }

    private func loadQueue() {
        let persisted = queueStore.load()
        guard !persisted.isEmpty else { return }

        // Preserve display order (newest first). Re-queue non-completed items
        // in original chronological order (oldest first) so they download in
        // the same sequence as before the crash/quit.
        let restored = persisted.map { DownloadItem(persisted: $0) }

        // Self-heal v1.3.0-era "empty success" rows: marked Done but no file
        // was ever recorded (no title/media chip in the UI). Re-queue them so
        // they run through the current yt-dlp → gallery-dl → fxtwitter chain
        // instead of posing as completed forever.
        for item in restored
        where item.status == .completed
            && item.outputPath == nil && item.videoPath == nil && item.audioPath == nil
        {
            item.status = .queued
        }

        items = restored
        for item in restored.reversed() where item.status != .completed && item.status != .paused {
            downloadQueue.append(item)
        }
    }

    // "t" covers x.com share links (?s=46&t=…) so they dedup against the bare
    // status URL; YouTube's t= is only a seek position, irrelevant to a download.
    // "igsh" is Instagram's share-link tracking param (?igsh=…), same dedup story.
    private static let trackingParamsExact = Set(["si", "s", "t", "ref", "ref_src", "ref_url", "fbclid", "gclid", "msclkid", "igsh"])

    static func stripTrackingParams(_ urlString: String) -> String {
        guard var c = URLComponents(string: urlString) else { return urlString }
        c.queryItems = c.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !Self.trackingParamsExact.contains(name)
        }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        return c.url?.absoluteString ?? urlString
    }
}

struct DuplicateConfirmation: Identifiable {
    let id = UUID()
    let url: String
    let priorEntry: HistoryEntry
    let priorFileExists: Bool
}

/// One capture's worth of already-in-history links, presented as a single
/// alert — "Download all again / Skip all" — instead of N sequential ones.
struct DuplicateBatch: Identifiable {
    let id = UUID()
    let confirmations: [DuplicateConfirmation]

    /// Non-nil when the batch is one link, which gets the detailed alert
    /// (prior date, saved path, Show in Finder).
    var single: DuplicateConfirmation? {
        confirmations.count == 1 ? confirmations.first : nil
    }
}

/// Where a capture came from — only used to word the "no link" feedback.
enum CaptureSource {
    case clipboard, field, drop, urlScheme, file

    var noLinkMessage: String {
        switch self {
        case .clipboard: return "No link found in the clipboard"
        case .field: return "That doesn't look like a link"
        case .drop: return "No link found in the dropped text"
        case .urlScheme: return "The xdownloader:// URL carried no link"
        case .file: return "No links found in the file"
        }
    }
}

/// What one capture did, for callers that react to it (e.g. the URL field
/// clears itself only when its text was accepted).
struct CaptureResult {
    let queued: Int
    let alreadyPresent: Int
    let toConfirm: Int
    let foundLinks: Bool
}

/// A status-line message describing the outcome of a capture.
struct CaptureFeedback: Equatable {
    enum Kind { case success, info, warning }

    /// Every capture gets a fresh identity, even when the visible outcome is
    /// word-for-word the same — onChange-driven side effects (filter reset,
    /// scroll, pulse, VoiceOver announcement) must fire for repeats too.
    let id = UUID()
    let kind: Kind
    let message: String
    /// Existing item to scroll to and pulse ("already in your list").
    var highlightItemID: UUID? = nil
    /// Stays until replaced (pasteboard access denied) instead of auto-clearing.
    var isPersistent: Bool = false
    /// Show an "Open System Settings" button next to the message.
    var offersPrivacySettings: Bool = false
}
