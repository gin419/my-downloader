import Foundation

enum GalleryDlService {

    // MARK: - Download

    @MainActor
    static func run(
        item: DownloadItem,
        executablePath: String,
        outputDirectory: URL,
        cookieBrowser: CookieBrowser,
        cookiesFile: String? = nil,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void
    ) async {
        let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? [])

        var args = cookieArgs(cookieBrowser, cookiesFile: cookiesFile)
        args += [
            "--dest", outputDirectory.path,
            "-D", ".",
            // Large X/Reddit videos (multi-GB) drop the connection or read-time out
            // on a flaky link; the default ~4 retries / 30s aren't enough. Be generous.
            "--retries", "10",
            "-o", "downloader.http.timeout=60",
        ]
        args += SiteRegistry.profile(for: item.url).galleryDlArgs
        args += [
            "--no-mtime",
            item.url,
        ]

        let exitCode = await runProcess(
            executablePath: executablePath,
            arguments: args,
            item: item,
            register: register,
            unregister: unregister,
            lineParser: { line, item in parseLine(line, item: item) }
        )

        guard exitCode == 0 else {
            if case .failed = item.status { } else {
                item.status = .failed("gallery-dl exit code \(exitCode)")
            }
            return
        }

        // Detect newly created media files since the download started.
        let imageExts = Set(["jpg", "jpeg", "png", "webp", "gif", "avif"])
        let videoExts = Set(["mp4", "mov", "webm", "mkv", "m4v"])
        let afterFiles = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []

        func ext(_ name: String) -> String { URL(fileURLWithPath: name).pathExtension.lowercased() }
        let newImages = afterFiles.filter { !beforeFiles.contains($0) && imageExts.contains(ext($0)) }.sorted()
        let newVideos = afterFiles.filter { !beforeFiles.contains($0) && videoExts.contains(ext($0)) }.sorted()

        if item.outputPath == nil {
            let candidate = newImages.first ?? newVideos.first
            if let first = candidate {
                item.outputPath = outputDirectory.appendingPathComponent(first).path
            }
        }

        // gallery-dl exited 0 but neither new files appeared nor dry-run could
        // resolve a path — the tweet's media is genuinely unreachable (most
        // often: a deleted tweet, or sensitive content the cookie session
        // can't unlock). Without this guard, the row would be marked "Done"
        // with no files, which is misleading. Prefer gallery-dl's own warning
        // (age-restriction, media unavailable, …) over the generic guess.
        guard item.outputPath != nil else {
            if let warning = item.lastToolWarning {
                item.status = .failed("No media found — \(warning)")
            } else {
                item.status = .failed("No media found — the tweet may be deleted, or export cookies.txt in Settings (recommended for X sensitive/NSFW content).")
            }
            return
        }

        if !newImages.isEmpty { item.imageCount = newImages.count }
        if !newVideos.isEmpty { item.videoCount = newVideos.count }

        // "File already existed" path: parseLine never fired, so infer count from outputPath extension.
        if newImages.isEmpty && newVideos.isEmpty, let path = item.outputPath {
            let e = ext(path)
            if imageExts.contains(e) && (item.imageCount ?? 0) == 0 { item.imageCount = 1 }
            if videoExts.contains(e) && (item.videoCount ?? 0) == 0 { item.videoCount = 1 }
        }

        // Sync category from final counts (overrides whatever parseLine may have set).
        let hasImg = (item.imageCount ?? 0) > 0
        let hasVid = (item.videoCount ?? 0) > 0
        if hasImg && hasVid       { item.mediaCategory = .mixed }
        else if hasImg            { item.mediaCategory = .image }
        else if hasVid            { item.mediaCategory = .video }

        // Rename single-image files: strip trailing " #1" suffix.
        if newImages.count == 1, let path = item.outputPath {
            let u = URL(fileURLWithPath: path)
            let stem = u.deletingPathExtension().lastPathComponent
            if stem.hasSuffix(" #1") {
                let clean = String(stem.dropLast(3))
                let newPath = u.deletingLastPathComponent()
                    .appendingPathComponent(clean + "." + u.pathExtension).path
                if (try? FileManager.default.moveItem(atPath: path, toPath: newPath)) != nil {
                    item.outputPath = newPath
                    item.title = displayTitle(forPath: newPath)
                }
            }
        }

        if item.title == nil, let path = item.outputPath {
            item.title = displayTitle(forPath: path)
        }

        item.status   = .completed
        item.progress = 1.0
        item.speed    = nil
        item.eta      = nil
    }

    // MARK: - Output parsing

    @MainActor
    static func parseLine(_ line: String, item: DownloadItem) {
        guard !line.isEmpty else { return }

        // gallery-dl prints each downloaded file's path on its own line, or
        // "# <path>" when the file already exists and was skipped. Filenames
        // embed the tweet id (see formatArgs), so a skip can only mean this
        // exact tweet's media is already on disk — treat it as this row's
        // output instead of letting the run end as "no media found".
        // Python/urllib3 warning lines also start with "/" but contain ": ".
        let isSkipLine = line.hasPrefix("# /") || line.hasPrefix("# ~")
        let pathLine = isSkipLine ? String(line.dropFirst(2)) : line
        if pathLine.hasPrefix("/") || pathLine.hasPrefix("~") {
            let ext = (pathLine as NSString).pathExtension.lowercased()
            let knownMedia = ["jpg", "jpeg", "png", "webp", "gif", "avif", "mp4", "mov", "webm", "m4a", "mp3"]
            guard knownMedia.contains(ext) else { return }

            let isImage = ["jpg", "jpeg", "png", "webp", "gif", "avif"].contains(ext)
            let isVideo = ["mp4", "mov", "webm", "mkv", "m4v"].contains(ext)
            item.status     = .downloading
            item.outputPath = pathLine
            if isImage {
                item.imageCount = (item.imageCount ?? 0) + 1
            } else if isVideo {
                item.videoCount = (item.videoCount ?? 0) + 1
            }
            // Update category progressively
            let hasImg = (item.imageCount ?? 0) > 0
            let hasVid = (item.videoCount ?? 0) > 0
            if hasImg && hasVid       { item.mediaCategory = .mixed }
            else if hasImg            { item.mediaCategory = .image }
            else if hasVid            { item.mediaCategory = .video }

            if item.title == nil {
                item.title = displayTitle(forPath: pathLine)
            }
            return
        }

        // Warnings aren't failures by themselves, but when the run ends with no
        // files they're the only clue why (age-restricted tweet, media removed
        // by a DMCA notice, …). Remember the most recent one so the
        // empty-success guard in run() can show it instead of a generic guess.
        // Must come before the "error" check: warning text may contain the
        // word "error" (e.g. "API errors (1/10)") without being fatal.
        if let r = line.range(of: "[warning] ") {
            let msg = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !msg.isEmpty { item.lastToolWarning = msg }
            return
        }

        // "[twitter][info] No results for <url>": X's TweetDetail API returned
        // an empty conversation for an existing tweet — seen when X temporarily
        // limits a (typically spam-flagged) account's visibility. The state can
        // lift after hours/days, so steer the user toward retrying later.
        if line.contains("[info] No results") {
            item.lastToolWarning = "X returned no results — the tweet may be temporarily limited or hidden. Retry later."
            return
        }

        if line.lowercased().contains("error") {
            if case .failed = item.status { return }
            item.status = .failed(line)
        }
    }

    // MARK: - Private helpers

    /// Filename stem → display title: strips the trailing " #N" file index,
    /// the " [tweet_id]" uniqueness suffix, and the legacy "_N" index.
    /// "Nick - text [2063695500809826393] #1" → "Nick - text"
    private static func displayTitle(forPath path: String) -> String {
        var stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        for pattern in [#" #\d+$"#, #" \[\d{10,}\]$"#, #"_\d+$"#] {
            if let r = stem.range(of: pattern, options: .regularExpression) {
                stem = String(stem[..<r.lowerBound])
            }
        }
        return stem
    }

    private static func cookieArgs(_ browser: CookieBrowser, cookiesFile: String? = nil) -> [String] {
        return CookieArgs.make(browser: browser, file: cookiesFile)
    }
}
