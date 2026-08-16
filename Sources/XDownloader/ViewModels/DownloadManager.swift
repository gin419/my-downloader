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
    @Published var cookieBrowserProfile: String = ""
    @Published var cookiesFilePath: String? = nil  // display / last resolved path
    @Published var twitterHandle: String = ""
    @Published private(set) var likesAccessVerification: LikesAccessVerification = .idle
    @Published private(set) var likesSyncSnapshot: LikesSyncSnapshot = .idle {
        didSet { recomputeMenuBarState() }
    }
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
    private var likesSyncProcess: Process?
    private var likesVerificationProcess: Process?
    private var likesSyncTask: Task<Void, Never>?
    private var likesRunID: String?
    private var likesLastRunID: String?
    private var likesAccountID: Int64?
    private var likesAccumulator = LikesSyncRunAccumulator()
    private var likesDiagnostics: [String] = []
    private var likesCancelRequested = false
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
    private let history: HistoryStore
    private let queueStore: QueueStore
    private let settingsStore: SettingsStore
    private let likesSyncStore: LikesSyncStore
    private let likesProcessRunner: any LikesSyncProcessRunning
    private let galleryDlPathProvider: () -> String?

    // Resolved at runtime via RequirementsService so paths stay in one place.
    private var ytdlpPath: String { RequirementsService.ytdlp.installedPath ?? "yt-dlp" }
    private var galleryDlPath: String? { galleryDlPathProvider() }

    var availableCookieBrowserProfiles: [BrowserCookieProfile] {
        BrowserCookieProfileDiscovery.profiles(for: cookieBrowser)
    }

    // MARK: - Init

    init(
        history: HistoryStore? = nil,
        queueStore: QueueStore = QueueStore(),
        settingsStore: SettingsStore = SettingsStore(),
        likesSyncStore: LikesSyncStore? = nil,
        likesProcessRunner: (any LikesSyncProcessRunning)? = nil,
        galleryDlPathProvider: @escaping () -> String? = {
            RequirementsService.galleryDl.installedPath
        }
    ) {
        self.history = history ?? HistoryStore()
        self.queueStore = queueStore
        self.settingsStore = settingsStore
        self.likesSyncStore = likesSyncStore ?? LikesSyncStore()
        self.likesProcessRunner = likesProcessRunner ?? LiveLikesSyncProcessRunner()
        self.galleryDlPathProvider = galleryDlPathProvider
        let downloads =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = downloads.appendingPathComponent("X-Videos")
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        self.outputDirectory = defaultDir

        loadSettings()
        restoreLikesSyncSnapshot()
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
            likesStatus: likesSyncSnapshot.status,
            likesHandle: likesSyncSnapshot.handle?.displayName,
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
        if likesSyncSnapshot.status.needsAttention {
            if likesSyncSnapshot.failures.isEmpty {
                startLikesSync()
            } else {
                retryAllLikesFailures()
            }
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
        guard let app = NSApp, app.isActive else { return false }
        return app.windows.contains { window in
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
        // Cross-attempt state: the detected external-redirect URL must survive
        // resetForReattempt (the fallback/auto-retry resets within one run)
        // but a user-initiated Retry starts a genuinely new attempt.
        item.externalRedirectURL = nil
        // A stale pause request from a previous run must never freeze the
        // retried download to .paused the moment its process exits.
        pausedItemIDs.remove(item.id)
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

    // MARK: - X Likes sync

    func likesHandleChanged() {
        likesAccessVerification = .idle
    }

    func cookieBrowserChanged() {
        normalizeCookieBrowserProfile()
        likesAccessVerification = .idle
        saveSettings()
    }

    func cookieBrowserProfileChanged() {
        likesAccessVerification = .idle
        saveSettings()
    }

    func verifyLikesAccess() {
        guard likesVerificationProcess == nil, !likesSyncSnapshot.status.isActive else { return }
        guard let executable = galleryDlPath else {
            likesAccessVerification = .failed("gallery-dl is required. Install or update it, then try again.")
            return
        }
        let handle: LikesSyncHandle
        do {
            handle = try LikesSyncHandle(twitterHandle)
        } catch {
            likesAccessVerification = .failed("Enter a valid X handle, such as @example.")
            return
        }

        twitterHandle = handle.displayName
        saveSettings()
        likesAccessVerification = .verifying
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cookies = self.resolveCookiesForDownload()
            var diagnostics: [String] = []
            var sawExtractorOutput = false
            let scopeID = UUID()
            var exitCode: Int32 = -1
            await self.cookieAccess.withScope(
                for: scopeID, file: cookies.path, grantedURL: cookies.granted
            ) {
                exitCode = await self.likesProcessRunner.run(
                    executablePath: executable,
                    arguments: LikesSyncArgumentBuilder.makeVerification(
                        handle: handle,
                        cookieBrowser: self.cookieBrowser,
                        cookieBrowserProfile: self.cookieBrowserProfile,
                        cookiesFile: cookies.path
                    ).args,
                    register: { [weak self] in self?.likesVerificationProcess = $0 },
                    unregister: { [weak self] in self?.likesVerificationProcess = nil },
                    onLine: { line in
                        if line.hasPrefix("likes-verify\t") { sawExtractorOutput = true }
                        if Self.isUsefulLikesDiagnostic(line) { diagnostics.append(line) }
                    })
            }
            guard case .verifying = self.likesAccessVerification else { return }
            if exitCode == 0, diagnostics.isEmpty || sawExtractorOutput {
                self.likesAccessVerification = .verified(handle)
            } else {
                self.likesAccessVerification = .failed(
                    Self.likesFailureMessage(from: diagnostics.last, exitCode: exitCode))
            }
        }
    }

    func startLikesSync() {
        startLikesSync(inputURLs: nil)
    }

    private func startLikesSync(inputURLs: [String]?) {
        guard !likesSyncSnapshot.status.isActive, likesVerificationProcess == nil else { return }
        guard let executable = galleryDlPath else {
            failLikesBeforeStart("gallery-dl is required. Install or update it, then try again.")
            return
        }

        let handle: LikesSyncHandle
        do {
            handle = try LikesSyncHandle(twitterHandle)
        } catch {
            failLikesBeforeStart("Enter a valid X handle in Settings before syncing Likes.")
            return
        }

        let plan = LikesSyncPlanner.plan(for: handle, rootDirectory: outputDirectory)
        do {
            try FileManager.default.createDirectory(at: plan.outputDirectory, withIntermediateDirectories: true)
        } catch {
            failLikesBeforeStart("Could not create the Likes folder: \(error.localizedDescription)")
            return
        }

        let account: LikesSyncAccount
        do {
            account = try likesSyncStore.upsertAccount(input: handle.displayName, rootDirectory: outputDirectory)
        } catch {
            failLikesBeforeStart("Could not open the Likes sync database.")
            return
        }
        guard let accountID = account.id else {
            failLikesBeforeStart("Could not create the Likes sync account record.")
            return
        }

        twitterHandle = handle.displayName
        saveSettings()
        let run = likesSyncStore.startRun(accountID: accountID)
        likesRunID = run.id
        likesLastRunID = run.id
        likesAccountID = accountID
        likesAccumulator = LikesSyncRunAccumulator()
        likesDiagnostics = []
        likesCancelRequested = false
        likesSyncSnapshot = LikesSyncSnapshot(
            handle: handle,
            status: .running,
            counts: LikesSyncCounts(ignored: likesSyncStore.ignoredFailures(accountID: accountID).count),
            failures: likesSyncStore.pendingFailures(accountID: accountID),
            message: inputURLs == nil ? "Scanning all accessible Likes…" : "Retrying failed Likes…",
            outputDirectory: plan.outputDirectory,
            startedAt: run.startedAt,
            finishedAt: nil)

        let cookies = resolveCookiesForDownload()
        let args = LikesSyncArgumentBuilder.make(
            plan: plan,
            cookieBrowser: cookieBrowser,
            cookieBrowserProfile: cookieBrowserProfile,
            cookiesFile: cookies.path,
            inputURLs: inputURLs
        ).args
        let scopeID = UUID()
        likesSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var exitCode: Int32 = -1
            await withTaskCancellationHandler {
                await self.cookieAccess.withScope(
                    for: scopeID, file: cookies.path, grantedURL: cookies.granted
                ) {
                    exitCode = await self.likesProcessRunner.run(
                        executablePath: executable,
                        arguments: args,
                        register: { [weak self] in self?.likesSyncProcess = $0 },
                        unregister: { [weak self] in self?.likesSyncProcess = nil },
                        onLine: { [weak self] line in self?.consumeLikesLine(line) })
                }
            } onCancel: { [weak self] in
                Task { @MainActor in self?.likesSyncProcess?.terminate() }
            }
            self.finishLikesSync(exitCode: exitCode)
        }
    }

    func cancelLikesSync() {
        guard likesSyncSnapshot.status == .running, let runID = likesRunID else { return }
        likesCancelRequested = true
        likesSyncSnapshot.status = .cancelling
        likesSyncSnapshot.message = "Cancelling after the current file…"
        likesSyncStore.updateRunStatus(id: runID, status: .cancelling)
        likesSyncTask?.cancel()
        likesSyncProcess?.terminate()
    }

    func retryLikesFailure(_ failure: LikesSyncFailure) {
        guard !likesSyncSnapshot.status.isActive else { return }
        likesSyncStore.restoreFailure(id: failure.id)
        likesSyncStore.markFailureRetried(id: failure.id)
        startLikesSync(inputURLs: failure.url.map { [$0] })
    }

    func retryAllLikesFailures() {
        guard !likesSyncSnapshot.status.isActive else { return }
        let failures =
            likesAccountID.map { likesSyncStore.failuresForRetry(accountID: $0) }
            ?? likesSyncSnapshot.failures.filter { $0.ignoredAt == nil }
        let urls = Array(Set(failures.compactMap(\.url))).sorted()
        for failure in failures { likesSyncStore.markFailureRetried(id: failure.id) }
        let needsFullRescan = failures.contains { $0.url == nil }
        startLikesSync(inputURLs: needsFullRescan || urls.isEmpty ? nil : urls)
    }

    func ignoreLikesFailure(_ failure: LikesSyncFailure) {
        likesSyncStore.ignoreFailure(id: failure.id)
        refreshLikesFailureLists()
    }

    func restoreIgnoredLikesFailures() {
        guard let accountID = likesAccountID else { return }
        for failure in likesSyncStore.ignoredFailures(accountID: accountID) {
            likesSyncStore.restoreFailure(id: failure.id)
        }
        refreshLikesFailureLists()
    }

    func openLikesFolder() {
        if let directory = likesSyncSnapshot.outputDirectory {
            NSWorkspace.shared.open(directory)
        } else if let handle = try? LikesSyncHandle(twitterHandle) {
            NSWorkspace.shared.open(LikesSyncPlanner.plan(for: handle, rootDirectory: outputDirectory).outputDirectory)
        }
    }

    private func consumeLikesLine(_ line: String) {
        guard let accountID = likesAccountID, let runID = likesRunID else { return }
        guard let event = LikesSyncEventParser.parse(line) else {
            if Self.isUsefulLikesDiagnostic(line) {
                likesDiagnostics.append(line)
                if likesDiagnostics.count > 20 { likesDiagnostics.removeFirst() }
            }
            return
        }

        likesAccumulator.apply(event)
        if let tweetID = event.tweetID {
            let author = event.authorHandle
            let url =
                event.tweetURL
                ?? author.map { "https://x.com/\($0)/status/\(tweetID)" }
                ?? "https://x.com/i/status/\(tweetID)"
            likesSyncStore.recordTweet(
                LikesSyncTweet(
                    tweetID: tweetID, accountID: accountID, runID: runID,
                    url: url, text: event.text, authorHandle: author))

            if let mediaID = event.mediaID, event.name == .after || event.name == .skip {
                likesSyncStore.recordMedia(
                    LikesSyncMedia(
                        id: mediaID, accountID: accountID, tweetID: tweetID, runID: runID,
                        kind: event.mediaKind, url: event.mediaURL, filePath: event.mediaPath))
            }
            if event.name == .after || event.name == .skip {
                likesSyncStore.resolveFailures(accountID: accountID, tweetID: tweetID)
            }
        }

        if event.name == .error {
            recordLikesFailure(
                message: event.message ?? "gallery-dl could not process this item.",
                category: event.failureCategory,
                tweetID: event.tweetID,
                url: event.tweetURL)
        }
        updateLikesSnapshotCounts()
    }

    private func recordLikesFailure(
        message: String,
        category: LikesSyncFailureCategory? = nil,
        tweetID: String? = nil,
        url: String? = nil
    ) {
        guard let accountID = likesAccountID else { return }
        let classified = category ?? LikesSyncFailureCategory.classify(message)
        let identity = tweetID ?? url ?? classified.rawValue
        let failure = LikesSyncFailure(
            id: "\(accountID):\(identity)",
            accountID: accountID,
            runID: likesRunID,
            tweetID: tweetID,
            url: url ?? tweetID.map { "https://x.com/i/status/\($0)" },
            category: classified,
            message: message,
            ignoredAt: nil,
            resolvedAt: nil,
            retryCount: 0)
        likesSyncStore.recordFailure(failure)
    }

    private func finishLikesSync(exitCode: Int32) {
        guard let runID = likesRunID, let accountID = likesAccountID else { return }
        let diagnosticCategory = likesDiagnostics.last.map(LikesSyncFailureCategory.classify)
        let diagnosticIsFatalAtZero =
            diagnosticCategory == .authentication
            || diagnosticCategory == .rateLimited || diagnosticCategory == .disk
        if (exitCode != 0 || diagnosticIsFatalAtZero), likesAccumulator.failureCount == 0,
            !likesCancelRequested
        {
            let message = Self.likesFailureMessage(from: likesDiagnostics.last, exitCode: exitCode)
            recordLikesFailure(message: message)
        }

        let pending = likesSyncStore.pendingFailures(accountID: accountID)
        let status: LikesSyncRunStatus
        if likesCancelRequested {
            status = .cancelled
        } else if exitCode == 0, pending.isEmpty {
            status = .completed
        } else if likesAccumulator.downloadedCount > 0 || likesAccumulator.skippedCount > 0 {
            status = .partial
        } else {
            status = .failed
        }

        let ignoredCount = likesSyncStore.ignoredFailures(accountID: accountID).count
        likesSyncStore.finishRun(
            id: runID, status: status, summary: likesAccumulator, ignoredCount: ignoredCount)
        let finishedAt = Date()
        updateLikesSnapshotCounts()
        likesSyncSnapshot.status = status
        likesSyncSnapshot.failures = pending
        likesSyncSnapshot.counts.failed = pending.count
        likesSyncSnapshot.counts.ignored = likesSyncStore.ignoredFailures(accountID: accountID).count
        likesSyncSnapshot.finishedAt = finishedAt
        switch status {
        case .completed:
            likesSyncSnapshot.message =
                likesAccumulator.downloadedCount == 0
                ? "Up to date — no new media." : "Likes sync completed."
        case .partial:
            likesSyncSnapshot.message = "Sync completed with items that need attention."
        case .cancelled:
            likesSyncSnapshot.message = "Sync cancelled. Saved files are kept; the next sync resumes safely."
        case .failed:
            likesSyncSnapshot.message = pending.first?.message ?? "Likes sync failed."
        default:
            break
        }
        if status.needsAttention, !isMainWindowShowing { hasUnseenFailures = true }
        likesSyncProcess = nil
        likesSyncTask = nil
        likesRunID = nil
        likesCancelRequested = false
        recomputeMenuBarState()
    }

    private func updateLikesSnapshotCounts() {
        likesSyncSnapshot.counts.discovered = likesAccumulator.tweetCount
        likesSyncSnapshot.counts.downloaded = likesAccumulator.downloadedCount
        likesSyncSnapshot.counts.skipped = likesAccumulator.skippedCount
        likesSyncSnapshot.counts.noMedia = likesAccumulator.noMediaCount
        if let accountID = likesAccountID {
            likesSyncSnapshot.counts.failed = likesSyncStore.pendingFailures(accountID: accountID).count
            likesSyncSnapshot.counts.ignored = likesSyncStore.ignoredFailures(accountID: accountID).count
        }
    }

    private func refreshLikesFailureLists() {
        guard let accountID = likesAccountID else { return }
        likesSyncSnapshot.failures = likesSyncStore.pendingFailures(accountID: accountID)
        likesSyncSnapshot.counts.failed = likesSyncSnapshot.failures.count
        likesSyncSnapshot.counts.ignored = likesSyncStore.ignoredFailures(accountID: accountID).count
        if likesSyncSnapshot.failures.isEmpty,
            likesSyncSnapshot.status == .partial || likesSyncSnapshot.status == .failed
        {
            likesSyncSnapshot.status = .completed
            likesSyncSnapshot.message =
                likesSyncSnapshot.counts.ignored > 0
                ? "Completed with ignored items." : "Likes sync completed."
            if let runID = likesLastRunID {
                likesSyncStore.updateRunStatus(id: runID, status: .completed)
            }
            markFailuresSeen()
        }
        recomputeMenuBarState()
    }

    private func failLikesBeforeStart(_ message: String) {
        likesSyncSnapshot.status = .failed
        likesSyncSnapshot.message = message
        likesSyncSnapshot.finishedAt = Date()
        if !isMainWindowShowing { hasUnseenFailures = true }
        recomputeMenuBarState()
    }

    private func restoreLikesSyncSnapshot() {
        guard let handle = try? LikesSyncHandle(twitterHandle),
            let account = likesSyncStore.account(for: handle), let accountID = account.id
        else { return }
        likesAccountID = accountID
        let pending = likesSyncStore.pendingFailures(accountID: accountID)
        let ignored = likesSyncStore.ignoredFailures(accountID: accountID)
        guard let run = likesSyncStore.latestRun(accountID: accountID) else {
            likesSyncSnapshot.handle = handle
            likesSyncSnapshot.outputDirectory = account.outputDirectory
            return
        }
        likesLastRunID = run.id
        likesSyncSnapshot = LikesSyncSnapshot(
            handle: handle,
            status: run.status,
            counts: LikesSyncCounts(
                discovered: run.tweetCount, downloaded: run.mediaCount,
                skipped: run.skippedCount, noMedia: run.noMediaCount,
                failed: pending.count, ignored: ignored.count),
            failures: pending,
            message: run.status == .interrupted
                ? "The previous sync was interrupted. Start again to resume safely." : nil,
            outputDirectory: account.outputDirectory,
            startedAt: run.startedAt,
            finishedAt: run.finishedAt)
    }

    nonisolated private static func isUsefulLikesDiagnostic(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("[warning]") && lower.contains("api errors (") { return false }
        if lower.contains("[cookies][info]") || lower.contains("[cookies][debug]") { return false }
        let cookieFailure =
            lower.contains("cookie")
            && (lower.contains("[warning]") || lower.contains("[error]")
                || lower.contains("failed") || lower.contains("unable")
                || lower.contains("could not") || lower.contains("not found"))
        return lower.contains("[error]") || lower.contains("429") || lower.contains("rate limit")
            || lower.contains("login") || lower.contains("unauthorized") || cookieFailure
            || lower.contains("no space") || lower.contains("permission denied")
            || lower.contains("connection") || lower.contains("timeout")
    }

    nonisolated private static func likesFailureMessage(from diagnostic: String?, exitCode: Int32) -> String {
        guard let diagnostic, !diagnostic.isEmpty else {
            return "gallery-dl exited with code \(exitCode). Verify the selected X login and try again."
        }
        let category = LikesSyncFailureCategory.classify(diagnostic)
        switch category {
        case .authentication:
            return "X login could not be verified. Select the browser profile where you are signed in to X, then try again."
        case .rateLimited:
            return "X rate-limited this sync. Wait a while, then retry."
        case .disk:
            return "The Likes folder is not writable or the disk is full."
        case .network:
            return "The network connection failed during Likes sync. Retry when the connection is stable."
        case .unavailable:
            return "X did not return this item; it may be deleted, protected, or unavailable."
        case .tool:
            return "This gallery-dl version cannot sync X Likes. Update gallery-dl, then try again."
        default:
            return diagnostic
        }
    }

    // MARK: - Settings

    func saveSettings() {
        settingsStore.save(currentSettings())
    }

    private func currentSettings() -> AppSettings {
        let persistedTwitterHandle =
            (try? LikesSyncHandle(twitterHandle).displayName) ?? twitterHandle
        return AppSettings(
            outputDirectory: outputDirectory,
            cookieBrowser: cookieBrowser,
            cookieBrowserProfile: cookieBrowserProfile,
            cookiesFilePath: cookiesFilePath,
            cookiesFileBookmarkData: cookieAccess.bookmarkForSaving,
            twitterHandle: persistedTwitterHandle,
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
        cookieBrowserProfile = s.cookieBrowserProfile
        cookiesFilePath = s.cookiesFilePath
        twitterHandle = s.twitterHandle
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
        normalizeCookieBrowserProfile()
    }

    private func normalizeCookieBrowserProfile() {
        let profiles = availableCookieBrowserProfiles
        guard !profiles.isEmpty else {
            cookieBrowserProfile = ""
            return
        }
        guard profiles.contains(where: { $0.id == cookieBrowserProfile }) else {
            cookieBrowserProfile =
                profiles.first(where: { $0.id == "Default" })?.id
                ?? profiles[0].id
            return
        }
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

    // MARK: - Failure messages

    /// yt-dlp exit-0-but-no-files message. Part of the empty-success family:
    /// `isEmptySuccessMessage` matches it by prefix (the gallery-dl-missing
    /// hint may be appended) so the one-shot auto-retry keeps firing.
    static let ytDlpEmptySuccessMessage =
        "yt-dlp reported success but found no media to download — the link may be a playlist/channel page, or the post has no video."

    /// Appended to the final failure when the fallback loop skipped gallery-dl
    /// because it isn't installed — the missing tool, not the site, is then
    /// the likely cause.
    static let galleryDlMissingHint =
        " (gallery-dl is not installed — installing it usually fixes X/Instagram/Reddit downloads; see Settings.)"

    /// Appends the gallery-dl-missing hint to a final failure message. The
    /// external-redirect sentinel is internal control flow, replaced wholesale
    /// before finalize — never annotate it, or the replacement comparison
    /// breaks.
    static func annotatedWithGalleryDlMissingHint(_ message: String) -> String {
        guard message != DownloadStatus.externalRedirectSentinel else { return message }
        return message + galleryDlMissingHint
    }

    /// Signal-aware yt-dlp failure line — a signal number is not an exit code
    /// the tool chose. Cites the run's last captured WARNING when present.
    static func ytDlpFailureMessage(code: Int32, wasSignal: Bool, lastWarning: String?) -> String {
        var message = wasSignal ? "yt-dlp was terminated (signal \(code))" : "yt-dlp exited with code \(code)"
        if let lastWarning { message += " — last warning: \(lastWarning)" }
        return message
    }

    /// True only for the "empty success" family — a tool exited 0 with no
    /// files — which is exactly what the one-shot auto-retry re-queues.
    /// Formerly a substring match ("found no media" / "No media found" /
    /// "cookies.txt") that new error copy kept tripping (the NSFW mapping
    /// mentions cookies.txt but must NOT re-run); now pinned to the message
    /// constants themselves. Prefix matches cover the two dynamic variants:
    /// "No media found — <captured warning>" and the appended
    /// `galleryDlMissingHint`.
    static func isEmptySuccessMessage(_ message: String) -> Bool {
        if message == GalleryDlService.noMediaGenericMessage { return true }
        if message.hasPrefix(GalleryDlService.noMediaWarningPrefix) { return true }
        if message.hasPrefix(ytDlpEmptySuccessMessage) { return true }
        return false
    }

    private func runDownload(_ item: DownloadItem) async {
        guard stillInList(item) else { return }
        item.status = .fetching
        if youtubeFormat == .audioOnly { item.mediaCategory = .audio }

        // A prior run hit a subtitle 429 and aborted before saving the video —
        // drop subtitles on the retry so the video itself can download.
        let effectiveSubtitleLanguage: SubtitleLanguage = item.subtitlesDisabled ? .none : subtitleLanguage

        let cookies = resolveCookiesForDownload()
        var ytResult = ProcessResult(code: 0, wasSignal: false)
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
                cookieBrowserProfile: cookieBrowserProfile,
                cookiesFile: cookies.path
            )

            ytResult = await ProcessRunner.run(
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
        if mediaCaptured && (ytResult.isSuccess || subtitleOnlyFailure) {
            // Counts must match deliverables on disk: pre-merge stream
            // Destination lines are ignored, so fill any zero left when only
            // intermediates were seen (or refresh the title off the final path).
            YtDlpService.ensureFinalMediaCounts(item)
            await runImageSweepIfNeeded(item)
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
        var skippedMissingGalleryDl = false
        for fallback in profile.fallbacks {
            guard stillInList(item) else { return }  // ✕ during a fallback run
            if case .completed = item.status { break }  // a prior fallback already won
            switch fallback {
            case .galleryDl:
                guard let gdlPath = galleryDlPath else {  // tool not installed
                    skippedMissingGalleryDl = true
                    continue
                }
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
            } else if ytResult.isSuccess {
                item.status = .failed(Self.ytDlpEmptySuccessMessage)
            } else {
                item.status = .failed(
                    Self.ytDlpFailureMessage(
                        code: ytResult.code, wasSignal: ytResult.wasSignal,
                        lastWarning: item.lastToolWarning))
            }
        }

        // gallery-dl was skipped for being missing: whatever failure stands —
        // yt-dlp's own, or fxtwitter's restored prior — the absent tool, not
        // the site, is the likely cause; say so. (The helper leaves the
        // external-redirect sentinel untouched.)
        if skippedMissingGalleryDl, case .failed(let message) = item.status {
            item.status = .failed(Self.annotatedWithGalleryDlMissingHint(message))
        }

        // External link positively identified: whether the sentinel itself
        // survived (fxtwitter restored it as the prior status) or the
        // fallbacks ran and came up empty — the tweet's only content IS the
        // external link, so name the destination instead of guessing "no
        // media". Placed BEFORE the auto-retry check: the replacement copy
        // never matches the empty-success predicate, so a positively
        // identified external link doesn't burn the one-shot retry. This is
        // still the last moment before the message can reach a renderer
        // (row, menu bar, NotificationService, history write); every earlier
        // consumer — the fallback chain above — saw the sentinel itself.
        if case .failed(let message) = item.status,
            message == DownloadStatus.externalRedirectSentinel
                || (item.externalRedirectURL != nil && Self.isEmptySuccessMessage(message))
        {
            item.status = .failed(
                DownloadStatus.externalRedirectMessage(detectedURL: item.externalRedirectURL))
        }

        // Auto-retry once on "empty success" — yt-dlp or gallery-dl exited 0
        // without producing any media. Most often a transient X GraphQL
        // hiccup (token rotation, brief rate-limit, cache miss) that one
        // extra attempt clears. Genuinely-unreachable tweets just hit the
        // same outcome and stay Failed. Real errors (non-zero exit codes)
        // don't match the predicate below and skip the retry, so we don't
        // waste time re-running obvious network/auth failures.
        let isEmptySuccess: Bool = {
            guard case .failed(let msg) = item.status else { return false }
            return Self.isEmptySuccessMessage(msg)
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

    /// Mixed video+photo posts: yt-dlp captures the video(s) and exits 0 —
    /// deliberately skipping the photos — and success bypasses the
    /// failure-driven fallback chain, so without this pass the photos would
    /// silently vanish. Runs only for profiles declaring `imageSweepArgs`.
    /// A Pause pressed during the sweep only stops the sweep — the video
    /// already landed, so the row completes; the stale pause request must be
    /// consumed here or the item's NEXT run would misread it as a pause.
    private func runImageSweepIfNeeded(_ item: DownloadItem) async {
        // Audio-only is an explicit opt-out of visual media: sweeping would
        // download photos the user didn't ask for and recomputeMediaCategory
        // would overwrite the explicitly-set .audio category.
        guard youtubeFormat != .audioOnly,
            SiteRegistry.profile(for: item.url).imageSweepArgs != nil,
            let gdlPath = galleryDlPath
        else { return }
        let cookies = resolveCookiesForDownload()
        await cookieAccess.withScope(for: item.id, file: cookies.path, grantedURL: cookies.granted) {
            await GalleryDlService.runImageSweep(
                item: item,
                executablePath: gdlPath,
                outputDirectory: outputDirectory,
                cookieBrowser: cookieBrowser,
                cookieBrowserProfile: cookieBrowserProfile,
                cookiesFile: cookies.path,
                register: { [weak self] p in self?.activeProcesses[item.id] = p },
                unregister: { [weak self] in self?.activeProcesses.removeValue(forKey: item.id) }
            )
        }
        pausedItemIDs.remove(item.id)
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
                cookieBrowserProfile: cookieBrowserProfile,
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
    // "igsh" is Instagram's share-link tracking param (?igsh=…), and "igshid"
    // its older spelling still present in countless shared links — same dedup story.
    private static let trackingParamsExact = Set([
        "si", "s", "t", "ref", "ref_src", "ref_url", "fbclid", "gclid", "msclkid", "igsh", "igshid",
    ])

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
