import Foundation
import AppKit
import SwiftUI

@MainActor
class DownloadManager: ObservableObject {

    // MARK: - Published state

    @Published var items: [DownloadItem] = []
    @Published var outputDirectory: URL
    @Published var cookieBrowser: CookieBrowser = .safari
    @Published var cookiesFilePath: String? = nil   // display / last resolved path
    private var cookiesFileBookmarkData: Data?       // security-scoped bookmark for sandboxed file access
    private var _bookmarkForDeinit: Data?            // non-isolated copy for deinit cleanup (avoids actor isolation in deinit)
    @Published var maxConcurrent: Int = 2
    @Published var showDownloadDate: Bool = false
    @Published var youtubeFormat: YouTubeFormat = .videoAndAudio
    @Published var videoQuality: VideoQuality = .best
    @Published var audioQuality: AudioQuality = .best
    @Published var subtitleLanguage: SubtitleLanguage = .none
    @Published var embedSubtitles: Bool = true
    @Published var openPreference: OpenPreference = .video
    @Published var autoDownloadOnPaste: Bool = false
    @Published var saveHistoryEnabled: Bool = true
    @Published var historyCount: Int = 0
    @Published var historySizeBytes: Int64 = 0
    @Published var pendingDuplicate: DuplicateConfirmation? = nil
    @Published var missingTools: [ToolRequirement] = []
    @Published var notice: String? = nil

    // MARK: - Private state

    private var activeProcesses: [UUID: Process] = [:]
    /// In-flight FxTwitterService fallbacks — URLSession Tasks, so they need
    /// Task.cancel() rather than Process.terminate() when the user hits Stop.
    private var activeFxTasks: [UUID: Task<Bool, Never>] = [:]
    private var downloadQueue: [DownloadItem] = []
    private var activeCount: Int = 0
    private var noticeTask: Task<Void, Never>?
    /// IDs of items the user explicitly paused — distinguishes a user-initiated
    /// `terminate()` from a real download failure when the process exits.
    private var pausedItemIDs: Set<UUID> = []
    private let history = HistoryStore()

    // Resolved at runtime via RequirementsService so paths stay in one place.
    private var ytdlpPath: String  { RequirementsService.ytdlp.installedPath    ?? "yt-dlp"     }
    private var galleryDlPath: String? { RequirementsService.galleryDl.installedPath }

    // MARK: - Init

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = downloads.appendingPathComponent("X-Videos")
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        self.outputDirectory = defaultDir

        loadSettings()
        loadQueue()
        checkRequirements()
        refreshHistoryStats()
        drainQueue()
    }

    deinit {
        // Use the non-isolated copy to avoid actor-isolated call in deinit
        if let data = _bookmarkForDeinit {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    func checkRequirements() {
        missingTools = RequirementsService.missingTools()
    }

    // MARK: - Queue management

    func addDownload(urlString: String) {
        addDownload(urlString: urlString, skipHistoryCheck: false)
    }

    /// `skipHistoryCheck` is set by `confirmDuplicateDownload` so the user's
    /// "Download again" choice doesn't re-trigger the same warning.
    private func addDownload(urlString: String, skipHistoryCheck: Bool) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stripped = stripTrackingParams(trimmed)

        if let existing = items.first(where: { $0.url == stripped }) {
            switch existing.status {
            case .completed:
                showNotice("Already downloaded — clear the completed item to re-download.")
            default:
                showNotice("Already in the download queue.")
            }
            return
        }

        if saveHistoryEnabled, !skipHistoryCheck, let prior = history.mostRecentCompleted(for: stripped) {
            let fileExists = prior.outputPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            pendingDuplicate = DuplicateConfirmation(
                url: stripped,
                priorEntry: prior,
                priorFileExists: fileExists
            )
            return
        }

        let item = DownloadItem(url: stripped)
        items.insert(item, at: 0)
        downloadQueue.append(item)
        saveQueue()
        drainQueue()
    }

    func confirmDuplicateDownload() {
        guard let dup = pendingDuplicate else { return }
        pendingDuplicate = nil
        addDownload(urlString: dup.url, skipHistoryCheck: true)
    }

    func dismissDuplicate() {
        pendingDuplicate = nil
    }

    func revealDuplicatePriorFile() {
        guard let dup = pendingDuplicate, let path = dup.priorEntry.outputPath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        pendingDuplicate = nil
    }

    func retryItem(_ item: DownloadItem) {
        item.status     = .queued
        item.progress   = 0
        item.speed      = nil
        item.eta        = nil
        item.totalSize  = nil
        item.outputPath = nil
        item.videoPath  = nil
        item.audioPath  = nil
        item.title      = nil
        item.imageCount    = nil
        item.videoCount    = nil
        item.mediaCategory = .unknown
        item.lastToolWarning = nil
        item.subtitleDownloadFailed = false
        item.subtitlesDisabled      = false
        item.retryCount   += 1
        downloadQueue.append(item)
        saveQueue()
        drainQueue()
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
    /// Starts (or restarts) security-scoped access for the stored bookmark and returns the usable path for --cookies.
    /// Must be called before passing the path to yt-dlp / gallery-dl.
    func beginAccessingCookiesFile() -> String? {
        guard let data = cookiesFileBookmarkData else { return cookiesFilePath }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        if url.startAccessingSecurityScopedResource() {
            cookiesFilePath = url.path   // update display to current location
            return url.path
        }
        return nil
    }

    func setCookiesFile(from url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            // stop any previous
            stopAccessingCookiesFile()
            cookiesFileBookmarkData = data
            _bookmarkForDeinit = data
            cookiesFilePath = url.path
            _ = beginAccessingCookiesFile()
            saveSettings()
        } catch {
            // last resort plain path (no sandbox grant)
            cookiesFileBookmarkData = nil
            cookiesFilePath = url.path
            saveSettings()
        }
    }

    func clearCookiesFile() {
        stopAccessingCookiesFile()
        cookiesFileBookmarkData = nil
        _bookmarkForDeinit = nil
        cookiesFilePath = nil
        saveSettings()
    }

    private func stopAccessingCookiesFile() {
        guard let data = cookiesFileBookmarkData else { return }
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            url.stopAccessingSecurityScopedResource()
        }
        _bookmarkForDeinit = nil
    }

    // MARK: - Settings

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(outputDirectory.absoluteString, forKey: "outputDirectory")
        d.set(cookieBrowser.rawValue,         forKey: "cookieBrowser")
        d.set(cookiesFilePath,                forKey: "cookiesFilePath")
        if let bm = cookiesFileBookmarkData {
            d.set(bm, forKey: "cookiesFileBookmarkData")
        } else {
            d.removeObject(forKey: "cookiesFileBookmarkData")
        }
        d.set(showDownloadDate,               forKey: "showDownloadDate")
        d.set(youtubeFormat.rawValue,         forKey: "youtubeFormat")
        d.set(videoQuality.rawValue,          forKey: "videoQuality")
        d.set(audioQuality.rawValue,          forKey: "audioQuality")
        d.set(subtitleLanguage.rawValue,      forKey: "subtitleLanguage")
        d.set(embedSubtitles,                 forKey: "embedSubtitles")
        d.set(maxConcurrent,                  forKey: "maxConcurrent")
        d.set(openPreference.rawValue,        forKey: "openPreference")
        d.set(autoDownloadOnPaste,            forKey: "autoDownloadOnPaste")
        d.set(saveHistoryEnabled,             forKey: "saveHistoryEnabled")
    }

    // MARK: - Private

    private func loadSettings() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "outputDirectory"), let u = URL(string: s) { outputDirectory = u }
        if let r = d.string(forKey: "cookieBrowser"),   let v = CookieBrowser(rawValue: r)    { cookieBrowser = v }
        if let p = d.string(forKey: "cookiesFilePath"), !p.isEmpty { cookiesFilePath = p } else { cookiesFilePath = nil }
        if let data = d.data(forKey: "cookiesFileBookmarkData") { 
            cookiesFileBookmarkData = data 
            _bookmarkForDeinit = data
        }
        if let r = d.string(forKey: "youtubeFormat"),   let v = YouTubeFormat(rawValue: r)    { youtubeFormat = v }
        if let r = d.string(forKey: "videoQuality"),    let v = VideoQuality(rawValue: r)     { videoQuality = v }
        if let r = d.string(forKey: "audioQuality"),    let v = AudioQuality(rawValue: r)     { audioQuality = v }
        if let r = d.string(forKey: "subtitleLanguage"),let v = SubtitleLanguage(rawValue: r) { subtitleLanguage = v }
        if let r = d.string(forKey: "openPreference"),  let v = OpenPreference(rawValue: r)   { openPreference = v }
        showDownloadDate  = d.bool(forKey: "showDownloadDate")
        embedSubtitles    = d.object(forKey: "embedSubtitles") as? Bool ?? true
        autoDownloadOnPaste = d.bool(forKey: "autoDownloadOnPaste")
        saveHistoryEnabled = d.object(forKey: "saveHistoryEnabled") as? Bool ?? true
        let stored = d.integer(forKey: "maxConcurrent")
        if stored > 0 { maxConcurrent = stored }
        // Start access early if we have a bookmark (best effort)
        if cookiesFileBookmarkData != nil { _ = beginAccessingCookiesFile() }
    }

    private func drainQueue() {
        while activeCount < maxConcurrent, !downloadQueue.isEmpty {
            let item = downloadQueue.removeFirst()
            activeCount += 1
            Task {
                await runDownload(item)
                activeCount -= 1
                drainQueue()
            }
        }
    }

    private func runDownload(_ item: DownloadItem) async {
        item.status = .fetching
        if youtubeFormat == .audioOnly { item.mediaCategory = .audio }

        // A prior run hit a subtitle 429 and aborted before saving the video —
        // drop subtitles on the retry so the video itself can download.
        let effectiveSubtitleLanguage: SubtitleLanguage = item.subtitlesDisabled ? .none : subtitleLanguage

        let fileToPass = beginAccessingCookiesFile()
        let args = YtDlpService.buildArguments(
            for: item,
            outputDirectory: outputDirectory,
            format: youtubeFormat,
            videoQuality: videoQuality,
            audioQuality: audioQuality,
            subtitleLanguage: effectiveSubtitleLanguage,
            embedSubtitles: embedSubtitles,
            cookieBrowser: cookieBrowser,
            cookiesFile: fileToPass
        )

        let exitCode = await runProcess(
            executablePath: ytdlpPath,
            arguments: args,
            item: item,
            register:   { [weak self] p in self?.activeProcesses[item.id] = p },
            unregister: { [weak self]   in self?.activeProcesses.removeValue(forKey: item.id) },
            lineParser: { [weak self] line, item in
                YtDlpService.parseLine(line, item: item) {
                    self?.activeProcesses[item.id]?.terminate()
                }
            }
        )

        // "Empty success": yt-dlp can exit 0 without writing any file. Seen on
        // Twitter for text-only tweets, quote-RTs whose referenced media yt-dlp
        // can't reach, and sensitive content the current cookies don't unlock. Use cookies.txt export for X NSFW videos.
        // Use a cookies.txt export (Settings) for X adult/NSFW media that browser cookies can't reach.
        // gallery-dl often picks these up, so treat it the same as a non-zero
        // exit and let the fallback below try.
        let mediaCaptured = item.outputPath != nil
        var hasFatalError = false; if case .failed = item.status { hasFatalError = true }
        // Subtitles are best-effort: if the video already reached disk but yt-dlp
        // exited non-zero *only* because the (optional) subtitle download was
        // rate-limited, keep the video rather than failing. Scoped to the
        // subtitle case so other non-zero exits (e.g. a Twitter multi-video tweet
        // that partially downloaded) still fall through to the fallback below.
        let subtitleOnlyFailure = item.subtitleDownloadFailed && !hasFatalError
        if mediaCaptured && (exitCode == 0 || subtitleOnlyFailure) {
            item.status   = .completed
            item.progress = 1.0
            item.speed    = nil
            item.eta      = nil
            finalize(item)
            return
        }

        // User pressed Stop: the non-zero exit was our own terminate(). Freeze the
        // row at its current progress so Resume can pick up from the .part file.
        if pausedItemIDs.remove(item.id) != nil {
            item.status = .paused
            item.speed  = nil
            item.eta    = nil
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
            item.status   = .fetching
            item.progress = 0
            item.speed    = nil
            item.eta      = nil
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
            if case .completed = item.status { break }   // a prior fallback already won
            switch fallback {
            case .galleryDl:
                guard let gdlPath = galleryDlPath else { continue }   // tool not installed
                ranFallback = true
                await runGalleryDlFallback(item, executablePath: gdlPath)
            case .fxTwitter:
                guard case .failed = item.status else { continue }    // only as a rescue
                ranFallback = true
                if await runFxTwitterFallback(item) { return }        // user pressed Stop mid-run
            }
        }

        // No fallback ran (none declared for this site, or gallery-dl missing) —
        // finalize yt-dlp's own outcome.
        if !ranFallback {
            if case .failed = item.status {
                // already set by YtDlpService
            } else if exitCode == 0 {
                item.status = .failed("yt-dlp reported success but found no media to download.")
            } else {
                item.status = .failed("yt-dlp exited with code \(exitCode)")
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
            item.status        = .fetching
            item.progress      = 0
            item.speed         = nil
            item.eta           = nil
            item.imageCount    = nil
            item.videoCount    = nil
            item.outputPath    = nil
            item.videoPath     = nil
            item.audioPath     = nil
            item.title         = nil
            item.mediaCategory = .unknown
            item.lastToolWarning = nil
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
        item.status     = .fetching
        item.progress   = 0
        item.imageCount = nil
        item.outputPath = nil
        item.videoPath  = nil
        item.audioPath  = nil
        item.title      = nil
        item.lastToolWarning = nil

        let fileToPass = beginAccessingCookiesFile()
        await GalleryDlService.run(
            item: item,
            executablePath: executablePath,
            outputDirectory: outputDirectory,
            cookieBrowser: cookieBrowser,
            cookiesFile: fileToPass,
            register:   { [weak self] p in self?.activeProcesses[item.id] = p },
            unregister: { [weak self]   in self?.activeProcesses.removeValue(forKey: item.id) }
        )
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
            item.speed  = nil
            item.eta    = nil
            saveQueue()
            return true
        }
        return false
    }

    private func finalize(_ item: DownloadItem) {
        saveQueue()
        recordHistory(for: item)
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
                  let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { return nil }
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

    private func showNotice(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) { notice = message }
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) { notice = nil }
            }
        }
    }

    // MARK: - Queue persistence

    private var queueFileURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("XDownloader", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json")
    }

    private func saveQueue() {
        let snapshot = items.map { $0.toPersisted() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            // best-effort: don't surface persistence failures to the user
        }
    }

    private func loadQueue() {
        let url = queueFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let persisted = try? JSONDecoder().decode([PersistedDownloadItem].self, from: data) else {
            return
        }

        // Preserve display order (newest first). Re-queue non-completed items
        // in original chronological order (oldest first) so they download in
        // the same sequence as before the crash/quit.
        let restored = persisted.map { DownloadItem(persisted: $0) }

        // Self-heal v1.3.0-era "empty success" rows: marked Done but no file
        // was ever recorded (no title/media chip in the UI). Re-queue them so
        // they run through the current yt-dlp → gallery-dl → fxtwitter chain
        // instead of posing as completed forever.
        for item in restored where item.status == .completed
            && item.outputPath == nil && item.videoPath == nil && item.audioPath == nil {
            item.status = .queued
        }

        items = restored
        for item in restored.reversed() where item.status != .completed && item.status != .paused {
            downloadQueue.append(item)
        }
    }

    private static let trackingParamsExact = Set(["si", "s", "ref", "ref_src", "ref_url", "fbclid", "gclid", "msclkid"])

    private func stripTrackingParams(_ urlString: String) -> String {
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
