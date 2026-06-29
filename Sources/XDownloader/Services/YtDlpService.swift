import Foundation

enum YtDlpService {

    // MARK: - Argument building

    static func buildArguments(
        for item: DownloadItem,
        outputDirectory: URL,
        format: YouTubeFormat,
        videoQuality: VideoQuality,
        audioQuality: AudioQuality,
        subtitleLanguage: SubtitleLanguage,
        embedSubtitles: Bool,
        cookieBrowser: CookieBrowser,
        cookiesFile: String? = nil
    ) -> [String] {
        // %(playlist_index& [%(playlist_index)02d]|)s expands to " [01]" etc. only when
        // a tweet contains multiple videos (yt-dlp treats them as a playlist). For
        // single-video tweets playlist_index is not set, so the suffix is empty.
        // Non-Twitter extractors (e.g. Pornhub) trigger a yt-dlp bug where nested
        // %(...)fmt patterns inside conditionals corrupt to null bytes — skip it there.
        let profile = SiteRegistry.profile(for: item.url)
        let outputTemplate = outputDirectory.path + "/%(uploader)s - %(title)s\(profile.outputTemplateSuffix).%(ext)s"
        var args: [String] = []
        args += CookieArgs.make(browser: cookieBrowser, file: cookiesFile)

        let hf = videoQuality.heightFilter ?? ""  // e.g. "[height<=1080]" or ""

        switch format {
        case .audioOnly:
            args += [
                "--format", "bestaudio/best",
                "--extract-audio",
                "--audio-format", "mp3",
                "--audio-quality", audioQuality.rawValue,
            ]
        case .singleFile:
            // YouTube (including Shorts) almost never serves a single combined mp4
            // stream — falling through to .videoAndAudio's selector avoids a
            // "Requested format is not available" failure.
            if profile.usesYouTubeFormatSelector {
                args += [
                    "--format",
                    "bestvideo[vcodec^=avc][ext=mp4]\(hf)+bestaudio[ext=m4a]/bestvideo[ext=mp4]\(hf)+bestaudio[ext=m4a]/bestvideo\(hf)+bestaudio/bestvideo+bestaudio/bv*+ba/b",
                    "--merge-output-format", "mp4",
                ]
            } else {
                // Prefer HTTPS combined streams; m3u8/HLS tokens expire quickly and can
                // cause "Requested format is not available" before the download starts.
                args += [
                    "--format",
                    "bestvideo*[acodec!=none][ext=mp4][protocol^=https]\(hf)/bestvideo*[acodec!=none][ext=mp4]\(hf)/best[acodec!=none]\(hf)/bv*+ba/b",
                    "--merge-output-format", "mp4",
                ]
            }
        case .videoAndAudio:
            // Prefer H.264 (avc) over AV1 for wider player compatibility.
            // Final `bv*+ba/b` is the yt-dlp catch-all: `bv*` matches combined
            // streams too (not just video-only), so even degenerate YouTube
            // responses with only HLS combined streams still resolve.
            args += [
                "--format",
                "bestvideo[vcodec^=avc][ext=mp4]\(hf)+bestaudio[ext=m4a]/bestvideo[ext=mp4]\(hf)+bestaudio[ext=m4a]/bestvideo\(hf)+bestaudio/bestvideo+bestaudio/bv*+ba/b",
                "--merge-output-format", "mp4",
            ]
        }

        if profile.supportsSubtitles && format != .audioOnly && subtitleLanguage != .none {
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

    /// Cleans a yt-dlp filename stem into a display title by stripping the suffixes
    /// yt-dlp adds: a trailing image index (`_2`), a multi-video playlist index
    /// (` [01]`), and the intermediate format code (`.f136`) left on the pre-merge
    /// stream's first Destination line (the final merged file has none).
    static func cleanTitleStem(_ stem: String, isImage: Bool) -> String {
        var s = stem
        if isImage, let r = s.range(of: #"_\d+$"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound])
        }
        if let r = s.range(of: #" \[\d+\]$"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound])
        }
        if let r = s.range(of: #"\.f\d+$"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound])
        }
        return s
    }

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
                if token == "of", i + 1 < tokens.count { item.totalSize = tokens[i + 1] }
                if token == "at", i + 1 < tokens.count { item.speed = tokens[i + 1] }
                if token == "ETA", i + 1 < tokens.count { item.eta = tokens[i + 1] }
            }
            return
        }

        // Destination: track video/audio/image paths and infer title
        if line.hasPrefix("[download]") && line.contains("Destination:"),
            let range = line.range(of: "Destination: ")
        {
            let path = String(line[range.upperBound...])
            let ext = (path as NSString).pathExtension.lowercased()
            let isImage = MediaExtensions.image.contains(ext)
            let isAudio = MediaExtensions.audio.contains(ext)

            if !isImage {
                if isAudio {
                    item.audioPath = path
                    item.mediaCategory = .audio  // a direct .mp3/.m4a download (not via [ExtractAudio])
                } else {
                    item.videoPath = path
                    item.videoCount = (item.videoCount ?? 0) + 1
                }
                item.outputPath = path
            } else if item.outputPath == nil {
                item.outputPath = path
            }

            if item.title == nil {
                // Keep the full "Uploader - Title" stem (gallery-dl titles already do this).
                let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                item.title = Self.cleanTitleStem(stem, isImage: isImage)
            }
            if isImage { item.imageCount = (item.imageCount ?? 0) + 1 }

            item.recomputeMediaCategory()  // update category progressively as files land

            return
        }

        // Merger: final merged output file
        if (line.hasPrefix("[Merger]") || line.hasPrefix("[ffmpeg]")) && line.contains("Merging formats into"),
            let q1 = line.firstIndex(of: "\""),
            let q2 = line.lastIndex(of: "\""),
            q1 != q2
        {
            let path = String(line[line.index(after: q1)..<q2])
            item.videoPath = path
            item.outputPath = path
            return
        }

        // ExtractAudio: final audio-only output file
        if line.hasPrefix("[ExtractAudio]") && line.contains("Destination:"),
            let range = line.range(of: "Destination: ")
        {
            let path = String(line[range.upperBound...])
            item.audioPath = path
            item.outputPath = path
            item.mediaCategory = .audio
            return
        }

        // External redirect detection: yt-dlp followed a link out of the tweet.
        // Kill the process immediately so gallery-dl can handle the original tweet URL.
        if SiteRegistry.profile(for: item.url).detectsExternalRedirect,
            line.hasPrefix("[generic]") || line.hasPrefix("[redirect]"),
            let urlRange = line.range(of: "(?:Extracting URL|Following redirect to): (https?://\\S+)", options: .regularExpression),
            let detected = line[urlRange].components(separatedBy: ": ").last,
            !SiteRegistry.isTwitterContent(detected)
        {
            terminate()
            item.status = .failed("external_redirect")
            return
        }

        // Errors
        let lower = line.lowercased()
        if lower.contains("error:") {
            if case .failed = item.status { return }
            if line.contains("Requested format is not available") {
                // Almost always a transient YouTube extractor hiccup — the
                // permissive `bv*+ba/b` tail of the selector should absorb
                // most of these; if it still fires, retrying a minute later
                // usually works.
                item.status = .failed("No downloadable format — usually a brief YouTube hiccup, click Retry.")
            } else if lower.contains("subtitle") {
                // Subtitle download failures (e.g. YouTube's "HTTP Error 429:
                // Too Many Requests") must not fail the whole download — the
                // video is the user's actual target. yt-dlp writes subtitles
                // *before* the video, so this ERROR aborts the item with no
                // media saved; flag it so DownloadManager can retry with
                // subtitles disabled. Don't set .failed here.
                item.subtitleDownloadFailed = true
                return
            } else {
                item.status = .failed(line)
            }
        }
    }
}
