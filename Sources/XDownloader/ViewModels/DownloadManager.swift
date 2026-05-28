import Foundation
import AppKit

@MainActor
class DownloadManager: ObservableObject {

    // MARK: - Published state

    @Published var items: [DownloadItem] = []
    @Published var outputDirectory: URL
    @Published var cookieBrowser: CookieBrowser = .safari
    @Published var maxConcurrent: Int = 2
    @Published var showDownloadDate: Bool = false
    @Published var youtubeFormat: YouTubeFormat = .videoAndAudio
    @Published var subtitleLanguage: SubtitleLanguage = .none
    @Published var embedSubtitles: Bool = true
    @Published var openPreference: OpenPreference = .video
    @Published var autoDownloadOnPaste: Bool = false

    // MARK: - Private state

    private var activeProcesses: [UUID: Process] = [:]
    private var downloadQueue: [DownloadItem] = []
    private var activeCount: Int = 0

    private let ytdlpPath: String = {
        for p in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return "yt-dlp"
    }()

    private let galleryDlPath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/gallery-dl",
            "/usr/local/bin/gallery-dl",
            "\(home)/Library/Python/3.9/bin/gallery-dl",
            "\(home)/Library/Python/3.10/bin/gallery-dl",
            "\(home)/Library/Python/3.11/bin/gallery-dl",
            "\(home)/Library/Python/3.12/bin/gallery-dl",
            "\(home)/Library/Python/3.13/bin/gallery-dl",
            "\(home)/.local/bin/gallery-dl",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }()

    // MARK: - Init

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = downloads.appendingPathComponent("X-Videos")
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        self.outputDirectory = defaultDir

        loadSettings()
    }

    // MARK: - Queue management

    func addDownload(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = DownloadItem(url: stripTrackingParams(trimmed))
        items.insert(item, at: 0)
        downloadQueue.append(item)
        drainQueue()
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
        item.imageCount = nil
        item.retryCount += 1
        downloadQueue.append(item)
        drainQueue()
    }

    func removeItem(_ item: DownloadItem) {
        activeProcesses[item.id]?.terminate()
        activeProcesses.removeValue(forKey: item.id)
        downloadQueue.removeAll { $0.id == item.id }
        items.removeAll { $0.id == item.id }
    }

    func clearCompleted() {
        items.removeAll { $0.status == .completed }
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

    // MARK: - Settings

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(outputDirectory.absoluteString, forKey: "outputDirectory")
        d.set(cookieBrowser.rawValue,         forKey: "cookieBrowser")
        d.set(showDownloadDate,               forKey: "showDownloadDate")
        d.set(youtubeFormat.rawValue,         forKey: "youtubeFormat")
        d.set(subtitleLanguage.rawValue,      forKey: "subtitleLanguage")
        d.set(embedSubtitles,                 forKey: "embedSubtitles")
        d.set(maxConcurrent,                  forKey: "maxConcurrent")
        d.set(openPreference.rawValue,        forKey: "openPreference")
        d.set(autoDownloadOnPaste,            forKey: "autoDownloadOnPaste")
    }

    // MARK: - Private

    private func loadSettings() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "outputDirectory"), let u = URL(string: s) { outputDirectory = u }
        if let r = d.string(forKey: "cookieBrowser"),   let v = CookieBrowser(rawValue: r)    { cookieBrowser = v }
        if let r = d.string(forKey: "youtubeFormat"),   let v = YouTubeFormat(rawValue: r)    { youtubeFormat = v }
        if let r = d.string(forKey: "subtitleLanguage"),let v = SubtitleLanguage(rawValue: r) { subtitleLanguage = v }
        if let r = d.string(forKey: "openPreference"),  let v = OpenPreference(rawValue: r)   { openPreference = v }
        showDownloadDate  = d.bool(forKey: "showDownloadDate")
        embedSubtitles    = d.object(forKey: "embedSubtitles") as? Bool ?? true
        autoDownloadOnPaste = d.bool(forKey: "autoDownloadOnPaste")
        let stored = d.integer(forKey: "maxConcurrent")
        if stored > 0 { maxConcurrent = stored }
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

        let args = YtDlpService.buildArguments(
            for: item,
            outputDirectory: outputDirectory,
            format: youtubeFormat,
            subtitleLanguage: subtitleLanguage,
            embedSubtitles: embedSubtitles,
            cookieBrowser: cookieBrowser
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

        if exitCode == 0 {
            item.status   = .completed
            item.progress = 1.0
            item.speed    = nil
            item.eta      = nil
            return
        }

        // yt-dlp failed on an X.com URL — try gallery-dl as fallback for image tweets.
        let isXUrl = item.url.contains("x.com/") || item.url.contains("twitter.com/")
        if isXUrl, let gdlPath = galleryDlPath {
            item.status     = .fetching
            item.progress   = 0
            item.imageCount = nil
            item.outputPath = nil
            item.videoPath  = nil
            item.audioPath  = nil
            item.title      = nil

            await GalleryDlService.run(
                item: item,
                executablePath: gdlPath,
                outputDirectory: outputDirectory,
                cookieBrowser: cookieBrowser,
                register:   { [weak self] p in self?.activeProcesses[item.id] = p },
                unregister: { [weak self]   in self?.activeProcesses.removeValue(forKey: item.id) }
            )
        } else if case .failed = item.status {
            // already set by YtDlpService
        } else {
            item.status = .failed("yt-dlp exited with code \(exitCode)")
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
