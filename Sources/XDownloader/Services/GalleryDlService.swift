import Foundation

enum GalleryDlService {

    // MARK: - Failure messages

    // Known raw gallery-dl output replaced with app-native copy naming the
    // true cause and the in-app fix. Internal (not private) so tests share
    // one source of truth. None of these are empty-success failures: the
    // paths composing them never set `item.emptySuccessFailure`, so they
    // never trigger the one-shot auto-retry.
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
    /// gallery-dl's "Requested user could not be found": a profile link whose
    /// account was renamed, deleted or mistyped. Without it the exit code's
    /// generic "a network/HTTP error" would name a cause that didn't happen.
    static let instagramAccountNotFoundMessage =
        "Instagram account not found — it may have been renamed or deleted, or the link may be incomplete; check the link, then Retry."
    /// gallery-dl's "<name>'s posts are private" warning on a profile run.
    static let instagramPrivateAccountMessage =
        "This account is private — follow it with the Instagram login in the browser selected in Settings → Cookies, then Retry."

    // Empty-success messages (exit 0, no files). The guard in run() that
    // composes them also sets `item.emptySuccessFailure` — the structural
    // flag DownloadManager's one-shot auto-retry consumes — so this copy can
    // be reworded freely without gaining or losing retry behavior.
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
        if line.contains("[instagram]"), line.contains("could not be found") {
            return instagramAccountNotFoundMessage
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
        var message = "gallery-dl failed: \(exitCauses(code: code)) (code \(code))"
        if let lastWarning { message += " — last warning: \(lastWarning)" }
        return message
    }

    /// The causes an exit status names, joined: "a network/HTTP error".
    static func exitCauses(code: Int32) -> String {
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
        return causes.joined(separator: " + ")
    }

    /// Non-zero exit after some files DID land (a multi-file post where one
    /// file errored): name what was saved and the first recorded error
    /// instead of the exit bitmask's generic guess. Retry is dedup-safe —
    /// existing files are skipped — so it only fetches the rest.
    static func partialFailureMessage(savedCount: Int, firstError: String) -> String {
        let saved = "Saved \(savedCount) file\(savedCount == 1 ? "" : "s"), but one or more downloads failed — "
        // App-native causes are whole sentences, and most already end in
        // their own "then Retry." — close them once, and don't say Retry twice.
        var cause = firstError
        while cause.hasSuffix(".") { cause.removeLast() }
        return cause.contains("Retry") ? saved + cause + "." : saved + cause + ". Retry fetches the rest."
    }

    // MARK: - Download

    /// A single post. `outputDirectory` is the download folder; where in it
    /// the files go is `folderMode`'s (see `FolderMode`).
    @MainActor
    static func run(
        item: DownloadItem,
        executablePath: String,
        outputDirectory: URL,
        folderMode: FolderMode = .flat,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String? = nil,
        cookiesFile: String? = nil,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void
    ) async {
        await runAndSettle(
            item: item,
            executablePath: executablePath,
            arguments: arguments(
                for: item.url, outputDirectory: outputDirectory, folderMode: folderMode,
                cookieBrowser: cookieBrowser, cookieBrowserProfile: cookieBrowserProfile,
                cookiesFile: cookiesFile),
            outputDirectory: outputDirectory,
            looseDirectory: outputDirectory,
            register: register,
            unregister: unregister,
            lineParser: { line, item in parseLine(line, item: item) },
            noMediaMessage: emptySuccessMessage(forProfileID: SiteRegistry.profile(for: item.url).id),
            stripsSingleFileSuffix: true,
            settlesErrorsAtExit: false)
    }

    /// Where a single post's files go inside the download folder.
    enum FolderMode: Equatable {
        /// Straight into the download folder, every file loose.
        case flat
        /// A post of two or more files into a folder of its own, named per
        /// the site's `galleryDlFolderFormat`; a one-file post loose.
        /// gallery-dl decides from the post's own file count before it
        /// writes anything, so a post that saved one file of three still
        /// gets its folder and a Retry finds the file there.
        case perPostIfMultiple
        /// As `perPostIfMultiple`, and the post `condition` names always
        /// gets its folder, whatever its count: the photo pass, whose count
        /// leaves out the video yt-dlp already saved.
        case perPost(always: String)
        /// The post `ownPost` names into this folder, found on disk from an
        /// earlier run of the same post (see `RowFolder.existing`), whatever
        /// its count; every other post the run meets (a quoted tweet) as
        /// `perPostIfMultiple` places it. The destination stays the
        /// download folder: flat into the found folder, a quoted tweet's
        /// files would miss where the first run put them, be fetched again
        /// and land in another post's folder.
        case into(URL, ownPost: String)
    }

    /// The gallery-dl option that picks a post's folder from its own
    /// keywords, nil when the files go flat into the destination. The
    /// conditions are tried in order and the empty one is the fallback: no
    /// folder at all. Given with "-o" after "-D", the value takes the place
    /// of the directory "-D" set and of any "directory" in the user's own
    /// config. A keyword a post lacks makes its condition false, so a post
    /// without a `count` stays loose.
    static func directoryOption(for mode: FolderMode, format: String?) -> String? {
        var entries: [(condition: String, folder: String)] = []
        switch mode {
        case .flat: return nil
        case .perPostIfMultiple: break
        case .perPost(let always): if let format { entries.append((always, format)) }
        case .into(let folder, let ownPost): entries.append((ownPost, literalSegment(folder.lastPathComponent)))
        }
        if let format { entries.append(("count > 1", format)) }
        guard !entries.isEmpty else { return nil }
        let rules = entries.map { "\(jsonString($0.condition)): [\(jsonString($0.folder))]" } + [#""": []"#]
        return "directory={\(rules.joined(separator: ", "))}"
    }

    /// `name` as a directory format that yields exactly `name`: a brace
    /// opens a field in gallery-dl's format strings, and doubled it is a
    /// plain brace.
    static func literalSegment(_ name: String) -> String {
        name.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
    }

    /// The condition that names the post `link` points at among the posts
    /// one gallery-dl run meets (a quoted tweet is another post), nil when
    /// the link carries no id to name it by.
    static func ownPostCondition(for link: String) -> String? {
        guard let id = RowFolder.postID(of: link) else { return nil }
        switch SiteRegistry.profile(for: link).id {
        case SiteRegistry.twitter.id: return "tweet_id == \(id)"
        // Ids and codes are of letters, digits, "_" and "-" only, so
        // neither needs escaping in the condition.
        case SiteRegistry.instagram.id: return "post_shortcode == \"\(id)\""
        default: return nil
        }
    }

    private static func jsonString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text), let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    /// An Instagram profile's newest posts, `postLimit` of them at most, in
    /// one gallery-dl run (see `profileArguments`). Settled like any other
    /// gallery-dl run — counts, partial failures and exit causes alike —
    /// except that the progress bar follows the posts reached out of
    /// `postLimit`, a lone image keeps its " #1" (a later paste of the same
    /// profile must find every file under the name gallery-dl gives it, or
    /// it would fetch that image again), and an error line leaves the row
    /// as it is: one post failing among hundreds says nothing yet about the
    /// run, so only the exit decides, in app-native copy.
    @MainActor
    static func runProfile(
        item: DownloadItem,
        username: String,
        postLimit: Int,
        executablePath: String,
        outputDirectory: URL,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String? = nil,
        cookiesFile: String? = nil,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void
    ) async {
        let progress = ProfileProgress(postLimit: postLimit)
        await runAndSettle(
            item: item,
            executablePath: executablePath,
            arguments: profileArguments(
                username: username, postLimit: postLimit, outputDirectory: outputDirectory,
                cookieBrowser: cookieBrowser, cookieBrowserProfile: cookieBrowserProfile,
                cookiesFile: cookiesFile),
            outputDirectory: outputDirectory,
            looseDirectory: nil,
            register: register,
            unregister: unregister,
            lineParser: { line, item in
                // The link may be routed to another profile by its spelling
                // ("/<name>.x.com/" reads as X); the errors are Instagram's.
                parseLine(line, item: item, profileID: SiteRegistry.instagram.id, settlesErrorsAtExit: true)
                progress.record(line, item: item)
            },
            noMediaMessage: noPostsMessage,
            stripsSingleFileSuffix: false,
            settlesErrorsAtExit: true)
    }

    /// Exit 0 and no file, new or already on disk: the account showed no
    /// post to this login.
    static let noPostsMessage =
        "No posts found — the account may have none, be private, or need you signed in to Instagram in the browser selected in Settings → Cookies, then Retry."

    /// Posts reached so far, told apart by the post code every file name
    /// carries. A post counts once its first file is reported, downloaded or
    /// already on disk, so a second paste moves the bar as far as the first.
    @MainActor
    final class ProfileProgress {
        private let postLimit: Int
        private var posts: Set<String> = []

        init(postLimit: Int) { self.postLimit = max(postLimit, 1) }

        func record(_ line: String, item: DownloadItem) {
            guard let code = GalleryDlService.postCode(inPathLine: line) else { return }
            posts.insert(code)
            item.progress = min(1, Double(posts.count) / Double(postLimit))
        }
    }

    /// The post code in a reported file's name, nil for any other line. The
    /// Instagram file-name template ends every name with
    /// " [<post code>] #<n>.<extension>".
    static func postCode(inPathLine line: String) -> String? {
        let path = line.hasPrefix("# ") ? String(line.dropFirst(2)) : line
        guard path.hasPrefix("/") || path.hasPrefix("~"),
            MediaExtensions.all.contains((path as NSString).pathExtension.lowercased())
        else { return nil }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let range = stem.range(of: #" \[[A-Za-z0-9_-]+\] #\d+$"#, options: .regularExpression) else {
            return nil
        }
        let tail = stem[range]
        guard let open = tail.firstIndex(of: "["), let close = tail.firstIndex(of: "]") else { return nil }
        return String(tail[tail.index(after: open)..<close])
    }

    /// Runs gallery-dl and settles the row from its exit and the files that
    /// arrived. `noMediaMessage` is the failure for exit 0 with no file;
    /// `stripsSingleFileSuffix` drops the " #1" of a lone image;
    /// `settlesErrorsAtExit` is the line parser's (see `parseLine`), so no
    /// error line has set the status and the exit alone words the failure.
    /// `looseDirectory` is the download folder of a single post, where its
    /// one-file posts lie loose; nil for a profile, whose files all go into
    /// the account's folder, `outputDirectory`.
    @MainActor
    private static func runAndSettle(
        item: DownloadItem,
        executablePath: String,
        arguments: [String],
        outputDirectory: URL,
        looseDirectory: URL?,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void,
        lineParser: @escaping (String, DownloadItem) -> Void,
        noMediaMessage: String,
        stripsSingleFileSuffix: Bool,
        settlesErrorsAtExit: Bool
    ) async {
        let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? [])
        let reported = ReportedFiles()

        let result = await ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            item: item,
            register: register,
            unregister: unregister,
            lineParser: { line, item in
                reported.record(line)
                lineParser(line, item)
            }
        )

        // A download archive answers for a file saved before posts had
        // folders with the path the file would have now, inside the folder,
        // where it is not: the file is still loose in the download folder.
        // The row points at a reported file that is really there, or else
        // at such a loose file.
        if let looseDirectory, let path = item.outputPath, !FileManager.default.fileExists(atPath: path) {
            let paths = [path] + reported.all.map(\.path)
            let isThere = { (candidate: String) in FileManager.default.fileExists(atPath: candidate) }
            if let there = paths.first(where: isThere) {
                item.outputPath = there
            } else if let loose = paths.lazy
                .map({ looseDirectory.appendingPathComponent(($0 as NSString).lastPathComponent).path })
                .first(where: isThere)
            {
                item.outputPath = loose
            }
        }

        guard result.isSuccess else {
            // Partial failure: files DID land (counted by parseLine, skip
            // lines included) and a specific error was recorded — one file of
            // a multi-file post errored while the rest downloaded. Whether
            // the recorded error is still the status or a later file's path
            // line flipped it back to .downloading, the truthful outcome is
            // the same: name what was saved and the first error, not the
            // exit bitmask's generic guess.
            let savedCount = (item.imageCount ?? 0) + (item.videoCount ?? 0)
            // A profile pasted again reports every earlier file as skipped, so
            // its "Saved N" counts only the files this run wrote.
            let savedByRun = settlesErrorsAtExit ? item.newToolFileCount : savedCount
            if !result.wasSignal, item.outputPath != nil, savedCount > 0,
                let firstError = item.firstToolError
            {
                // "Saved N… Retry fetches the rest" is only truthful when
                // this run actually landed files. On a retry where every
                // file dedupe-SKIPPED ("# /path" lines count into
                // imageCount/videoCount by design), the mapped fatal error
                // (NSFW, auth…) IS the outcome — the partial copy would
                // demote it into a fetchable leftover.
                item.status = .failed(
                    item.newToolFileCount == 0
                        ? firstError
                        : Self.partialFailureMessage(savedCount: savedByRun, firstError: firstError))
            } else if settlesErrorsAtExit, !result.wasSignal, item.outputPath != nil, savedCount > 0,
                item.newToolFileCount > 0
            {
                // Files landed, and no error had app-native copy (only
                // those are recorded): the exit code names the cause.
                item.status = .failed(
                    Self.partialFailureMessage(savedCount: savedByRun, firstError: Self.exitCauses(code: result.code)))
            } else if case .failed = item.status {
            } else if result.wasSignal {
                // Killed by a signal — the exit bitmask only describes real
                // exits, so decoding a signal number would invent false
                // causes. (Distinguishing a user pause from a crash on this
                // path is Phase 4 scope; today both read as terminated.)
                item.status = .failed("gallery-dl was terminated (signal \(result.code))")
            } else if settlesErrorsAtExit, let firstError = item.firstToolError {
                item.status = .failed(firstError)
            } else {
                // A profile row never shows the tool's own words, warnings
                // included; the exit's causes stand alone.
                item.status = .failed(
                    Self.exitFailureMessage(
                        code: result.code, lastWarning: settlesErrorsAtExit ? nil : item.lastToolWarning))
            }
            return
        }

        let imageExts = MediaExtensions.image
        let videoExts = MediaExtensions.video
        func ext(_ name: String) -> String { URL(fileURLWithPath: name).pathExtension.lowercased() }

        // gallery-dl exited 0 but neither new files appeared nor dry-run could
        // resolve a path — the tweet's media is genuinely unreachable (most
        // often: a deleted tweet, or sensitive content the cookie session
        // can't unlock). Without this guard, the row would be marked "Done"
        // with no files, which is misleading. Prefer gallery-dl's own warning
        // (age-restriction, media unavailable, …) over the generic guess.
        // The structural flag — not the message wording — is what arms
        // DownloadManager's one-shot empty-success auto-retry.
        guard item.outputPath != nil else {
            item.emptySuccessFailure = true
            if settlesErrorsAtExit {
                // App-native copy only (a private account, say), else the
                // profile's own "no posts" wording — never a raw warning.
                item.status = .failed(item.firstToolError ?? noMediaMessage)
            } else if let warning = item.lastToolWarning {
                item.status = .failed(Self.noMediaWarningPrefix + warning)
            } else {
                item.status = .failed(noMediaMessage)
            }
            return
        }

        if settlesErrorsAtExit {
            // A profile pasted again reports every earlier file as skipped:
            // the Done row counts only what this run saved, and Show in
            // Finder points at something that is really there. A reported
            // path can be an archive hit for a file since moved or deleted.
            // Only one profile runs at a time, so what appeared in its own
            // folder is this run's.
            let afterFiles = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
            let newImages = afterFiles.filter { !beforeFiles.contains($0) && imageExts.contains(ext($0)) }.sorted()
            let newVideos = afterFiles.filter { !beforeFiles.contains($0) && videoExts.contains(ext($0)) }.sorted()
            item.imageCount = newImages.isEmpty ? nil : newImages.count
            item.videoCount = newVideos.isEmpty ? nil : newVideos.count
            if let name = newVideos.first ?? newImages.first {
                item.outputPath = outputDirectory.appendingPathComponent(name).path
            } else if let path = item.outputPath, !FileManager.default.fileExists(atPath: path) {
                // Never nil: a Done row with no output reads as the old
                // empty-success bug and is re-queued at launch. The run's
                // directory is the account's own folder inside the download
                // folder; when the tool never made it (every file an archive
                // hit), the download folder is what is really there.
                let isThere = FileManager.default.fileExists(atPath: outputDirectory.path)
                item.outputPath = (isThere ? outputDirectory : outputDirectory.deletingLastPathComponent()).path
            }
            item.recomputeMediaCategory()
            item.markCompleted()
            return
        }

        // The files this run saved are the ones it reported, never what
        // else appeared in the download folder meanwhile: other rows save
        // there too, and a post's own folder is not in that listing at all.
        let newImages = reported.saved.filter { imageExts.contains(ext($0)) }
        let newVideos = reported.saved.filter { videoExts.contains(ext($0)) }
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

        // Rename single-image files: strip trailing " #1" suffix. Only when
        // the run saved that one image, as before posts had folders — a
        // quoted tweet's lone photo beside a post of several keeps its
        // number, so the next run finds it under the name it asks for —
        // and only a file loose in the download folder is a one-file
        // post's: inside a post's folder, " #1" is the first of several.
        let isLoose = { (path: String) in looseDirectory.map { Self.isDirectlyInside(path, $0) } ?? false }
        if stripsSingleFileSuffix, newImages.count == 1, let path = newImages.first, isLoose(path) {
            let u = URL(fileURLWithPath: path)
            let stem = u.deletingPathExtension().lastPathComponent
            if stem.hasSuffix(" #1") {
                let clean = String(stem.dropLast(3))
                let newPath = u.deletingLastPathComponent()
                    .appendingPathComponent(clean + "." + u.pathExtension).path
                if (try? FileManager.default.moveItem(atPath: path, toPath: newPath)) != nil,
                    item.outputPath == path
                {
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
    /// `outputDirectory` is the download folder; `folderMode` says where in
    /// it the post's files go.
    static func arguments(
        for url: String,
        outputDirectory: URL,
        folderMode: FolderMode = .flat,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String? = nil,
        cookiesFile: String?,
        extraArgs: [String] = []
    ) -> [String] {
        let profile = SiteRegistry.profile(for: url)
        return commandLine(
            url: url, outputDirectory: outputDirectory,
            directoryOption: directoryOption(for: folderMode, format: profile.galleryDlFolderFormat),
            cookieBrowser: cookieBrowser, cookieBrowserProfile: cookieBrowserProfile, cookiesFile: cookiesFile,
            siteArgs: profile.galleryDlArgs + extraArgs)
    }

    /// The command line for an Instagram profile's newest posts.
    ///
    /// The posts tab ("/<username>/posts/") is the account's own timeline —
    /// photos, carousels and reels alike, newest first, each post once.
    /// Handed the profile itself, gallery-dl would read the posts tab only
    /// by default, but a user's config could widen that to stories,
    /// highlights and tagged; the reels tab would leave the photos out.
    ///
    /// `max-posts` stops the walk after that many posts, a carousel counting
    /// as one, and no further page of the timeline is asked for. `--range`
    /// counts files, so it would cut a carousel short and still pass the
    /// cap in posts.
    ///
    /// Nothing here touches gallery-dl's own pause between Instagram
    /// requests (several seconds each): a whole account is many requests
    /// under the browser login, and that pause is what keeps it from
    /// looking like a scraper. Files already on disk are skipped, as they
    /// are by default, so pasting the profile again fetches only what is
    /// missing.
    ///
    /// `videos=merged` takes each video's ready-made file, the largest of
    /// the versions Instagram lists (verified against gallery-dl 1.32.13's
    /// instagram extractor). Left at its default, a video that also has a
    /// DASH manifest is handed to gallery-dl's yt-dlp downloader instead,
    /// which Homebrew's gallery-dl cannot import: it logs an error, then
    /// falls back to that same ready-made file. What "merged" gives up is
    /// the DASH streams, which can reach the original resolution, and only
    /// a gallery-dl that can import yt-dlp would ever fetch them.
    static func profileArguments(
        username: String,
        postLimit: Int,
        outputDirectory: URL,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String? = nil,
        cookiesFile: String?
    ) -> [String] {
        commandLine(
            url: profilePostsURL(username: username), outputDirectory: outputDirectory,
            cookieBrowser: cookieBrowser, cookieBrowserProfile: cookieBrowserProfile, cookiesFile: cookiesFile,
            siteArgs: SiteRegistry.instagram.galleryDlArgs + [
                "-o", "max-posts=\(postLimit)",
                "-o", "videos=merged",
            ])
    }

    /// Always the one host gallery-dl's Instagram extractor recognises: it
    /// reads neither "m.instagram.com", "instagr.am" nor an uppercase host.
    static func profilePostsURL(username: String) -> String {
        "https://www.instagram.com/\(username)/posts/"
    }

    private static func commandLine(
        url: String,
        outputDirectory: URL,
        directoryOption: String? = nil,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String?,
        cookiesFile: String?,
        siteArgs: [String]
    ) -> [String] {
        var args = CookieArgs.make(
            browser: cookieBrowser, profile: cookieBrowserProfile, file: cookiesFile)
        args += [
            "--dest", outputDirectory.path,
            "-D", ".",
        ]
        // After "-D", which it must override (see `directoryOption`).
        if let directoryOption { args += ["-o", directoryOption] }
        args += [
            // Large X/Reddit videos (multi-GB) drop the connection or read-time out
            // on a flaky link; the default ~4 retries / 30s aren't enough. Be generous.
            "--retries", "10",
            "-o", "downloader.http.timeout=60",
        ]
        args += siteArgs
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
    /// outputPath stay the video's. Per-item failures are deliberately
    /// silent: the video is the download's outcome, and a sweep that finds
    /// nothing is the normal case (video-only posts). The exit result is
    /// returned (nil when the profile declares no sweep) so the caller can
    /// notice a SYSTEMATICALLY failing sweep — every run exiting non-zero —
    /// which silently loses all photos from mixed posts.
    ///
    /// `folderMode` places the photos as it places a post's files (see
    /// `FolderMode`); the result names every photo the pass reported, saved
    /// or already on disk, so the caller can see where the post's photos are.
    @MainActor
    @discardableResult
    static func runImageSweep(
        item: DownloadItem,
        executablePath: String,
        outputDirectory: URL,
        folderMode: FolderMode = .flat,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String? = nil,
        cookiesFile: String? = nil,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void
    ) async -> SweepResult? {
        guard let sweepArgs = SiteRegistry.profile(for: item.url).imageSweepArgs else { return nil }
        let reported = ReportedFiles()

        let result = await ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments(
                for: item.url, outputDirectory: outputDirectory, folderMode: folderMode,
                cookieBrowser: cookieBrowser, cookieBrowserProfile: cookieBrowserProfile,
                cookiesFile: cookiesFile, extraArgs: sweepArgs),
            item: item,
            register: register,
            unregister: unregister,
            // Collects the photos' paths and nothing else: the video owns
            // status/title/outputPath.
            lineParser: { line, _ in reported.record(line) }
        )

        let newImages = reported.saved.filter {
            MediaExtensions.image.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }
        if !newImages.isEmpty {
            item.imageCount = (item.imageCount ?? 0) + newImages.count
            item.recomputeMediaCategory()
        }
        return SweepResult(
            exit: result,
            photos: reported.all.filter {
                MediaExtensions.image.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
            })
    }

    /// How a photo pass ended, and the photos it reported.
    struct SweepResult {
        let exit: ProcessResult
        /// Every photo reported, saved by the pass or already on disk.
        let photos: [ReportedMedia]

        var isSuccess: Bool { exit.isSuccess }
    }

    /// A media file gallery-dl reported: saved by this run, or already on
    /// disk and skipped ("# <path>").
    struct ReportedMedia: Equatable {
        let path: String
        let wasSkipped: Bool
    }

    /// The media file a line reports, nil for any other line. gallery-dl
    /// prints each saved file's path on its own line, and "# <path>" for a
    /// file already there; Python/urllib3 warning lines also start with "/"
    /// but name no media file.
    static func reportedMedia(in line: String) -> ReportedMedia? {
        let isSkipLine = line.hasPrefix("# /") || line.hasPrefix("# ~")
        let pathLine = isSkipLine ? String(line.dropFirst(2)) : line
        guard pathLine.hasPrefix("/") || pathLine.hasPrefix("~"),
            MediaExtensions.all.contains((pathLine as NSString).pathExtension.lowercased())
        else { return nil }
        return ReportedMedia(path: pathLine, wasSkipped: isSkipLine)
    }

    /// The files one run reported, in order.
    @MainActor
    final class ReportedFiles {
        private(set) var all: [ReportedMedia] = []

        /// The paths of the files this run saved itself.
        var saved: [String] { all.filter { !$0.wasSkipped }.map(\.path) }

        func record(_ line: String) {
            if let media = GalleryDlService.reportedMedia(in: line) { all.append(media) }
        }
    }

    /// True when `path` names an entry directly inside `directory`.
    static func isDirectlyInside(_ path: String, _ directory: URL) -> Bool {
        URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path
    }

    // MARK: - Output parsing

    /// `profileID` names the site whose copy the errors get; nil reads it
    /// off the row's link. With `settlesErrorsAtExit` an error line never
    /// touches the status: only its app-native copy is recorded, when it
    /// has one, and the run's exit words the outcome — no Failed flash
    /// while files keep arriving, and no raw tool line left on the row.
    @MainActor
    static func parseLine(
        _ line: String, item: DownloadItem, profileID: String? = nil, settlesErrorsAtExit: Bool = false
    ) {
        guard !line.isEmpty else { return }

        // gallery-dl prints each downloaded file's path on its own line, or
        // "# <path>" when the file already exists and was skipped. Filenames
        // embed the tweet id (see formatArgs), so a skip can only mean this
        // exact tweet's media is already on disk — treat it as this row's
        // output instead of letting the run end as "no media found".
        // Python/urllib3 warning lines also start with "/" but contain ": ",
        // and are passed over here like any other path that names no media.
        if let media = reportedMedia(in: line) {
            let ext = (media.path as NSString).pathExtension.lowercased()

            let isImage = MediaExtensions.image.contains(ext)
            let isVideo = MediaExtensions.video.contains(ext)
            if !media.wasSkipped { item.newToolFileCount += 1 }
            item.status = .downloading
            // A file landing means any backoff wait is over — a stale
            // "14 minutes (rate limited)" ETA must not outlive the wait.
            item.eta = nil
            item.outputPath = media.path
            if isImage {
                item.imageCount = (item.imageCount ?? 0) + 1
            } else if isVideo {
                item.videoCount = (item.videoCount ?? 0) + 1
            }
            item.recomputeMediaCategory()  // update category progressively

            if item.title == nil {
                item.title = displayTitle(forPath: media.path)
            }
            return
        }
        let isSkipLine = line.hasPrefix("# /") || line.hasPrefix("# ~")
        if line.hasPrefix("/") || line.hasPrefix("~") || isSkipLine { return }

        // Warnings aren't failures by themselves, but when the run ends with no
        // files they're the only clue why (age-restricted tweet, media removed
        // by a DMCA notice, …). Remember the most recent one so the
        // empty-success guard in run() can show it instead of a generic guess.
        // Must come before the "error" check: warning text may contain the
        // word "error" (e.g. "API errors (1/10)") without being fatal.
        if let r = line.range(of: "[warning] ") {
            let msg = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if settlesErrorsAtExit, line.contains("[instagram]"), msg.hasSuffix("posts are private") {
                recordFirstError(Self.instagramPrivateAccountMessage, item: item)
            }
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
            recordFirstError(Self.instagramLoginMessage, item: item)
            if settlesErrorsAtExit { return }
            if case .failed = item.status { return }
            item.status = .failed(Self.instagramLoginMessage)
            return
        }

        if line.lowercased().contains("error") {
            // Known raw errors get app-native copy naming the true cause and
            // the in-app fix; everything else stays verbatim.
            let profileID = profileID ?? SiteRegistry.profile(for: item.url).id
            let mapped = Self.mappedErrorMessage(for: line, profileID: profileID)
            if settlesErrorsAtExit {
                if let mapped { recordFirstError(mapped, item: item) }
                return
            }
            let message = mapped ?? line
            recordFirstError(message, item: item)
            if case .failed = item.status { return }
            item.status = .failed(message)
        }
    }

    /// The status alone can't carry a per-file error to the end of the run —
    /// gallery-dl keeps going and the next successful file's path line flips
    /// the item back to `.downloading`. Remember the FIRST error so run()'s
    /// exit handling can report a truthful partial failure.
    @MainActor
    private static func recordFirstError(_ message: String, item: DownloadItem) {
        if item.firstToolError == nil { item.firstToolError = message }
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
