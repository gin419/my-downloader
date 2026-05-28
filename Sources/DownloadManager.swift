import Foundation
import AppKit

enum YouTubeFormat: String, CaseIterable, Identifiable {
    case videoAndAudio = "video"
    case singleFile = "videoOnly"   // pre-muxed video+audio in one file, no merge step
    case audioOnly = "audio"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .videoAndAudio: return "Video + Audio"
        case .singleFile: return "Single File"
        case .audioOnly: return "Audio Only"
        }
    }
}

enum SubtitleLanguage: String, CaseIterable, Identifiable {
    case none = ""
    case english = "en"
    case chineseTraditional = "zh-Hant"
    case chineseSimplified = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .english: return "English"
        case .chineseTraditional: return "Chinese (Traditional)"
        case .chineseSimplified: return "Chinese (Simplified)"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .spanish: return "Spanish"
        case .french: return "French"
        }
    }
}

enum OpenPreference: String, CaseIterable, Identifiable {
    case video = "video"
    case audio = "audio"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        }
    }
}

enum CookieBrowser: String, CaseIterable, Identifiable {
    case safari = "safari"
    case chrome = "chrome"
    case firefox = "firefox"
    case edge = "edge"
    case none = ""

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        case .edge: return "Edge"
        case .none: return "None"
        }
    }
}

@MainActor
class DownloadManager: ObservableObject {
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

    private var activeProcesses: [UUID: Process] = [:]
    private var downloadQueue: [DownloadItem] = []
    private var activeCount: Int = 0

    private let ytdlpPath: String = {
        for candidate in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"] {
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
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
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }()

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = downloads.appendingPathComponent("X-Videos")
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        self.outputDirectory = defaultDir

        if let saved = UserDefaults.standard.string(forKey: "outputDirectory"),
           let url = URL(string: saved) {
            self.outputDirectory = url
        }
        if let raw = UserDefaults.standard.string(forKey: "cookieBrowser"),
           let browser = CookieBrowser(rawValue: raw) {
            self.cookieBrowser = browser
        }
        self.showDownloadDate = UserDefaults.standard.bool(forKey: "showDownloadDate")
        if let raw = UserDefaults.standard.string(forKey: "youtubeFormat"),
           let fmt = YouTubeFormat(rawValue: raw) {
            self.youtubeFormat = fmt
        }
        if let raw = UserDefaults.standard.string(forKey: "subtitleLanguage"),
           let lang = SubtitleLanguage(rawValue: raw) {
            self.subtitleLanguage = lang
        }
        self.embedSubtitles = UserDefaults.standard.object(forKey: "embedSubtitles") as? Bool ?? true
        let storedConcurrent = UserDefaults.standard.integer(forKey: "maxConcurrent")
        if storedConcurrent > 0 { self.maxConcurrent = storedConcurrent }
        if let raw = UserDefaults.standard.string(forKey: "openPreference"),
           let pref = OpenPreference(rawValue: raw) {
            self.openPreference = pref
        }
        self.autoDownloadOnPaste = UserDefaults.standard.bool(forKey: "autoDownloadOnPaste")
    }

    func addDownload(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let item = DownloadItem(url: stripTrackingParams(trimmed))
        items.insert(item, at: 0)
        downloadQueue.append(item)
        drainQueue()
    }

    func retryItem(_ item: DownloadItem) {
        item.status = .queued
        item.progress = 0
        item.speed = nil
        item.eta = nil
        item.totalSize = nil
        item.outputPath = nil
        item.videoPath = nil
        item.audioPath = nil
        item.title = nil
        item.imageCount = nil
        item.retryCount += 1
        downloadQueue.append(item)
        drainQueue()
    }

    private static let trackingParamsExact = Set(["si", "s", "ref", "ref_src", "ref_url", "fbclid", "gclid", "msclkid"])

    private func stripTrackingParams(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }
        components.queryItems = components.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !Self.trackingParamsExact.contains(name)
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url?.absoluteString ?? urlString
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

        let outputTemplate = outputDirectory.path + "/%(uploader)s - %(title)s.%(ext)s"
        var args: [String] = []

        if cookieBrowser != .none {
            args += ["--cookies-from-browser", cookieBrowser.rawValue]
        }

        let isYouTube = item.url.contains("youtube.com/") || item.url.contains("youtu.be/")

        // Format applies to all yt-dlp downloads (YouTube, X.com, etc.)
        switch youtubeFormat {
        case .audioOnly:
            args += [
                "--format", "bestaudio/best",
                "--extract-audio",
                "--audio-format", "mp3",
                "--audio-quality", "0",
            ]
        case .singleFile:
            // Best pre-muxed format that already contains both video and audio in one file.
            // acodec!=none ensures we never pick a silent stream.
            args += [
                "--format", "bestvideo*[acodec!=none][ext=mp4]/best[ext=mp4]/best",
                "--merge-output-format", "mp4",
            ]
        case .videoAndAudio:
            args += [
                "--format", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best",
                "--merge-output-format", "mp4",
            ]
        }

        // Subtitles are YouTube-specific
        if isYouTube && youtubeFormat != .audioOnly && subtitleLanguage != .none {
            args += [
                "--write-sub",
                "--write-auto-sub",
                "--sub-lang", subtitleLanguage.rawValue,
            ]
            if embedSubtitles {
                args += ["--embed-subs"]
            }
        }

        args += [
            "--output", outputTemplate,
            "--socket-timeout", "10",
            "--progress",
            "--newline",
            item.url,
        ]

        let exitCode = await runProcess(
            executablePath: ytdlpPath,
            arguments: args,
            item: item,
            lineParser: { [weak self] line, item in self?.parseLine(line, item: item) }
        )

        if exitCode == 0 {
            item.status = .completed
            item.progress = 1.0
            item.speed = nil
            item.eta = nil
            return
        }

        // yt-dlp failed on an X.com/Twitter URL — try gallery-dl as fallback for image tweets.
        // This covers two cases:
        //   1. "No video could be found in this tweet" — image-only tweet
        //   2. yt-dlp follows an external link in the tweet text and fails there
        //      instead of downloading the actual tweet image(s).
        let isXUrl = item.url.contains("x.com/") || item.url.contains("twitter.com/")
        if isXUrl, let gdlPath = galleryDlPath {
            item.status = .fetching
            item.progress = 0
            item.imageCount = nil
            item.outputPath = nil
            item.videoPath = nil
            item.audioPath = nil
            item.title = nil
            await runGalleryDl(item, executablePath: gdlPath)
        } else {
            // yt-dlp failed and there is no gallery-dl fallback for this URL —
            // guarantee the item ends up in a terminal failed state.
            if case .failed = item.status { } else {
                item.status = .failed("yt-dlp exited with code \(exitCode)")
            }
        }
    }

    private func runGalleryDl(_ item: DownloadItem, executablePath: String) async {
        // Snapshot directory before download to detect newly created files.
        // This lets us find the output path even when gallery-dl skips existing files.
        let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? [])

        var args: [String] = []
        if cookieBrowser != .none {
            args += ["--cookies-from-browser", cookieBrowser.rawValue]
        }
        // Flat output, filename format matching yt-dlp: "DisplayName - Tweet text #N.ext"
        // The #{num} suffix is stripped later if only 1 image is downloaded.
        args += [
            "--dest", outputDirectory.path,
            "-D", ".",
            "-f", "{author[nick]} - {content:.100} #{num}.{extension}",
            "--no-mtime",
            item.url,
        ]

        let exitCode = await runProcess(
            executablePath: executablePath,
            arguments: args,
            item: item,
            lineParser: { [weak self] line, item in self?.parseGalleryDlLine(line, item: item) }
        )

        guard exitCode == 0 else {
            if case .failed = item.status { } else {
                item.status = .failed("gallery-dl exit code \(exitCode)")
            }
            return
        }

        // Find newly created image files (handles both fresh download and skip cases).
        let imageExts = Set(["jpg", "jpeg", "png", "webp", "gif", "avif"])
        let afterFiles = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        let newImageFiles = afterFiles.filter { f in
            !beforeFiles.contains(f) && imageExts.contains(URL(fileURLWithPath: f).pathExtension.lowercased())
        }.sorted()

        // If outputPath was set by parseGalleryDlLine (live download), keep it.
        // Otherwise fall back to the new files we detected (file was already present / skipped).
        if item.outputPath == nil {
            if let first = newImageFiles.first {
                item.outputPath = outputDirectory.appendingPathComponent(first).path
            } else {
                // File was skipped (already existed) — run a quick dry-run to get expected path.
                if let skippedPath = await galleryDlDryRunPath(executablePath: executablePath, item: item) {
                    item.outputPath = skippedPath
                }
            }
        }

        // Count all images belonging to this tweet (share the same stem before " #N").
        let count = newImageFiles.count > 0 ? newImageFiles.count : (item.outputPath != nil ? 1 : 0)
        item.imageCount = count > 0 ? count : nil

        // If exactly 1 image, rename to strip the " #1" suffix → "Name - Tweet.jpg"
        if count == 1, let path = item.outputPath {
            let u = URL(fileURLWithPath: path)
            let stem = u.deletingPathExtension().lastPathComponent
            if stem.hasSuffix(" #1") {
                let cleanStem = String(stem.dropLast(3))
                let newPath = u.deletingLastPathComponent()
                    .appendingPathComponent(cleanStem + "." + u.pathExtension).path
                if (try? FileManager.default.moveItem(atPath: path, toPath: newPath)) != nil {
                    item.outputPath = newPath
                    item.title = cleanStem
                }
            }
        }

        // Extract title from final outputPath if still nil
        if item.title == nil, let path = item.outputPath {
            item.title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }

        item.status = .completed
        item.progress = 1.0
        item.speed = nil
        item.eta = nil
    }

    /// Run gallery-dl in print-only mode to discover the expected output path
    /// without downloading. Used when the file was already present and skipped.
    private func galleryDlDryRunPath(executablePath: String, item: DownloadItem) async -> String? {
        var args: [String] = []
        if cookieBrowser != .none {
            args += ["--cookies-from-browser", cookieBrowser.rawValue]
        }
        args += [
            "--dest", outputDirectory.path,
            "-D", ".",
            "-f", "{author[nick]} - {content:.100} #{num}.{extension}",
            "--print", "filepath",
            item.url,
        ]
        var foundPath: String? = nil
        await runProcess(
            executablePath: executablePath,
            arguments: args,
            item: item,
            lineParser: { line, _ in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("/") && foundPath == nil {
                    // Strip " #1" suffix to match how we rename single images
                    foundPath = trimmed
                }
            }
        )
        // Resolve the actual file: prefer the renamed (no " #1") version, then original.
        // Return nil rather than a path that doesn't exist on disk.
        if let p = foundPath {
            let u = URL(fileURLWithPath: p)
            let stem = u.deletingPathExtension().lastPathComponent
            if stem.hasSuffix(" #1") {
                let cleanPath = u.deletingLastPathComponent()
                    .appendingPathComponent(String(stem.dropLast(3)) + "." + u.pathExtension).path
                if FileManager.default.fileExists(atPath: cleanPath) { return cleanPath }
            }
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    private func runProcess(
        executablePath: String,
        arguments: [String],
        item: DownloadItem,
        lineParser: @escaping (String, DownloadItem) -> Void
    ) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        activeProcesses[item.id] = process
        let itemID = item.id

        let makeHandler: (FileHandle) -> (FileHandle) -> Void = { handle in
            return { [weak self] _ in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor [weak self] in
                    guard let self, let item = self.items.first(where: { $0.id == itemID }) else { return }
                    for line in text.components(separatedBy: .newlines) {
                        lineParser(line.trimmingCharacters(in: .whitespaces), item)
                    }
                }
            }
        }

        stdout.fileHandleForReading.readabilityHandler = makeHandler(stdout.fileHandleForReading)
        stderr.fileHandleForReading.readabilityHandler = makeHandler(stderr.fileHandleForReading)

        do {
            try process.run()
        } catch {
            item.status = .failed(error.localizedDescription)
            activeProcesses.removeValue(forKey: item.id)
            return -1
        }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        activeProcesses.removeValue(forKey: item.id)

        return process.terminationStatus
    }

    private func parseLine(_ line: String, item: DownloadItem) {
        guard !line.isEmpty else { return }

        // Progress line: [download]  45.3% of  15.42MiB at  2.34MiB/s ETA 00:05
        if line.hasPrefix("[download]") && line.contains("%") {
            item.status = .downloading
            let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // find the XX.X% token
            for (i, token) in tokens.enumerated() {
                if token.hasSuffix("%") {
                    let pctStr = String(token.dropLast())
                    if let pct = Double(pctStr) {
                        item.progress = min(pct / 100.0, 1.0)
                    }
                }
                if token == "of" && i + 1 < tokens.count {
                    item.totalSize = tokens[i + 1]
                }
                if token == "at" && i + 1 < tokens.count {
                    item.speed = tokens[i + 1]
                }
                if token == "ETA" && i + 1 < tokens.count {
                    item.eta = tokens[i + 1]
                }
            }
            return
        }

        // Destination line: [download] Destination: /path/to/file
        if line.hasPrefix("[download]") && line.contains("Destination:") {
            if let range = line.range(of: "Destination: ") {
                let path = String(line[range.upperBound...])
                let ext = (path as NSString).pathExtension.lowercased()
                let isImage = ["jpg", "jpeg", "png", "webp"].contains(ext)
                let isAudio = ["m4a", "aac", "ogg", "opus", "weba"].contains(ext)

                if !isImage {
                    if isAudio {
                        item.audioPath = path
                    } else {
                        item.videoPath = path
                    }
                    item.outputPath = path
                } else if item.outputPath == nil {
                    item.outputPath = path
                }
                // Extract title from filename: "Uploader - Title.ext"
                // Strip trailing image index suffix like "_001", "_1" for multi-image tweets
                if item.title == nil {
                    var stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                    if isImage, let indexRange = stem.range(of: #"_\d+$"#, options: .regularExpression) {
                        stem = String(stem[..<indexRange.lowerBound])
                    }
                    if let dashRange = stem.range(of: " - ") {
                        item.title = String(stem[dashRange.upperBound...])
                    }
                }
                if isImage {
                    item.imageCount = (item.imageCount ?? 0) + 1
                }
            }
            return
        }

        // Merger line: [Merger] Merging formats into "/path/to/merged.mp4"
        // This is the final output file for Video+Audio downloads — update outputPath here
        // so clicking the title opens the merged video, not the intermediate audio stream.
        if (line.hasPrefix("[Merger]") || line.hasPrefix("[ffmpeg]")) && line.contains("Merging formats into"),
           let firstQuote = line.firstIndex(of: "\""),
           let lastQuote = line.lastIndex(of: "\""),
           firstQuote != lastQuote {
            let path = String(line[line.index(after: firstQuote)..<lastQuote])
            item.videoPath = path
            item.outputPath = path
            return
        }

        // ExtractAudio line: [ExtractAudio] Destination: /path/to/file.mp3
        // Final file for Audio Only downloads.
        if line.hasPrefix("[ExtractAudio]") && line.contains("Destination:"),
           let range = line.range(of: "Destination: ") {
            let path = String(line[range.upperBound...])
            item.audioPath = path
            item.outputPath = path
            return
        }

        // Detect yt-dlp following an external link out of an X.com tweet.
        // e.g. "[generic] Extracting URL: http://www.nylon-teazer.co.uk"
        // Kill the process immediately so gallery-dl can take over without waiting for SSL timeout.
        let isXUrl = item.url.contains("x.com/") || item.url.contains("twitter.com/")
        if isXUrl,
           (line.hasPrefix("[generic]") || line.hasPrefix("[redirect]")),
           let urlRange = line.range(of: "(?:Extracting URL|Following redirect to): (https?://\\S+)", options: .regularExpression),
           let detectedUrl = line[urlRange].components(separatedBy: ": ").last,
           !detectedUrl.contains("x.com"),
           !detectedUrl.contains("twitter.com"),
           !detectedUrl.contains("twimg.com") {
            activeProcesses[item.id]?.terminate()
            item.status = .failed("external_redirect")
            return
        }

        // Error line
        let lower = line.lowercased()
        if lower.contains("error:") || lower.contains("warning: ") {
            if case .failed = item.status { return }
            // Don't set status to failed on warnings
            if lower.contains("error:") {
                item.status = .failed(line)
            }
            return
        }
    }

    private func parseGalleryDlLine(_ line: String, item: DownloadItem) {
        guard !line.isEmpty else { return }

        // gallery-dl prints the downloaded file path on its own line, e.g.:
        //   /Users/gin/Downloads/X-Videos/twitter/nylonteazer/2059552516027678881_1.jpg
        //
        // Filter out Python/urllib3 warning lines which also start with "/" but look like:
        //   /path/to/site-packages/urllib3/__init__.py:35: NotOpenSSLWarning: ...
        // A real file path has a known media extension; warnings contain ": " after the path.
        if line.hasPrefix("/") || line.hasPrefix("~") {
            let path = line
            let ext = (path as NSString).pathExtension.lowercased()
            let knownMedia = ["jpg", "jpeg", "png", "webp", "gif", "avif", "mp4", "mov", "webm", "m4a", "mp3"]
            guard knownMedia.contains(ext) else { return }   // skip warnings & unknown lines

            let isImage = ["jpg", "jpeg", "png", "webp", "gif", "avif"].contains(ext)
            item.status = .downloading
            item.outputPath = path          // always update so last downloaded file wins
            if isImage {
                item.imageCount = (item.imageCount ?? 0) + 1
            }
            if item.title == nil {
                var stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                if let indexRange = stem.range(of: #"_\d+$"#, options: .regularExpression) {
                    stem = String(stem[..<indexRange.lowerBound])
                }
                item.title = stem
            }
            return
        }

        if line.lowercased().contains("error") {
            if case .failed = item.status { return }
            item.status = .failed(line)
        }
    }

    func removeItem(_ item: DownloadItem) {
        if let process = activeProcesses[item.id] {
            process.terminate()
            activeProcesses.removeValue(forKey: item.id)
        }
        downloadQueue.removeAll { $0.id == item.id }
        items.removeAll { $0.id == item.id }
    }

    func clearCompleted() {
        items.removeAll { $0.status == .completed }
    }

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

    func saveSettings() {
        UserDefaults.standard.set(outputDirectory.absoluteString, forKey: "outputDirectory")
        UserDefaults.standard.set(cookieBrowser.rawValue, forKey: "cookieBrowser")
        UserDefaults.standard.set(showDownloadDate, forKey: "showDownloadDate")
        UserDefaults.standard.set(youtubeFormat.rawValue, forKey: "youtubeFormat")
        UserDefaults.standard.set(subtitleLanguage.rawValue, forKey: "subtitleLanguage")
        UserDefaults.standard.set(embedSubtitles, forKey: "embedSubtitles")
        UserDefaults.standard.set(maxConcurrent, forKey: "maxConcurrent")
        UserDefaults.standard.set(openPreference.rawValue, forKey: "openPreference")
        UserDefaults.standard.set(autoDownloadOnPaste, forKey: "autoDownloadOnPaste")
    }
}
