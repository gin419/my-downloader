import Foundation

enum GalleryDlService {

    // MARK: - Failure messages

    // Known raw gallery-dl output replaced with app-native copy naming the
    // true cause and the in-app fix. Internal (not private) so tests share
    // one source of truth. Only the empty-success family further down may
    // match DownloadManager's empty-success auto-retry predicate.
    static let nsfwTweetMessage =
        "This tweet is marked sensitive — export a cookies.txt file in Settings (browser cookies often can't unlock NSFW X media), then Retry."
    static let protectedTweetMessage =
        "This account's posts are protected — you must follow it; sign in via Settings → Cookies, then Retry."
    static let xAuthMessage =
        "X sign-in needed or expired — sign in to X in the browser in Settings → Cookies, then Retry. "
        + "If you're already signed in and this persists, update gallery-dl."
    static let signInGenericMessage =
        "Sign-in required or session expired — check Settings → Cookies, then Retry."
    static let internalErrorMessage =
        "gallery-dl hit an internal error — the site may have changed its API. "
        + "Updating gallery-dl (brew upgrade gallery-dl) usually fixes this."
    static let instagramChallengeMessage =
        "Instagram is asking for a security check — open instagram.com, complete it, then Retry."
    static let unsupportedURLMessage =
        "gallery-dl doesn't recognize this URL — if the site recently changed links, updating gallery-dl may add support."
    static let instagramLoginMessage =
        "Instagram requires login — sign in to Instagram in the browser selected in Settings → Cookies, then Retry."

    // Empty-success messages (exit 0, no files): the ONLY messages allowed to
    // trigger DownloadManager's one-shot empty-success auto-retry — its
    // predicate matches exactly these (plus the `noMediaWarningPrefix`
    // dynamic variant), so new failure copy must not reuse this phrasing.
    static let noMediaTwitterMessage =
        "No media found — the tweet may be deleted, or export cookies.txt in Settings (recommended for X sensitive/NSFW content)."
    static let noMediaInstagramMessage =
        "No media found — the post may be deleted, or sign in to Instagram in the browser selected in Settings → Cookies, then Retry."
    static let noMediaRedditMessage =
        "No media found — the post may be deleted, or the subreddit may be private."
    static let noMediaGenericMessage = "No media found at this link."
    /// Prefix of the dynamic "No media found — <captured warning>" variant.
    static let noMediaWarningPrefix = "No media found — "

    /// Site-appropriate "exit 0 but no files" message. (The pre-Phase-2 code
    /// hardcoded the Twitter wording for every non-Instagram site, telling
    /// Reddit users about deleted tweets and cookies.txt.)
    static func emptySuccessMessage(forProfileID id: String) -> String {
        switch id {
        case "twitter": return noMediaTwitterMessage
        case "instagram": return noMediaInstagramMessage
        case "reddit": return noMediaRedditMessage
        default: return noMediaGenericMessage
        }
    }

    /// Known raw error lines → app-native copy, ordered most-specific-first:
    /// the NSFW/Protected forms must win over the AuthRequired umbrella they
    /// are nested in. nil keeps the caller's verbatim-line behavior.
    /// `profileID` site-gates the X-specific sign-in copy: other sites get a
    /// generic sign-in message instead of being told to sign in to X.
    static func mappedErrorMessage(for line: String, profileID: String) -> String? {
        if line.contains("NSFW Tweet") { return nsfwTweetMessage }
        if line.contains("Protected Tweet") || line.contains("Tweets are protected") {
            return protectedTweetMessage
        }
        if line.contains("AuthRequired") || line.contains("Could not authenticate you")
            || line.contains("401 Unauthorized")
        {
            return profileID == "twitter" ? xAuthMessage : signInGenericMessage
        }
        if line.contains("An unexpected error occurred") { return internalErrorMessage }
        if line.contains("[instagram]"), line.lowercased().contains("challenge") {
            return instagramChallengeMessage
        }
        if line.contains("Unsupported URL") { return unsupportedURLMessage }
        return nil
    }

    /// Decodes gallery-dl's exit-status bitmask into named causes, citing the
    /// run's last captured warning when there is one. Bits verified against
    /// gallery-dl 1.32.9's exception.py / __init__.py: 1 unspecified,
    /// 4 extraction/HTTP, 8 ChallengeError (bot check), 16 auth,
    /// 32 InputError family, 64 unsupported URL, 128 OS error.
    static func exitFailureMessage(code: Int32, lastWarning: String?) -> String {
        var causes: [String] = []
        if code & 4 != 0 { causes.append("a network/HTTP error") }
        if code & 8 != 0 {
            causes.append("a bot-check challenge — open the site in your browser and complete it, or refresh cookies")
        }
        if code & 16 != 0 { causes.append("an authorization problem — check Settings → Cookies") }
        if code & 32 != 0 { causes.append("an input or format problem") }
        if code & 64 != 0 { causes.append("URL not recognized") }
        if code & 128 != 0 { causes.append("a disk or file error") }
        if causes.isEmpty { causes = ["an unspecified error"] }
        var message = "gallery-dl failed: \(causes.joined(separator: " + ")) (code \(code))"
        if let lastWarning { message += " — last warning: \(lastWarning)" }
        return message
    }

    /// Non-zero exit after some files DID land (a multi-file post where one
    /// file errored): name what was saved and the first recorded error
    /// instead of the exit bitmask's generic guess. Retry is dedup-safe —
    /// existing files are skipped — so it only fetches the rest.
    ///
    /// Declared red: still returns the bare error; the saved-count
    /// composition lands with the implementation commit.
    static func partialFailureMessage(savedCount: Int, firstError: String) -> String {
        firstError
    }

    // MARK: - Download

    @MainActor
    static func run(
        item: DownloadItem,
        executablePath: String,
        outputDirectory: URL,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String? = nil,
        cookiesFile: String? = nil,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void
    ) async {
        let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? [])

        let result = await ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments(
                for: item.url, outputDirectory: outputDirectory,
                cookieBrowser: cookieBrowser, cookieBrowserProfile: cookieBrowserProfile,
                cookiesFile: cookiesFile),
            item: item,
            register: register,
            unregister: unregister,
            lineParser: { line, item in parseLine(line, item: item) }
        )

        guard result.isSuccess else {
            if case .failed = item.status {
            } else if result.wasSignal {
                // Killed by a signal — the exit bitmask only describes real
                // exits, so decoding a signal number would invent false
                // causes. (Distinguishing a user pause from a crash on this
                // path is Phase 4 scope; today both read as terminated.)
                item.status = .failed("gallery-dl was terminated (signal \(result.code))")
            } else {
                item.status = .failed(
                    Self.exitFailureMessage(code: result.code, lastWarning: item.lastToolWarning))
            }
            return
        }

        // Detect newly created media files since the download started.
        let imageExts = MediaExtensions.image
        let videoExts = MediaExtensions.video
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
                item.status = .failed(Self.noMediaWarningPrefix + warning)
            } else {
                item.status = .failed(
                    Self.emptySuccessMessage(forProfileID: SiteRegistry.profile(for: item.url).id))
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
        item.recomputeMediaCategory()

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

        item.markCompleted()
    }

    // MARK: - Argument building

    /// One command line for both the full fallback run and the image sweep —
    /// `extraArgs` (e.g. the sweep's `-o videos=false`) slot in after the
    /// profile's own args so they can override per-site option defaults.
    static func arguments(
        for url: String,
        outputDirectory: URL,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String? = nil,
        cookiesFile: String?,
        extraArgs: [String] = []
    ) -> [String] {
        var args = CookieArgs.make(
            browser: cookieBrowser, profile: cookieBrowserProfile, file: cookiesFile)
        args += [
            "--dest", outputDirectory.path,
            "-D", ".",
            // Large X/Reddit videos (multi-GB) drop the connection or read-time out
            // on a flaky link; the default ~4 retries / 30s aren't enough. Be generous.
            "--retries", "10",
            "-o", "downloader.http.timeout=60",
        ]
        args += SiteRegistry.profile(for: url).galleryDlArgs
        args += extraArgs
        args += [
            "--no-mtime",
            url,
        ]
        return args
    }

    // MARK: - Image sweep

    /// Post-success photo pass for profiles that declare `imageSweepArgs`:
    /// collects the photos of a mixed video+photo post without touching the
    /// already-captured video result — the item's status, title, and
    /// outputPath stay the video's. Failures are deliberately silent: the
    /// video is the download's outcome, and a sweep that finds nothing is the
    /// normal case (video-only posts).
    @MainActor
    static func runImageSweep(
        item: DownloadItem,
        executablePath: String,
        outputDirectory: URL,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String? = nil,
        cookiesFile: String? = nil,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void
    ) async {
        guard let sweepArgs = SiteRegistry.profile(for: item.url).imageSweepArgs else { return }
        let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? [])

        _ = await ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments(
                for: item.url, outputDirectory: outputDirectory,
                cookieBrowser: cookieBrowser, cookieBrowserProfile: cookieBrowserProfile,
                cookiesFile: cookiesFile, extraArgs: sweepArgs),
            item: item,
            register: register,
            unregister: unregister,
            lineParser: { _, _ in }  // the video owns status/title/outputPath
        )

        let afterFiles = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        let newImages = afterFiles.filter {
            !beforeFiles.contains($0)
                && MediaExtensions.image.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }
        if !newImages.isEmpty {
            item.imageCount = (item.imageCount ?? 0) + newImages.count
            item.recomputeMediaCategory()
        }
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
            guard MediaExtensions.all.contains(ext) else { return }

            let isImage = MediaExtensions.image.contains(ext)
            let isVideo = MediaExtensions.video.contains(ext)
            item.status = .downloading
            // A file landing means any backoff wait is over — a stale
            // "14 minutes (rate limited)" ETA must not outlive the wait.
            item.eta = nil
            item.outputPath = pathLine
            if isImage {
                item.imageCount = (item.imageCount ?? 0) + 1
            } else if isVideo {
                item.videoCount = (item.videoCount ?? 0) + 1
            }
            item.recomputeMediaCategory()  // update category progressively

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

        // Backoff wait: gallery-dl sleeps through rate limits, 429 backoffs,
        // and CloudFront blocks printing only "[…][info] Waiting for
        // 14 minutes until 12:34:56 (<reason>)" — up to ~15 minutes on X,
        // during which the row would look hung. Surface the wait through the
        // row's existing ETA field (no layout change). Deliberately NOT
        // written to lastToolWarning: a wait is routine, and it must not
        // clobber a real [warning] diagnostic captured above.
        if line.contains("Waiting for "), line.contains(" until ") {
            if let start = line.range(of: "Waiting for "),
                let end = line.range(of: " until "),
                start.upperBound < end.lowerBound
            {
                item.eta = "\(line[start.upperBound..<end.lowerBound]) (rate limited)"
            }
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

        // Instagram answers logged-out requests with "[instagram][error] HTTP
        // redirect to login page (…)" — the raw line doesn't say what to do,
        // so replace it with the fix.
        if line.contains("[instagram][error]"), line.lowercased().contains("login") {
            if case .failed = item.status { return }
            item.status = .failed(Self.instagramLoginMessage)
            return
        }

        if line.lowercased().contains("error") {
            if case .failed = item.status { return }
            // Known raw errors get app-native copy naming the true cause and
            // the in-app fix; everything else stays verbatim.
            let profileID = SiteRegistry.profile(for: item.url).id
            item.status = .failed(Self.mappedErrorMessage(for: line, profileID: profileID) ?? line)
        }
    }

    // MARK: - Helpers

    /// Filename stem → display title: strips the trailing " #N" file index,
    /// the " [tweet_id]" / " [shortcode]" uniqueness suffix, and the legacy
    /// "_N" index. "Nick - text [2063695500809826393] #1" → "Nick - text"
    static func displayTitle(forPath path: String) -> String {
        var stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if let r = stem.range(of: #" #\d+$"#, options: .regularExpression) {
            stem = String(stem[..<r.lowerBound])
        }
        // A filename carries exactly one uniqueness suffix: a numeric tweet id
        // or an 11-base64url-char Instagram shortcode. Stop after the first
        // match — a Twitter filename's id is followed by the tweet's own text
        // once stripped, and that text may itself end with an 11-char bracketed
        // token ("… [OFFICIAL_MV]") that must survive as part of the title.
        for pattern in [#" \[\d{10,}\]$"#, #" \[[A-Za-z0-9_-]{11}\]$"#] {
            if let r = stem.range(of: pattern, options: .regularExpression) {
                stem = String(stem[..<r.lowerBound])
                break
            }
        }
        if let r = stem.range(of: #"_\d+$"#, options: .regularExpression) {
            stem = String(stem[..<r.lowerBound])
        }
        return stem
    }
}
