import Foundation
import AppKit
import SwiftUI

@MainActor
class DownloadManager: ObservableObject {

    // MARK: - Published state

    @Published var items: [DownloadItem] = []
    @Published var outputDirectory: URL
    @Published var cookieBrowser: CookieBrowser = .safari
    @Published var maxConcurrent: Int = 2
    @Published var showDownloadDate: Bool = false
    @Published var youtubeFormat: YouTubeFormat = .videoAndAudio
    @Published var videoQuality: VideoQuality = .best
    @Published var audioQuality: AudioQuality = .best
    @Published var subtitleLanguage: SubtitleLanguage = .none
    @Published var embedSubtitles: Bool = true
    @Published var openPreference: OpenPreference = .video
    @Published var autoDownloadOnPaste: Bool = false
    @Published var missingTools: [ToolRequirement] = []
    @Published var notice: String? = nil

    // MARK: - Private state

    private var activeProcesses: [UUID: Process] = [:]
    private var downloadQueue: [DownloadItem] = []
    private var activeCount: Int = 0
    private var noticeTask: Task<Void, Never>?

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
        checkRequirements()
    }

    func checkRequirements() {
        missingTools = RequirementsService.missingTools()
    }

    // MARK: - Queue management

    func addDownload(urlString: String) {
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

        let item = DownloadItem(url: stripped)
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
        item.imageCount    = nil
        item.videoCount    = nil
        item.mediaCategory = .unknown
        item.retryCount   += 1
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
        d.set(videoQuality.rawValue,          forKey: "videoQuality")
        d.set(audioQuality.rawValue,          forKey: "audioQuality")
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
        if let r = d.string(forKey: "videoQuality"),    let v = VideoQuality(rawValue: r)     { videoQuality = v }
        if let r = d.string(forKey: "audioQuality"),    let v = AudioQuality(rawValue: r)     { audioQuality = v }
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
        if youtubeFormat == .audioOnly { item.mediaCategory = .audio }

        let args = YtDlpService.buildArguments(
            for: item,
            outputDirectory: outputDirectory,
            format: youtubeFormat,
            videoQuality: videoQuality,
            audioQuality: audioQuality,
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
