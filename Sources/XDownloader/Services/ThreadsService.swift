import Foundation

/// In-app resolver for Threads posts. Neither yt-dlp nor gallery-dl has a
/// Threads extractor, but a public post's page carries the whole post —
/// every carousel child, original-resolution images and a progressive MP4 —
/// as JSON inside a `<script type="application/json">` tag, so one page
/// fetch resolves it. Everything but `run` is a pure function of the fetched
/// page. The page is requested logged out; only when Threads withholds the
/// post from logged-out visitors is there one more try with the owner's
/// browser login (see ThreadsSignedInPage). The files themselves are always
/// fetched without cookies, and nothing resolved is ever stored, because the
/// media addresses are signed and expire within days.
enum ThreadsService {

    // MARK: - Running a download

    /// Resolves the post and downloads its files. Returns true only when
    /// every file is on disk.
    ///
    /// Unlike the fxtwitter rescue this is the ONLY downloader for its site,
    /// so it never restores an earlier status: every exit but a cancel
    /// leaves the row completed or failed with a message of its own. A
    /// cancel (Stop, or the row's ✕) leaves no outcome — DownloadManager
    /// sets the paused state, or the row is already gone.
    ///
    /// `session` is a seam for tests; the default keeps and sends no cookies.
    /// `signedInPage` is the signed-in second try, nil where there is none
    /// to offer. It is called at most once per run, and only after the
    /// logged-out page came back restricted or as the login page.
    @MainActor
    static func run(
        item: DownloadItem, outputDirectory: URL, session: URLSession = DirectDownload.session,
        signedInPage: SignedInPageFetch? = nil
    ) async -> Bool {
        item.status = .fetching
        // While fetching, any eta is shown as a rate-limit wait.
        item.eta = nil
        // This run owns the outcome; only the two outcomes that may be
        // transient arm the one-shot auto-retry again.
        item.emptySuccessFailure = false

        guard let link = parseLink(item.url), let pageURL = canonicalURL(for: link) else {
            // Profile pages, search, the feed: never crawled.
            item.status = .failed(notAPostLinkMessage)
            return false
        }

        let post: ResolvedPost
        var usedSignIn = false
        switch await fetchPost(at: pageURL, code: link.code, session: session) {
        case .resolved(let resolved): post = resolved
        case .cancelled: return false
        case .failed(let message, let mayBeTransient, let failure, let endedAt):
            guard let failure, needsSignIn(failure), let signedInPage else {
                item.emptySuccessFailure = mayBeTransient
                item.status = .failed(message)
                return false
            }
            // No address Threads is known to answer without a redirect: the
            // login is not sent at all.
            guard let address = signedInAddress(for: link, requested: pageURL, loggedOutEnd: endedAt) else {
                item.status = .failed(signedInNeedsFullLinkMessage)
                return false
            }
            // The one signed-in try of this run. Whatever it ends in is
            // final: the auto-retry stays off, or it would send the login a
            // second time without being asked.
            usedSignIn = true
            switch signedInOutcome(await signedInPage(address), code: link.code, loggedOutMessage: message) {
            case .resolved(let resolved): post = resolved
            case .cancelled: return false
            case .failed(let message, _, _, _):
                item.status = .failed(message)
                return false
            }
        }

        let stem = fileStem(author: post.author, text: post.text, code: post.code)
        // Two or more files get a folder named after the stem. The count is
        // the post's own, so a Retry after a partial run finds the files it
        // already saved; the re-resolve below keeps the count, so the folder
        // cannot change mid-run.
        let folder = RowFolder.folder(in: outputDirectory, name: stem, fileCount: post.media.count)
        RowFolder.use(folder, for: item)
        let directory = folder ?? outputDirectory
        var media = post.media
        var savedPaths: [String] = []
        var imageCount = 0
        var videoCount = 0
        // A per-file failure must not silently shrink the file count under a
        // green "Done" — remember the last one so the final message can name
        // a concrete reason.
        var lastFailure: DirectDownload.FileFailure?
        var resolvedAgain = false

        var index = 0
        while index < media.count {
            // Stop cancels the wrapping Task (see DownloadManager) — bail
            // out between files; a transfer in flight reports .cancelled.
            if Task.isCancelled { return false }
            let entry = media[index]
            let name = baseName(stem: stem, index: index, count: media.count)

            var saved = DirectDownload.existingFile(baseName: name, in: directory)
            if saved == nil {
                item.status = .downloading
                let outcome = await DirectDownload.download(
                    entry.url, to: directory, baseName: name,
                    fallbackExtension: entry.kind == .video ? "mp4" : "jpg",
                    item: item, fileIndex: index, fileCount: media.count, session: session)
                switch outcome {
                case .saved(let url):
                    saved = url
                case .cancelled:
                    return false
                case .failed(let failure):
                    // The signed address ran out (or was refused): resolve
                    // the post afresh, once, and try this file again. A
                    // second refusal is reported like any other failure.
                    // (Not for a post only the login could see: logged out
                    // the answer is known, and the login is used once.)
                    if case .httpStatus(403) = failure, !resolvedAgain, !usedSignIn {
                        resolvedAgain = true
                        item.status = .fetching
                        item.speed = nil
                        if case .resolved(let fresh) = await fetchPost(at: pageURL, code: link.code, session: session),
                            fresh.code == post.code, fresh.media.count == media.count
                        {
                            media = fresh.media
                            continue
                        }
                        if Task.isCancelled { return false }
                    }
                    lastFailure = failure
                }
            }
            if let saved {
                savedPaths.append(saved.path)
                if entry.kind == .video { videoCount += 1 } else { imageCount += 1 }
            }
            index += 1
        }

        if Task.isCancelled { return false }
        guard let first = savedPaths.first else {
            item.speed = nil
            item.status = .failed(
                DirectDownload.zeroSavedFailureMessage(lastFailure: lastFailure) ?? nothingSavedMessage(lastFailure: lastFailure))
            return false
        }

        item.outputPath = savedPaths.first { !MediaExtensions.image.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) } ?? first
        item.imageCount = imageCount > 0 ? imageCount : nil
        item.videoCount = videoCount > 0 ? videoCount : nil
        item.recomputeMediaCategory()
        if item.title == nil { item.title = displayTitle(author: post.author, text: post.text) }
        if let lastFailure {
            // Some files failed: keep the saved ones on the row, but the run
            // must not read as a clean "Done" with a silently smaller count.
            // The count is what is ON DISK — this run's downloads and the
            // files an earlier run saved.
            item.speed = nil
            item.status = .failed(
                DirectDownload.partialFailureMessage(saved: savedPaths.count, attempted: media.count, lastFailure: lastFailure))
            return false
        }
        item.markCompleted()
        return true
    }

    /// What the page request sends, and nothing else of ours: without all
    /// three Threads answers HTTP 200 with a page that carries no post data.
    /// URLSession's own User-Agent and "Accept: */*" are among the refused.
    static let pageHeaders: [String: String] = [
        "User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Sec-Fetch-Mode": "navigate",
    ]

    /// Whether a failed resolve may be a passing answer worth the one
    /// automatic retry. Threads has answered "no such post" once for a post
    /// that existed, and a page without post data can be a bad moment on
    /// their side. Sign-in, restriction, a post without media and a malformed
    /// link give the same answer every time.
    static func mayBeTransient(_ failure: Failure) -> Bool {
        switch failure {
        case .notFound, .noPostData: return true
        case .loginRequired, .restricted, .blockedShell, .noMedia: return false
        }
    }

    private enum PageOutcome {
        case resolved(ResolvedPost)
        /// `failure` is nil when the request itself failed. `endedAt` is
        /// the address the request's redirects ended at.
        case failed(message: String, mayBeTransient: Bool, failure: Failure?, endedAt: URL? = nil)
        case cancelled
    }

    /// Requests the page at the address given with the owner's login, once.
    /// The address is `signedInAddress`'s, not the link's. Supplied by
    /// DownloadManager, which owns the settings, the tool and the process
    /// registry; a seam for tests.
    typealias SignedInPageFetch = @MainActor (URL) async -> ThreadsSignedInPage.Outcome

    /// The two answers a login can change. Every other failure is the same
    /// signed in, so the login is not sent for it.
    static func needsSignIn(_ failure: Failure) -> Bool {
        switch failure {
        case .restricted, .loginRequired: return true
        case .notFound, .blockedShell, .noPostData, .noMedia: return false
        }
    }

    /// The address the signed-in try asks for, nil when there is none it can
    /// ask for safely. yt-dlp answers a redirect with a second request, and
    /// the login travels with both, so the address must be one Threads
    /// answers in place. That is the post address the logged-out request
    /// ENDED at: Threads moves `/t/<code>` and a wrong or changed username
    /// there. When the logged-out request ended somewhere else (the login
    /// page), the link's own address stands in if it names the author; a
    /// `/t/<code>` link has nothing to stand in.
    static func signedInAddress(for link: PostLink, requested: URL, loggedOutEnd: URL?) -> URL? {
        if let loggedOutEnd, loggedOutEnd.scheme?.lowercased() == "https", loggedOutEnd.host?.lowercased() == "www.threads.com",
            let ended = parseLink(loggedOutEnd.absoluteString), ended.code == link.code, ended.username != nil
        {
            return canonicalURL(for: ended)
        }
        return link.username == nil ? nil : requested
    }

    /// What the signed-in try leaves. `loggedOutMessage` stands when the
    /// try could not be made at all.
    private static func signedInOutcome(
        _ outcome: ThreadsSignedInPage.Outcome, code: String, loggedOutMessage: String
    ) -> PageOutcome {
        switch outcome {
        case .cancelled:
            return .cancelled
        case .noCookieSource:
            return .failed(message: loggedOutMessage, mayBeTransient: false, failure: nil)
        case .toolMissing:
            return .failed(message: signedInToolMissingMessage, mayBeTransient: false, failure: nil)
        case .failed(let failure):
            return .failed(message: message(for: failure), mayBeTransient: false, failure: nil)
        case .httpStatus(let status):
            return .failed(message: signedInHTTPStatusMessage(status), mayBeTransient: false, failure: nil)
        case .page(let page, let usedCookiesFile):
            switch resolve(html: page.html, finalURL: page.finalURL, code: code) {
            case .success(let post):
                // Redirected after all: that took more than the one
                // request, and a download must not make it look like the
                // link is fine to use again.
                if page.redirected { return .failed(message: signedInRedirectedMessage, mayBeTransient: false, failure: nil) }
                return .resolved(post)
            case .failure(let failure):
                // Still withheld: the login has no Threads sign-in in it.
                // A redirected run keeps these messages: where Threads sent
                // the request is the reason (its login page, for one).
                let text =
                    needsSignIn(failure)
                    ? (usedCookiesFile ? signInMissingInCookiesFileMessage : signInMissingInBrowserMessage)
                    : message(for: failure)
                return .failed(message: text, mayBeTransient: false, failure: failure)
            }
        }
    }

    /// One page request, redirects followed. The address the redirects END
    /// at is what gets classified: a missing post and the login wall both
    /// answer HTTP 200, on another page.
    @MainActor
    private static func fetchPost(at pageURL: URL, code: String, session: URLSession) async -> PageOutcome {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: DirectDownload.request(for: pageURL, headers: pageHeaders))
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
            return .failed(message: pageUnreachableMessage(.transport(error)), mayBeTransient: false, failure: nil)
        }
        if Task.isCancelled { return .cancelled }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .failed(message: pageUnreachableMessage(.httpStatus(http.statusCode)), mayBeTransient: false, failure: nil)
        }
        switch resolve(html: String(decoding: data, as: UTF8.self), finalURL: response.url, code: code) {
        case .success(let post):
            return .resolved(post)
        case .failure(let failure):
            return .failed(
                message: message(for: failure), mayBeTransient: mayBeTransient(failure), failure: failure, endedAt: response.url)
        }
    }

    // MARK: - Failure messages

    // Every Threads failure names its own cause: yt-dlp never runs for these
    // links, so there is no earlier, more informative message to fall back
    // on. Internal (not private) so tests share one source of truth. Where
    // a Retry cannot change the outcome the copy says so instead of
    // promising one.
    static let notAPostLinkMessage =
        "This Threads link isn't a single post — open the post on threads.com and paste its own link instead."
    static let notFoundMessage =
        "Threads post not found — it may be deleted, or the link may be incomplete; check the link, then Retry."
    // These two stand when no login could be tried: Settings name no
    // browser and no cookies.txt.
    static let loginRequiredMessage =
        "This post needs sign-in at threads.com — choose your browser in Settings → Cookies and sign in at threads.com there "
        + "(an Instagram sign-in alone is not enough), then Retry."
    static let restrictedMessage =
        "Threads limits who can see this post — choose your browser in Settings → Cookies and sign in at threads.com there "
        + "(an Instagram sign-in alone is not enough), then Retry."
    // The login was tried and Threads still withheld the post. The browser
    // is the one in Settings, whichever that is.
    static let signInMissingInBrowserMessage =
        "Threads still hides this post — sign in at threads.com in the browser selected in Settings → Cookies "
        + "(an Instagram sign-in alone is not enough), then Retry."
    static let signInMissingInCookiesFileMessage =
        "Threads still hides this post — the cookies.txt chosen in Settings → Cookies has no Threads sign-in. "
        + "Clear it to use your browser, or export it again after signing in at threads.com "
        + "(an Instagram sign-in alone is not enough), then Retry."
    static let signedInToolMissingMessage =
        "Threads only shows this post to signed-in visitors — reading it with your sign-in needs yt-dlp, which is not installed. "
        + "Install yt-dlp, then Retry."
    static let signedInToolNotStartedMessage =
        "Threads only shows this post to signed-in visitors — yt-dlp, which reads it with your sign-in, couldn't be started. "
        + "Reinstall yt-dlp, then Retry."
    static let signedInToolOutdatedMessage =
        "Threads only shows this post to signed-in visitors — the installed yt-dlp is too old to read it with your sign-in. "
        + "Update yt-dlp, then Retry."
    // Reading the browser's cookies can wait on a macOS prompt; the tool
    // cannot tell that apart from a server that does not answer.
    static let signedInTimedOutMessage =
        "Couldn't load the post from Threads with your sign-in — no answer in time. "
        + "If macOS is asking for permission to read the browser's cookie storage, allow it; otherwise check the connection. Then Retry."
    // The link carries no author, so there is no address the login could
    // be sent to without Threads redirecting it.
    static let signedInNeedsFullLinkMessage =
        "Threads only shows this post to signed-in visitors, and a short link can't be read with your sign-in — "
        + "open the post on threads.com and paste its full link (the one with the author's name) instead."
    static let signedInRedirectedMessage =
        "Threads moved this link to another address, so the post wasn't downloaded with your sign-in — "
        + "open the post on threads.com and paste its link from there instead."
    static let signedInNoPageMessage =
        "Couldn't load the post from Threads with your sign-in — check the connection, then Retry."
    static let signedInUndecodableMessage =
        "Couldn't read the page yt-dlp returned for this Threads post — update yt-dlp, then Retry."
    static let blockedShellMessage =
        "Threads returned an empty page — the link may be malformed, or Threads changed its site; check the link, then Retry."
    static let noPostDataMessage =
        "Threads sent the page without the post's data — wait a moment, then Retry. If it persists, Threads may have changed its site."
    static let noMediaMessage =
        "No photo or video in this Threads post — text, link cards and GIFs can't be downloaded."

    /// The page request itself failed: no answer, or an HTTP error status.
    static func pageUnreachableMessage(_ failure: DirectDownload.FileFailure) -> String {
        "Couldn't load the post from Threads — \(DirectDownload.shortReason(for: failure)). Check the connection, then Retry."
    }

    /// The signed-in request was answered with an HTTP error status. Too
    /// many requests is the one status where a Retry right away makes
    /// things worse.
    static func signedInHTTPStatusMessage(_ status: Int) -> String {
        let reason = DirectDownload.shortReason(for: .httpStatus(status))
        guard status != 429 else {
            return "Couldn't load the post from Threads with your sign-in — \(reason). "
                + "Threads is limiting requests: wait a few minutes before you Retry."
        }
        return "Couldn't load the post from Threads with your sign-in — \(reason). Check the connection, then Retry."
    }

    /// The post resolved, but not one of its files could be saved. A Retry
    /// resolves the post again, so it also gets fresh media addresses.
    static func nothingSavedMessage(lastFailure: DirectDownload.FileFailure?) -> String {
        guard let lastFailure else { return "None of this post's files could be saved — Retry." }
        return "None of this post's files could be saved — \(DirectDownload.shortReason(for: lastFailure)). Retry fetches them again."
    }

    /// The message a failed signed-in try puts on the row. Always one of
    /// the app's own: nothing the tool printed is ever shown.
    static func message(for failure: ThreadsSignedInPage.FetchFailure) -> String {
        switch failure {
        case .toolNotStarted: return signedInToolNotStartedMessage
        case .cookiesUnreadable: return YtDlpService.cookieDatabaseMessage
        case .toolOutdated: return signedInToolOutdatedMessage
        case .timedOut: return signedInTimedOutMessage
        case .noPage: return signedInNoPageMessage
        case .undecodable: return signedInUndecodableMessage
        }
    }

    /// The message a resolve failure puts on the row.
    static func message(for failure: Failure) -> String {
        switch failure {
        case .notFound: return notFoundMessage
        case .loginRequired: return loginRequiredMessage
        case .restricted: return restrictedMessage
        case .blockedShell: return blockedShellMessage
        case .noPostData: return noPostDataMessage
        case .noMedia: return noMediaMessage
        }
    }

    // MARK: - Link parsing

    /// The one post a Threads link names. Only `code` identifies the post:
    /// the username in a link is not authoritative (the server redirects a
    /// wrong one to the real owner), and `/t/<code>` links carry none.
    struct PostLink: Equatable {
        let username: String?
        let code: String
    }

    /// Exact hosts, compared lowercased — never a substring test: a
    /// substring would also claim "somethreads.com" and any link that merely
    /// mentions a Threads address in its query.
    static let hosts: Set<String> = ["threads.com", "www.threads.com", "threads.net", "www.threads.net"]

    private static let domains = ["threads.com", "threads.net"]

    /// True for a link on Threads — the site's domains and their subdomains,
    /// in any letter case. Wider than `parseLink` on purpose: a Threads link
    /// that is not a single post still belongs to this site, and is turned
    /// down with a message of its own instead of being handed to yt-dlp.
    static func isThreadsHost(_ link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let codePattern = "[A-Za-z0-9_-]{5,}"
    private static let postPathPattern = "^/@?([A-Za-z0-9._]+)/post/(\(codePattern))(?:/(?:embed|media)?)?/?$"
    private static let shortPathPattern = "^/t/(\(codePattern))/?$"

    /// Parses a link to a single Threads post; nil for everything else —
    /// other sites, profile pages, search, the feed. The query string is
    /// ignored entirely: share-link parameters are tracking only.
    static func parseLink(_ link: String) -> PostLink? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host?.lowercased(), hosts.contains(host)
        else { return nil }
        let path = components.path
        if let groups = captures(of: postPathPattern, in: path) {
            return PostLink(username: groups[0], code: groups[1])
        }
        if let groups = captures(of: shortPathPattern, in: path) {
            return PostLink(username: nil, code: groups[0])
        }
        return nil
    }

    /// The one address fetched for a post, whatever form the link had
    /// (threads.net, no www, /media, share parameters).
    static func canonicalURL(for link: PostLink) -> URL? {
        if let username = link.username {
            return URL(string: "https://www.threads.com/@\(username)/post/\(link.code)")
        }
        return URL(string: "https://www.threads.com/t/\(link.code)")
    }

    // MARK: - Locating the post

    /// Returns the LINKED post's object and nothing else. The rule: the
    /// object whose `data.media` is itself an object with `code` equal to
    /// the link's code and a `user` object. A search for the first object
    /// carrying the code is unsafe — related posts that quote the target
    /// embed a copy of it, code included — while replies, the parent thread
    /// and related posts all live under other keys and never satisfy this
    /// rule. The position of the script tag is not stable, so every tag that
    /// mentions the code is tried.
    static func findTarget(html: String, code: String) -> [String: Any]? {
        guard let regex = try? NSRegularExpression(pattern: scriptPattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let whole = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: whole) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let body = html[range]
            guard body.contains(code), body.contains("\"media\"") else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { continue }
            if let target = target(in: json, code: code) { return target }
        }
        return nil
    }

    private static let scriptPattern = "<script type=\"application/json\"[^>]*>(.*?)</script>"

    private static func target(in value: Any, code: String) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let data = dict["data"] as? [String: Any],
                let media = data["media"] as? [String: Any],
                media["code"] as? String == code,
                media["user"] is [String: Any]
            {
                return media
            }
            for child in dict.values {
                if let found = target(in: child, code: code) { return found }
            }
        } else if let list = value as? [Any] {
            for child in list {
                if let found = target(in: child, code: code) { return found }
            }
        }
        return nil
    }

    // MARK: - Media extraction

    /// One downloadable file of a post. `url` must be requested exactly as
    /// given: the address is signed, and changing any part of it (to ask for
    /// a bigger size, say) is answered with HTTP 403.
    struct Media: Equatable {
        enum Kind: String {
            case image
            case video
        }

        let kind: Kind
        let url: URL
        /// Pixel size of an image. Always nil for a video: the page only
        /// states the size of the uploaded source, and the progressive file
        /// actually served is smaller (720 wide), so any number here would
        /// overstate what gets saved.
        let width: Int?
        let height: Int?
    }

    /// The constant image Threads serves logged-out in place of every GIF.
    /// It is the same file for every post, so it counts as no media.
    static let gifPlaceholderMarker = "static.cdninstagram.com/rsrc.php"

    /// Media carried directly by one post or carousel child, in post order.
    static func mediaOf(_ node: [String: Any]) -> [Media] {
        // A carousel repeats its first child at post level; the children are
        // the real list.
        if let children = node["carousel_media"] as? [[String: Any]], !children.isEmpty {
            return children.flatMap { mediaOf($0) }
        }
        // Video before image: a video item also carries cover images, and
        // taking those would save a still instead of the video. Every entry
        // of `video_versions` held the same progressive MP4 in every sample.
        if let versions = node["video_versions"] as? [[String: Any]],
            let url = versions.lazy.compactMap({ mediaURL($0["url"]) }).first
        {
            return [Media(kind: .video, url: url, width: nil, height: nil)]
        }
        if let image = bestImage(of: node) { return [image] }
        if let gif = gif(of: node) { return [gif] }
        return []
    }

    /// The original-resolution candidate. The list also holds downscales and
    /// SQUARE CROPS, in no dependable order, so the pick is the candidate
    /// whose size equals the post's stated original size, else the largest
    /// by area — never by position. A text post still has the key, with an
    /// empty list.
    private static func bestImage(of node: [String: Any]) -> Media? {
        let raw = ((node["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]]) ?? []
        let candidates = raw.compactMap { candidate -> Media? in
            guard let url = mediaURL(candidate["url"]) else { return nil }
            return Media(kind: .image, url: url, width: candidate["width"] as? Int, height: candidate["height"] as? Int)
        }
        guard !candidates.isEmpty else { return nil }
        if let width = node["original_width"] as? Int, let height = node["original_height"] as? Int,
            let original = candidates.first(where: { $0.width == width && $0.height == height })
        {
            return original
        }
        return candidates.max { area($0) < area($1) }
    }

    private static func area(_ media: Media) -> Int {
        (media.width ?? 0) * (media.height ?? 0)
    }

    /// A GIF attachment, saved as an image file. Logged-out pages only ever
    /// carried the placeholder; a real address is taken as it comes.
    private static func gif(of node: [String: Any]) -> Media? {
        guard let images = (node["giphy_media_info"] as? [String: Any])?["images"] as? [String: Any] else { return nil }
        let pick =
            images["original"] as? [String: Any] ?? images["fixed_height"] as? [String: Any]
            ?? images.keys.sorted().lazy.compactMap { images[$0] as? [String: Any] }.first
        guard let pick, let raw = pick["url"] as? String, !raw.contains(gifPlaceholderMarker), let url = mediaURL(raw) else {
            return nil
        }
        return Media(kind: .image, url: url, width: pick["width"] as? Int, height: pick["height"] as? Int)
    }

    /// Only an https address with a host counts as media. The page is the
    /// only source of these addresses, and anything else in that place — a
    /// file:// address would be read off this Mac and copied into the
    /// download folder — is not a file of the post.
    private static func mediaURL(_ value: Any?) -> URL? {
        guard let raw = value as? String, let url = URL(string: raw),
            url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: - Resolving

    /// Which post the media came from.
    enum MediaSource: String {
        /// The linked post's own media.
        case post
        case quotedPost = "quoted_post"
        case repostedPost = "reposted_post"
        /// Media of another post shown inline under a link card (an
        /// Instagram reel, for one).
        case linkedInlineMedia = "linked_inline_media"
    }

    /// A post resolved to its files. `author`, `text` and `code` describe
    /// the post that OWNS the media — the quoted, reposted or linked post
    /// when the linked post has none of its own — so the files are named
    /// after the person who made them, and downloading the original post
    /// directly produces the same names.
    struct ResolvedPost: Equatable {
        let author: String
        let text: String
        let code: String
        let source: MediaSource
        let media: [Media]
    }

    /// Why a page yielded nothing to download.
    enum Failure: Error, Equatable, CaseIterable {
        /// Redirected to the feed: deleted post or a code that never existed.
        case notFound
        /// Redirected to the login page.
        case loginRequired
        /// The post exists but Threads withholds it from logged-out visitors.
        case restricted
        /// A bare error page without route information: malformed code, or
        /// the request was not taken for a browser's.
        case blockedShell
        /// The page loaded but carries no object for this post.
        case noPostData
        /// The post resolved but has nothing downloadable.
        case noMedia
    }

    /// Resolves a fetched page. `finalURL` is the address after redirects:
    /// every failure page answers HTTP 200, so the status code says nothing.
    static func resolve(html: String, finalURL: URL?, code: String) -> Result<ResolvedPost, Failure> {
        guard let post = findTarget(html: html, code: code) else {
            return .failure(classifyFailure(finalURL: finalURL, html: html))
        }
        guard let resolved = resolveMedia(in: post, linkCode: code) else { return .failure(.noMedia) }
        return .success(resolved)
    }

    /// The post's own media; only when it has none, the media of the post
    /// it quotes, then reposts, then shows inline under a link card.
    static func resolveMedia(in post: [String: Any], linkCode: String) -> ResolvedPost? {
        let info = post["text_post_app_info"] as? [String: Any] ?? [:]
        let share = info["share_info"] as? [String: Any] ?? [:]
        let chain: [(node: [String: Any]?, source: MediaSource)] = [
            (post, .post),
            (share["quoted_post"] as? [String: Any], .quotedPost),
            (share["reposted_post"] as? [String: Any], .repostedPost),
            (info["linked_inline_media"] as? [String: Any], .linkedInlineMedia),
        ]
        for (node, source) in chain {
            guard let node else { continue }
            let media = mediaOf(node)
            guard !media.isEmpty else { continue }
            return ResolvedPost(
                author: author(of: node),
                text: (node["caption"] as? [String: Any])?["text"] as? String ?? "",
                code: node["code"] as? String ?? linkCode,
                source: source,
                media: media)
        }
        return nil
    }

    /// Display name when the account has one, else the username — the same
    /// choice X downloads make with the author's nick.
    private static func author(of node: [String: Any]) -> String {
        let user = node["user"] as? [String: Any]
        for key in ["full_name", "username"] {
            // Cleaned here, not only in the file name: a display name of
            // nothing but dots must fall through to the username.
            if let name = (user?[key] as? String).map(leadingNamePart), !name.isEmpty {
                return name
            }
        }
        return unknownAuthor
    }

    /// Stands in for an author the page doesn't name.
    static let unknownAuthor = "threads"

    /// Classifies a page that held no post object. Only addresses and the
    /// names of routes and components are tested: the visible text is
    /// localized and differs between requests for the same post, and the
    /// page size depends on compression. The order matters — the redirect
    /// targets are checked first because their pages are full of OTHER
    /// people's posts.
    static func classifyFailure(finalURL: URL?, html: String) -> Failure {
        if let finalURL {
            if finalURL.absoluteString.contains("error=invalid_post") { return .notFound }
            if finalURL.path.hasPrefix("/login") { return .loginRequired }
        }
        if html.contains("BarcelonaGeoBlockedErrorRoot") { return .restricted }
        if html.contains("Barcelona404ErrorRoot"), !html.contains("initialRouteInfo") { return .blockedShell }
        return .noPostData
    }

    // MARK: - File names

    /// "<author> - <text, 100 characters> [<code>]" — the shape X downloads
    /// have (see SiteRegistry.twitter's galleryDlArgs and FxTwitterService).
    /// The code keeps two posts by one author with the same or no text from
    /// colliding and being skipped as already downloaded.
    ///
    /// A file name holds 255 BYTES, and 100 characters of Chinese or Japanese
    /// text alone are 300: the text is cut further, as far as it takes, or
    /// the file could not be saved at all.
    static func fileStem(author: String, text: String, code: String) -> String {
        let name = leadingNamePart(author)
        let author = name.isEmpty ? unknownAuthor : name
        var cut = String(printable(text).prefix(100))
        var stem = DirectDownload.sanitize("\(author) - \(cut) [\(code)]")
        while stem.utf8.count > maxStemBytes, !cut.isEmpty {
            cut.removeLast()
            stem = DirectDownload.sanitize("\(author) - \(cut) [\(code)]")
        }
        return stem
    }

    /// Characters that direct the text around them instead of showing:
    /// they can make a name read as another one ("gpj.exe" for "exe.jpg").
    /// Listed one by one, because the wider "format" class also holds the
    /// joiner that emoji sequences are built with.
    private static let directionControls: Set<Unicode.Scalar> = [
        "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]

    /// Display names and captions are whatever the account typed. Line and
    /// paragraph breaks and tabs become spaces, like the newlines of an X
    /// caption; every other control character and the direction controls are
    /// dropped — in a file name they are invisible at best.
    static func printable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r", "\t", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}":
                scalars.append(" ")
            case _ where scalar.properties.generalCategory == .control || directionControls.contains(scalar):
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// The author as the first part of a name. A leading "." would make the
    /// saved file a hidden one: the row says Done and Finder shows nothing.
    private static func leadingNamePart(_ author: String) -> String {
        var name = Substring(printable(author).trimmingCharacters(in: .whitespacesAndNewlines))
        while name.first == "." { name = name.dropFirst().drop(while: \.isWhitespace) }
        return String(name)
    }

    /// Leaves room under the 255-byte limit for " #NN" and the extension.
    static let maxStemBytes = 240

    /// File name of the post's `index`th file (0-based) out of `count`. Only
    /// multi-file posts get the " #N" suffix: X downloads have the
    /// single-file " #1" stripped after download, and naming the file
    /// without it from the start keeps the re-download check a plain
    /// file-exists test.
    static func fileName(stem: String, index: Int, count: Int, fileExtension: String) -> String {
        "\(baseName(stem: stem, index: index, count: count)).\(fileExtension)"
    }

    /// The file name without its extension, which is only known once the
    /// server has answered.
    static func baseName(stem: String, index: Int, count: Int) -> String {
        count > 1 ? "\(stem) #\(index + 1)" : stem
    }

    /// Row title: the stem without its code — what GalleryDlService's
    /// displayTitle leaves of an X filename. Built from the parts rather
    /// than by stripping the file name, which would have to guess where the
    /// code starts.
    static func displayTitle(author: String, text: String) -> String {
        let title = DirectDownload.sanitize("\(printable(author)) - \(String(printable(text).prefix(100)))")
        return title.hasSuffix("-") ? String(title.dropLast()).trimmingCharacters(in: .whitespaces) : title
    }

    // MARK: - Private

    /// Capture groups of the first match, nil when the pattern doesn't match.
    private static func captures(of pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
