import Foundation

/// In-app resolver for Threads posts. Neither yt-dlp nor gallery-dl has a
/// Threads extractor, but a public post's page carries the whole post —
/// every carousel child, original-resolution images and a progressive MP4 —
/// as JSON inside a `<script type="application/json">` tag, so one page
/// fetch resolves it. Everything here is a pure function of the fetched
/// page: no cookies are read or sent, and nothing resolved is ever stored,
/// because the media addresses are signed and expire within days.
enum ThreadsService {

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
    static let loginRequiredMessage =
        "This post needs sign-in at threads.com — XDownloader can't download signed-in Threads posts yet, so Retry won't help for now."
    static let restrictedMessage =
        "Threads limits who can see this post — it needs sign-in at threads.com, which XDownloader can't use yet, so Retry won't help for now."
    static let blockedShellMessage =
        "Threads returned an empty page — the link may be malformed, or Threads changed its site; check the link, then Retry."
    static let noPostDataMessage =
        "Threads sent the page without the post's data — wait a moment, then Retry. If it persists, Threads may have changed its site."
    static let noMediaMessage =
        "No photo or video in this Threads post — text, link cards and GIFs can't be downloaded."

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

    private static func mediaURL(_ value: Any?) -> URL? {
        guard let raw = value as? String, !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else { return nil }
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
            if let name = (user?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }
        return "threads"
    }

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
    static func fileStem(author: String, text: String, code: String) -> String {
        DirectDownload.sanitize("\(author) - \(String(text.prefix(100))) [\(code)]")
    }

    /// File name of the post's `index`th file (0-based) out of `count`. Only
    /// multi-file posts get the " #N" suffix: X downloads have the
    /// single-file " #1" stripped after download, and naming the file
    /// without it from the start keeps the re-download check a plain
    /// file-exists test.
    static func fileName(stem: String, index: Int, count: Int, fileExtension: String) -> String {
        count > 1 ? "\(stem) #\(index + 1).\(fileExtension)" : "\(stem).\(fileExtension)"
    }

    /// Row title: the stem without its code — what GalleryDlService's
    /// displayTitle leaves of an X filename. Built from the parts rather
    /// than by stripping the file name, which would have to guess where the
    /// code starts.
    static func displayTitle(author: String, text: String) -> String {
        let title = DirectDownload.sanitize("\(author) - \(String(text.prefix(100)))")
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
