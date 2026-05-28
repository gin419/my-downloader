import Foundation

enum YtDlpService {

    // MARK: - Argument building

    static func buildArguments(
        for item: DownloadItem,
        outputDirectory: URL,
        format: YouTubeFormat,
        subtitleLanguage: SubtitleLanguage,
        embedSubtitles: Bool,
        cookieBrowser: CookieBrowser
    ) -> [String] {
        let outputTemplate = outputDirectory.path + "/%(uploader)s - %(title)s.%(ext)s"
        var args: [String] = []

        if cookieBrowser != .none {
            args += ["--cookies-from-browser", cookieBrowser.rawValue]
        }

        let isYouTube = item.url.contains("youtube.com/") || item.url.contains("youtu.be/")

        switch format {
        case .audioOnly:
            args += [
                "--format", "bestaudio/best",
                "--extract-audio",
                "--audio-format", "mp3",
                "--audio-quality", "0",
            ]
        case .singleFile:
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

        if isYouTube && format != .audioOnly && subtitleLanguage != .none {
            args += ["--write-sub", "--write-auto-sub", "--sub-lang", subtitleLanguage.rawValue]
            if embedSubtitles { args += ["--embed-subs"] }
        }

        args += [
            "--output", outputTemplate,
            "--socket-timeout", "10",
            "--progress",
            "--newline",
            item.url,
        ]

        return args
    }

    // MARK: - Output parsing

    /// Parse one line of yt-dlp stdout/stderr, updating `item` in place.
    /// `terminate` is called when yt-dlp is detected following an external redirect
    /// out of an X.com tweet — the caller should kill the process so gallery-dl can take over.
    @MainActor
    static func parseLine(_ line: String, item: DownloadItem, terminate: () -> Void) {
        guard !line.isEmpty else { return }

        // Progress: [download]  45.3% of  15.42MiB at  2.34MiB/s ETA 00:05
        if line.hasPrefix("[download]") && line.contains("%") {
            item.status = .downloading
            let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            for (i, token) in tokens.enumerated() {
                if token.hasSuffix("%"), let pct = Double(token.dropLast()) {
                    item.progress = min(pct / 100.0, 1.0)
                }
                if token == "of",  i + 1 < tokens.count { item.totalSize = tokens[i + 1] }
                if token == "at",  i + 1 < tokens.count { item.speed    = tokens[i + 1] }
                if token == "ETA", i + 1 < tokens.count { item.eta      = tokens[i + 1] }
            }
            return
        }

        // Destination: track video/audio/image paths and infer title
        if line.hasPrefix("[download]") && line.contains("Destination:"),
           let range = line.range(of: "Destination: ") {
            let path = String(line[range.upperBound...])
            let ext  = (path as NSString).pathExtension.lowercased()
            let isImage = ["jpg", "jpeg", "png", "webp"].contains(ext)
            let isAudio = ["m4a", "aac", "ogg", "opus", "weba"].contains(ext)

            if !isImage {
                if isAudio { item.audioPath = path } else { item.videoPath = path }
                item.outputPath = path
            } else if item.outputPath == nil {
                item.outputPath = path
            }

            if item.title == nil {
                var stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                if isImage, let r = stem.range(of: #"_\d+$"#, options: .regularExpression) {
                    stem = String(stem[..<r.lowerBound])
                }
                if let r = stem.range(of: " - ") { item.title = String(stem[r.upperBound...]) }
            }
            if isImage { item.imageCount = (item.imageCount ?? 0) + 1 }
            return
        }

        // Merger: final merged output file
        if (line.hasPrefix("[Merger]") || line.hasPrefix("[ffmpeg]")) && line.contains("Merging formats into"),
           let q1 = line.firstIndex(of: "\""),
           let q2 = line.lastIndex(of: "\""),
           q1 != q2 {
            let path = String(line[line.index(after: q1)..<q2])
            item.videoPath  = path
            item.outputPath = path
            return
        }

        // ExtractAudio: final audio-only output file
        if line.hasPrefix("[ExtractAudio]") && line.contains("Destination:"),
           let range = line.range(of: "Destination: ") {
            let path = String(line[range.upperBound...])
            item.audioPath  = path
            item.outputPath = path
            return
        }

        // External redirect detection: yt-dlp followed a link out of the tweet.
        // Kill the process immediately so gallery-dl can handle the original tweet URL.
        let isXUrl = item.url.contains("x.com/") || item.url.contains("twitter.com/")
        if isXUrl,
           (line.hasPrefix("[generic]") || line.hasPrefix("[redirect]")),
           let urlRange = line.range(of: "(?:Extracting URL|Following redirect to): (https?://\\S+)", options: .regularExpression),
           let detected = line[urlRange].components(separatedBy: ": ").last,
           !detected.contains("x.com"),
           !detected.contains("twitter.com"),
           !detected.contains("twimg.com") {
            terminate()
            item.status = .failed("external_redirect")
            return
        }

        // Errors
        let lower = line.lowercased()
        if lower.contains("error:") {
            if case .failed = item.status { return }
            item.status = .failed(line)
        }
    }
}
