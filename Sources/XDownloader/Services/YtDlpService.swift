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
        cookieBrowserProfile: String? = nil,
        cookiesFile: String? = nil
    ) -> [String] {
        // The profile's outputTemplateSuffix expands to " [01]" etc. only when a
        // post contains multiple videos (yt-dlp treats them as a playlist). For
        // single videos playlist_index is not set, so the suffix is empty.
        // Nested %(...)fmt patterns inside the &conditional corrupt to null
        // bytes (a yt-dlp template-parser limitation) — new suffixes must use
        // the `{0}` replacement syntax instead (see the instagram profile).
        let profile = SiteRegistry.profile(for: item.url)
        let stem =
            profile.extractorTitleIncludesUploader
            ? "%(title)s" : "%(uploader)s - %(title)s"
        let outputTemplate = outputDirectory.path + "/\(stem)\(profile.outputTemplateSuffix).%(ext)s"
        var args: [String] = []
        args += CookieArgs.make(
            browser: cookieBrowser, profile: cookieBrowserProfile, file: cookiesFile)

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

    // MARK: - Failure messages

    // Messages for "Requested format is not available" on YouTube, chosen
    // from the WARNING-line evidence recorded in `item.extractorBreakage`.
    // Internal (not private) so tests share one source of truth. None of them
    // may contain DownloadManager's empty-success auto-retry trigger
    // substrings — a broken tool would silently re-run and fail identically.
    static let staleToolMessage =
        "YouTube blocked this yt-dlp version — update it (e.g. brew upgrade yt-dlp), then Retry."
    static let missingJSRuntimeMessage =
        "yt-dlp needs a JavaScript runtime for YouTube — install deno (brew install deno), then Retry."
    static let transientFormatMessage =
        "No downloadable format — usually a brief YouTube hiccup, click Retry."

    // Known raw ERROR lines replaced with app-native copy naming the true
    // cause and the in-app fix (the model is GalleryDlService's
    // Instagram-login mapping). Same constraints as above: internal so tests
    // share one source of truth, and none may match DownloadManager's
    // empty-success auto-retry predicate.
    static let privateVideoMessage =
        "Private video — sign in with an authorized account in the browser chosen in Settings → Cookies, then Retry."
    static let ageRestrictedMessage =
        "Age-restricted — needs a signed-in browser session (Settings → Cookies)."
    static let membersOnlyMessage =
        "Members-only video — needs cookies from a member account."
    static let botCheckMessage =
        "YouTube wants a signed-in session — pick your YouTube browser in Settings → Cookies (update yt-dlp if this repeats)."
    static let http403Message =
        "YouTube rejected the download (HTTP 403) — this usually means yt-dlp is outdated. Update it, then Retry."
    static let genericHttp403Message =
        "The site rejected the download (HTTP 403) — Retry; if it persists, the media may need different cookies."
    static let cookieDatabaseMessage =
        "Couldn't read the selected browser's cookies — pick the browser and profile you actually use in Settings → Cookies."
    static let ffmpegMissingMessage =
        "ffmpeg is required to convert or merge media — install it (brew install ffmpeg), then Retry."

    /// Known raw ERROR lines → app-native copy. Compound (multi-substring)
    /// patterns come first so the most specific match wins; nil keeps the
    /// caller's verbatim-line behavior for unrecognized errors. `profileID`
    /// site-gates the diagnoses whose copy names a specific site.
    static func mappedErrorMessage(for line: String, profileID: String) -> String? {
        let lower = line.lowercased()
        if lower.contains("postprocessing"),
            lower.contains("ffmpeg") || lower.contains("ffprobe"),
            lower.contains("not found") || lower.contains("not installed")
        {
            return ffmpegMissingMessage
        }
        if lower.contains("could not find"), lower.contains("cookies database") {
            return cookieDatabaseMessage
        }
        if lower.contains("unable to download video data"), lower.contains("403") {
            // The stale-tool diagnosis is a YouTube pattern; on other sites a
            // 403 usually means a cookie/session problem, not an old yt-dlp.
            return profileID == "youtube" ? http403Message : genericHttp403Message
        }
        // yt-dlp relays YouTube's own phrasing, which uses a right single
        // quote ("you’re") — accept the plain apostrophe too.
        if lower.contains("sign in to confirm you're not a bot")
            || lower.contains("sign in to confirm you’re not a bot")
        {
            return botCheckMessage
        }
        if lower.contains("sign in to confirm your age") { return ageRestrictedMessage }
        if lower.contains("members-only") || lower.contains("join this channel") {
            return membersOnlyMessage
        }
        if lower.contains("private video") { return privateVideoMessage }
        return nil
    }

    // MARK: - Output parsing

    /// Cleans a yt-dlp filename stem into a display title by stripping the suffixes
    /// yt-dlp adds: a trailing image index (`_2`), a multi-video playlist index
    /// (` [01]`), and the intermediate format code (`.f136`, `.fhls-230`, …)
    /// left on pre-merge stream filenames (the final merged file has none).
    static func cleanTitleStem(_ stem: String, isImage: Bool) -> String {
        var s = stem
        if isImage, let r = s.range(of: #"_\d+$"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound])
        }
        if let r = s.range(of: #" \[\d+\]$"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound])
        }
        // Format ids are not always pure digits — Twitter HLS uses
        // "hls-230", "hls-audio-64000-Audio", "http-832", etc.
        if let r = s.range(of: #"\.f[\w-]+$"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound])
        }
        return s
    }

    /// yt-dlp names pre-merge streams by inserting `.f{format_id}` before the
    /// extension (`clip.f136.mp4`, `clip.fhls-230.mp4`). Those are temporary
    /// pieces of one final video, not separate deliverables the user receives.
    static func isIntermediateFormatPath(_ path: String) -> Bool {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return stem.range(of: #"\.f[\w-]+$"#, options: .regularExpression) != nil
    }

    /// Parse one line of yt-dlp stdout/stderr, updating `item` in place.
    /// `terminate` is called when yt-dlp is detected following an external redirect
    /// out of an X.com tweet — the caller should kill the process so gallery-dl can take over.
    @MainActor
    static func parseLine(_ line: String, item: DownloadItem, terminate: () -> Void) {
        guard !line.isEmpty else { return }

        // Skip notice: the file already exists on disk from a prior download.
        // yt-dlp then exits 0 printing only this line — no Destination:/[Merger]
        // follows — so it must count as the captured output or the run reads as
        // an "empty success" and the item fails. Checked BEFORE the progress
        // branch: the output template preserves literal '%' from titles, and a
        // '%' in the filename would otherwise make this line parse as progress.
        // Older yt-dlp versions append " and merged" — match the line's tail
        // (so a Destination: line can't land here) and cut at the LAST marker
        // occurrence, keeping filenames that contain the marker text intact.
        if line.hasPrefix("[download] "),
            line.hasSuffix(" has already been downloaded")
                || line.hasSuffix(" has already been downloaded and merged")
        {
            let body = line.dropFirst("[download] ".count)
            if let marker = body.range(of: " has already been downloaded", options: .backwards) {
                Self.recordMediaPath(String(body[..<marker.lowerBound]), on: item)
            }
            return
        }

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
            Self.recordMediaPath(String(line[range.upperBound...]), on: item)
            return
        }

        // Merger: one final deliverable video the user actually receives.
        // Pre-merge Destination lines (video stream + audio stream) are not
        // counted — only this merged file is.
        if (line.hasPrefix("[Merger]") || line.hasPrefix("[ffmpeg]")) && line.contains("Merging formats into"),
            let q1 = line.firstIndex(of: "\""),
            let q2 = line.lastIndex(of: "\""),
            q1 != q2
        {
            let path = String(line[line.index(after: q1)..<q2])
            item.videoPath = path
            item.outputPath = path
            item.videoCount = (item.videoCount ?? 0) + 1
            let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            item.title = Self.cleanTitleStem(stem, isImage: false)
            item.recomputeMediaCategory()
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
            // Remembered so DownloadManager can name the destination host in
            // the final message, whether the sentinel below survives or the
            // fallbacks run and come up empty.
            item.externalRedirectURL = detected
            item.status = .failed(DownloadStatus.externalRedirectSentinel)
            return
        }

        // Stale-extractor tells: WARNINGs that identify WHY YouTube formats
        // are about to go missing — a yt-dlp build too old for current
        // YouTube (signature/nsig extraction failed, only images offered) or
        // a missing JavaScript runtime. Recorded here, consumed by the
        // "Requested format is not available" error below to name the real
        // cause. The WARNING prefix gate is load-bearing: a Destination
        // filename containing tell text must never trigger detection.
        // ("Precondition check failed" is deliberately NOT a tell — it fires
        // transiently on healthy installs.)
        if line.hasPrefix("WARNING") {
            if SiteRegistry.profile(for: item.url).id == "youtube" {
                let lowerWarning = line.lowercased()
                if lowerWarning.contains("no supported javascript runtime") {
                    item.extractorBreakage = .missingJSRuntime
                    return
                }
                if lowerWarning.contains("signature extraction failed")
                    || lowerWarning.contains("nsig extraction failed")
                    || lowerWarning.contains("only images are available")
                {
                    // Never downgrade missingJSRuntime: a missing runtime also
                    // breaks signature extraction, and installing deno is the
                    // actionable root cause.
                    if item.extractorBreakage == .none { item.extractorBreakage = .staleTool }
                    return
                }
            }
            // Any other WARNING (all sites): not a failure by itself, but when
            // the run ends badly the most recent one is the best clue why —
            // remember it (minus the prefix) so DownloadManager can cite it in
            // exit-code failures, mirroring GalleryDlService's capture.
            let body =
                line.hasPrefix("WARNING: ")
                ? String(line.dropFirst("WARNING: ".count)) : line
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { item.lastToolWarning = trimmed }
            return
        }

        // Errors
        let lower = line.lowercased()
        if lower.contains("error:") {
            if case .failed = item.status { return }
            if line.contains("Requested format is not available") {
                // With no tell recorded this is almost always a transient
                // YouTube extractor hiccup — the permissive `bv*+ba/b` tail
                // of the selector should absorb most of these; if it still
                // fires, retrying a minute later usually works. A recorded
                // tell means the tool itself is broken and Retry alone can't
                // fix it — say so.
                let breakage: ExtractorBreakage =
                    SiteRegistry.profile(for: item.url).id == "youtube" ? item.extractorBreakage : .none
                switch breakage {
                case .missingJSRuntime: item.status = .failed(Self.missingJSRuntimeMessage)
                case .staleTool: item.status = .failed(Self.staleToolMessage)
                case .none: item.status = .failed(Self.transientFormatMessage)
                }
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
                // Known raw errors get app-native copy naming the true cause
                // and the in-app fix; everything else stays verbatim.
                let profileID = SiteRegistry.profile(for: item.url).id
                item.status = .failed(Self.mappedErrorMessage(for: line, profileID: profileID) ?? line)
            }
        }
    }

    /// After a successful yt-dlp run: if every Destination was a pre-merge
    /// intermediate (no Merger line, no final name without `.f…`), still count
    /// the single deliverable the user has on disk. Counts never invent media
    /// that isn't there — they only fill a zero when a path was captured.
    @MainActor
    static func ensureFinalMediaCounts(_ item: DownloadItem) {
        let path = item.outputPath ?? item.videoPath ?? item.audioPath
        guard let path else {
            item.recomputeMediaCategory()
            return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if MediaExtensions.video.contains(ext), (item.videoCount ?? 0) == 0 {
            item.videoCount = 1
        }
        if MediaExtensions.image.contains(ext), (item.imageCount ?? 0) == 0 {
            item.imageCount = 1
        }
        // Prefer a title cleaned from the final path over one still carrying
        // a pre-merge format code (`.fhls-230`, …).
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let cleaned = Self.cleanTitleStem(stem, isImage: MediaExtensions.image.contains(ext))
        if item.title == nil || item.title != cleaned {
            // Only overwrite when the current title still looks like an
            // intermediate stem, or is missing.
            if item.title == nil || Self.isIntermediateFormatPath(path)
                || (item.title?.range(of: #"\.f[\w-]+$"#, options: .regularExpression) != nil)
            {
                item.title = cleaned
            }
        }
        item.recomputeMediaCategory()
    }

    /// Record a media file yt-dlp reports as on disk — a fresh "Destination:"
    /// line or a "has already been downloaded" skip notice.
    ///
    /// Counts reflect **deliverables the user keeps**, not temporary streams:
    /// pre-merge `.f{format_id}` paths update progress/paths but do not bump
    /// `videoCount` / `imageCount`. Final names (and `[Merger]` lines) do.
    @MainActor
    private static func recordMediaPath(_ path: String, on item: DownloadItem) {
        let ext = (path as NSString).pathExtension.lowercased()
        let isImage = MediaExtensions.image.contains(ext)
        let isAudioExt = MediaExtensions.audio.contains(ext)
        // Twitter/YouTube HLS often packages the audio-only stream as `.mp4`
        // (`….fhls-audio-64000-Audio.mp4`). Treat that as audio, not a 2nd video.
        let isAudioOnlyIntermediate =
            isIntermediateFormatPath(path)
            && URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                .range(of: "audio", options: .caseInsensitive) != nil
        let isAudio = isAudioExt || isAudioOnlyIntermediate
        let isIntermediate = isIntermediateFormatPath(path)

        if !isImage {
            if isAudio {
                item.audioPath = path
                // Only lock the row to "Audio" for a real audio-only deliverable
                // (`.m4a` / `.mp3` / …), not for a pre-merge audio stream that
                // will be merged into a video.
                if isAudioExt && !isIntermediate {
                    item.mediaCategory = .audio
                }
            } else {
                item.videoPath = path
                if !isIntermediate {
                    item.videoCount = (item.videoCount ?? 0) + 1
                }
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
        // Images are final deliverables (yt-dlp does not split them into streams).
        if isImage { item.imageCount = (item.imageCount ?? 0) + 1 }

        item.recomputeMediaCategory()  // update category progressively as files land
        // Pre-merge streams deliberately leave videoCount nil until [Merger];
        // still show "Video" on the row while those streams download.
        if item.mediaCategory == .unknown, item.videoPath != nil {
            item.mediaCategory = .video
        }
    }
}
