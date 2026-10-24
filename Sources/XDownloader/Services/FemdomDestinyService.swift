import Foundation

/// In-app resolver for femdomdestiny.com posts. The site is a free
/// WordPress blog that yt-dlp's generic extractor turns down ("Unsupported
/// URL") and gallery-dl has no extractor for. Everything a post shows is
/// served to every logged-out visitor, so one page request finds it all,
/// and no cookie is sent anywhere.
///
/// What a post holds, all of it inside the post's own `<article>` (the
/// sidebar, header and footer are left out):
/// - videos as plain `<video src>` / `<source src>`, or inside a Flowplayer
///   box whose `data-item` attribute is JSON naming the file;
/// - NextGEN galleries: a link to each full-size picture under
///   "/wp-content/gallery/", wrapping a small thumbnail;
/// - pictures placed in the text, at their largest size.
/// Pictures that link to another site are advertising banners and are left
/// out, as are pictures that link to another post, video posters and the
/// site's logo.
///
/// The markup is minified: attribute values are often unquoted.
enum FemdomDestinyService {

    // MARK: - Running a download

    /// Resolves post `slug` and downloads every video and picture of it into
    /// `outputDirectory` (two or more files into a folder of their own).
    /// Returns true only when every file is on disk. Every exit but a cancel
    /// leaves the row completed or failed with a message of its own.
    @MainActor
    static func run(
        item: DownloadItem, outputDirectory: URL, session: URLSession = DirectDownload.session
    ) async -> Bool {
        item.status = .fetching
        item.eta = nil
        item.emptySuccessFailure = false

        guard let slug = postSlug(of: item.url), let pageURL = pageURL(for: slug) else {
            item.status = .failed(notAPostLinkMessage)
            return false
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await DiagnosticTrail.data(
                for: DirectDownload.request(for: pageURL, headers: pageHeaders), session: session,
                label: "femdomdestiny-page")
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
            item.status = .failed(pageUnreachableMessage(.transport(error)))
            return false
        }
        if Task.isCancelled { return false }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            item.status = .failed(
                http.statusCode == 404 ? notFoundMessage : pageUnreachableMessage(.httpStatus(http.statusCode)))
            return false
        }

        let post: Post
        switch resolve(html: String(decoding: data, as: UTF8.self), pageURL: response.url ?? pageURL) {
        case .success(let found): post = found
        case .failure(let failure):
            item.status = .failed(message(for: failure))
            return false
        }

        let stem = ThreadsService.fileStem(author: siteName, text: post.title, code: slug)
        let count = post.media.count
        let folder = RowFolder.folder(in: outputDirectory, name: RowFolder.appNamed(stem), fileCount: count)
        RowFolder.use(folder, for: item)
        let directory = folder ?? outputDirectory
        let names = baseNames(for: post.media, stem: stem)
        let referer = ["User-Agent": userAgent, "Referer": pageURL.absoluteString]

        var saved: [(path: String, kind: Media.Kind)] = []
        var lastFailure: DirectDownload.FileFailure?
        for (index, media) in post.media.enumerated() {
            if Task.isCancelled { return false }
            let name = names[index]
            if let existing = DirectDownload.existingFile(baseName: name, in: directory) {
                saved.append((existing.path, media.kind))
                continue
            }
            item.status = .downloading
            var outcome: DirectDownload.Outcome = .failed(.httpStatus(0))
            for address in media.addresses {
                outcome = await DirectDownload.download(
                    address, headers: referer, to: directory, baseName: name, fallbackExtension: nil,
                    accepting: media.kind == .video ? MediaExtensions.video : MediaExtensions.image,
                    item: item, fileIndex: index, fileCount: count, session: session)
                // Only a full-size guess the site doesn't have falls back
                // to the size the page itself showed.
                guard case .failed(.httpStatus(404)) = outcome else { break }
            }
            switch outcome {
            case .saved(let url): saved.append((url.path, media.kind))
            case .failed(let failure): lastFailure = failure
            case .cancelled: return false
            }
        }

        if Task.isCancelled { return false }
        guard let first = saved.first else {
            item.speed = nil
            item.status = .failed(
                DirectDownload.zeroSavedFailureMessage(lastFailure: lastFailure) ?? nothingSavedMessage(lastFailure: lastFailure))
            return false
        }
        item.outputPath = first.path
        let pictures = saved.filter { $0.kind == .picture }.count
        let videos = saved.count - pictures
        item.imageCount = pictures > 0 ? pictures : nil
        item.videoCount = videos > 0 ? videos : nil
        item.recomputeMediaCategory()
        if item.title == nil { item.title = ThreadsService.displayTitle(author: siteName, text: post.title) }
        if let lastFailure {
            item.speed = nil
            item.status = .failed(
                DirectDownload.partialFailureMessage(saved: saved.count, attempted: count, lastFailure: lastFailure))
            return false
        }
        item.markCompleted()
        return true
    }

    /// File names without extension. A post of one file saves it loose in
    /// the download folder, under the post's own name so it can't collide
    /// with another post's file. A post of several saves into its own
    /// folder, each file under the name the site gave it ("…-1.jpg",
    /// "fishnets-joi.mp4"), numbered only where two would clash.
    static func baseNames(for media: [Media], stem: String) -> [String] {
        guard media.count > 1 else { return media.isEmpty ? [] : [stem] }
        var used: [String: Int] = [:]
        return media.enumerated().map { index, item in
            var base = DirectDownload.sanitize(item.addresses[0].deletingPathExtension().lastPathComponent)
            base = String(base.trimmingCharacters(in: CharacterSet(charactersIn: ".")).prefix(120))
            if base.isEmpty { base = ThreadsService.baseName(stem: stem, index: index, count: media.count) }
            let seen = used[base.lowercased(), default: 0]
            used[base.lowercased()] = seen + 1
            return seen == 0 ? base : "\(base) (\(seen + 1))"
        }
    }

    // MARK: - Requests

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"

    static let pageHeaders: [String: String] = [
        "User-Agent": userAgent,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    ]

    // MARK: - Links

    static let siteName = "Femdom Destiny"
    static let canonicalHost = "femdomdestiny.com"
    static let hosts: Set<String> = ["femdomdestiny.com", "www.femdomdestiny.com"]

    /// First path parts that name a listing or a file, never one post.
    static let reservedFirstParts: Set<String> = [
        "category", "tag", "page", "author", "search", "feed", "comments", "wp-content", "wp-includes",
        "wp-admin", "wp-json", "xmlrpc.php", "wp-login.php",
    ]

    /// True for any link on the site except its files: a post, the home
    /// page, a category. The files ("/wp-content/…", a video pasted on its
    /// own) stay with the generic downloader, which has always fetched them.
    static func isSiteLink(_ link: String) -> Bool {
        guard let components = siteComponents(link) else { return false }
        let first = components.path.split(separator: "/").first.map { String($0).lowercased() }
        return !["wp-content", "wp-includes"].contains(first ?? "")
    }

    /// The post a link names ("/<slug>/"), or nil for the home page, a
    /// listing or any other link.
    static func postSlug(of link: String) -> String? {
        guard let components = siteComponents(link) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 1, let slug = parts.first, !reservedFirstParts.contains(slug.lowercased()),
            (1...200).contains(slug.utf8.count),
            slug.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "%" })
        else { return nil }
        return slug
    }

    static func canonicalLink(for slug: String) -> String { "https://\(canonicalHost)/\(slug)/" }

    static func pageURL(for slug: String) -> URL? { URL(string: canonicalLink(for: slug)) }

    private static func siteComponents(_ link: String) -> URLComponents? {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(), hosts.contains(host)
        else { return nil }
        return components
    }

    // MARK: - Reading the page

    struct Media: Equatable {
        enum Kind: Equatable { case picture, video }
        let kind: Kind
        /// Tried in order: a full-size guess first, then what the page
        /// itself showed, when the two differ.
        let addresses: [URL]
    }

    struct Post: Equatable {
        let title: String
        let media: [Media]
    }

    enum Failure: Error, Equatable {
        /// No `<article>`: an error page, or the site changed its layout.
        case noArticle
        /// The post holds nothing to download (text, a podcast player).
        case noMedia
    }

    static func resolve(html: String, pageURL: URL) -> Result<Post, Failure> {
        guard let article = articleHTML(in: html) else { return .failure(.noArticle) }
        let media = mediaInArticle(article, pageURL: pageURL)
        guard !media.isEmpty else { return .failure(.noMedia) }
        return .success(Post(title: title(in: html) ?? "", media: media))
    }

    /// The post's `<article>` element, scripts and styles removed. The
    /// first one: a post page has one, and related posts are not articles.
    static func articleHTML(in html: String) -> String? {
        guard let start = html.range(of: "<article", options: .caseInsensitive),
            let end = html.range(of: "</article>", options: .caseInsensitive, range: start.upperBound..<html.endIndex)
        else { return nil }
        var article = String(html[start.lowerBound..<end.upperBound])
        for tag in ["script", "style", "noscript"] {
            article = article.replacingOccurrences(
                of: "<\(tag)\\b.*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        return article
    }

    /// The post's title: its heading, else the page's og:title less the
    /// site's name.
    static func title(in html: String) -> String? {
        if let heading = firstCapture(#"<h1\b[^>]*>(.*?)</h1>"#, in: html) {
            let text = decodeEntities(heading.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        if let og = firstCapture(#"<meta\s+property=["']?og:title["']?\s+content=["']([^"']*)["']"#, in: html) {
            var text = decodeEntities(og).trimmingCharacters(in: .whitespacesAndNewlines)
            for separator in [" - ", " – ", " | "] {
                if let range = text.range(of: separator + siteName, options: [.caseInsensitive, .backwards]) {
                    text = String(text[..<range.lowerBound])
                }
            }
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Every video and picture of the article, in page order, each once.
    static func mediaInArticle(_ article: String, pageURL: URL) -> [Media] {
        var result: [Media] = []
        var seen = Set<String>()
        func add(_ kind: Media.Kind, _ addresses: [URL]) {
            let unique = addresses.reduce(into: [URL]()) { list, url in if !list.contains(url) { list.append(url) } }
            guard let first = unique.first else { return }
            let key = identity(of: first)
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(Media(kind: kind, addresses: unique))
        }

        // The link the scan is inside, and whether it already gave its
        // picture (a gallery link), so the thumbnail inside is not taken.
        var openLink: URL?
        var openLinkGavePicture = false
        var insideVideo = false

        for tag in tags(in: article) {
            switch (tag.name, tag.isClosing) {
            case ("a", false):
                openLink = tag.attributes["href"].flatMap { resolve($0, against: pageURL) }
                openLinkGavePicture = false
                if let link = openLink, isGalleryPicture(link) {
                    add(.picture, [siteFile(link)])
                    openLinkGavePicture = true
                }
            case ("a", true):
                openLink = nil
                openLinkGavePicture = false
            case ("video", false):
                insideVideo = true
                if let src = tag.attributes["src"].flatMap({ resolve($0, against: pageURL) }), isVideoFile(src) {
                    add(.video, [siteFile(src)])
                }
            case ("video", true):
                insideVideo = false
            case ("source", false):
                let type = tag.attributes["type"]?.lowercased() ?? ""
                if let src = tag.attributes["src"].flatMap({ resolve($0, against: pageURL) }),
                    isVideoFile(src) || (insideVideo && type.hasPrefix("video/"))
                {
                    add(.video, [siteFile(src)])
                }
            case ("img", false):
                guard !openLinkGavePicture, let picture = pictureAddresses(of: tag, link: openLink, pageURL: pageURL)
                else { break }
                add(.picture, picture)
            default:
                break
            }
            // A Flowplayer box names its file in JSON, on whatever tag holds it.
            if !tag.isClosing, let item = tag.attributes["data-item"] {
                for src in flowplayerSources(item) {
                    if let url = resolve(src, against: pageURL), isVideoFile(url) { add(.video, [siteFile(url)]) }
                }
            }
        }
        return result
    }

    /// The addresses to try for a picture in the text, nil when it is not
    /// one of the post's own: a banner linking to another site, a picture
    /// linking to another post, a video poster, the logo or a thumbnail.
    static func pictureAddresses(of tag: Tag, link: URL?, pageURL: URL) -> [URL]? {
        let classes = (tag.attributes["class"] ?? "").lowercased()
        for skipped in ["fp-splash", "ngg-gallery-thumbnail", "emoji", "avatar", "logo", "wp-smiley"]
        where classes.contains(skipped) {
            return nil
        }
        let raw = [tag.attributes["data-lazy-src"], tag.attributes["data-src"], tag.attributes["src"]]
            .compactMap { $0 }.first { !$0.hasPrefix("data:") && !$0.isEmpty }
        guard let raw, let shown = resolve(raw, against: pageURL), isUploadedPicture(shown) else { return nil }
        if shown.lastPathComponent.lowercased().contains("logo") { return nil }

        if let link {
            // Linked to its own full-size file ("link to media file"): that file.
            if isUploadedPicture(link) { return [siteFile(link), siteFile(shown)] }
            // Linked anywhere else — another site (an advertising banner) or
            // another page of this one (a related post) — it is not the post's.
            return nil
        }

        let largest = largestSrcsetEntry(tag.attributes["srcset"]).flatMap { resolve($0, against: pageURL) }
        let base = largest.map(siteFile) ?? siteFile(shown)
        if let original = withoutSizeSuffix(base) { return [original, base] }
        return [base]
    }

    // MARK: - Address rules

    /// A link to a full-size NextGEN gallery picture on the site.
    static func isGalleryPicture(_ url: URL) -> Bool {
        guard isOnSite(url) else { return false }
        let path = url.path.lowercased()
        return path.hasPrefix("/wp-content/gallery/") && !path.contains("/thumbs/")
            && MediaExtensions.image.contains(url.pathExtension.lowercased())
    }

    /// A picture uploaded to the site (WordPress media), any size.
    static func isUploadedPicture(_ url: URL) -> Bool {
        isOnSite(url) && url.path.lowercased().hasPrefix("/wp-content/uploads/")
            && MediaExtensions.image.contains(url.pathExtension.lowercased())
    }

    /// A video file on the site.
    static func isVideoFile(_ url: URL) -> Bool {
        isOnSite(url) && MediaExtensions.video.contains(url.pathExtension.lowercased())
    }

    static func isOnSite(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return false }
        return hosts.contains(host) && (scheme == "https" || scheme == "http")
    }

    /// The one address of a site file: https on the bare host (the "www"
    /// and plain-http spellings the old posts use only redirect there), and
    /// no query — "?x86621" is a cache-buster, the file is the same without it.
    static func siteFile(_ url: URL) -> URL {
        guard isOnSite(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        components.host = canonicalHost
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    /// "photo-300x200.jpg" → "photo.jpg": WordPress's full-size original
    /// beside a resized copy. Nil when the name has no size suffix.
    static func withoutSizeSuffix(_ url: URL) -> URL? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: #"-\d{2,5}x\d{2,5}$"#, options: .regularExpression) else { return nil }
        let original = String(name[..<range.lowerBound])
        guard !original.isEmpty else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(original).appendingPathExtension(url.pathExtension)
    }

    /// The widest entry of a srcset ("a.jpg 300w, b.jpg 1024w" → "b.jpg").
    static func largestSrcsetEntry(_ srcset: String?) -> String? {
        guard let srcset else { return nil }
        var best: (url: String, width: Int)?
        for entry in srcset.split(separator: ",") {
            let parts = entry.split(whereSeparator: \.isWhitespace)
            guard let url = parts.first else { continue }
            let width =
                parts.dropFirst().first.flatMap { descriptor -> Int? in
                    guard descriptor.hasSuffix("w") else { return nil }
                    return Int(descriptor.dropLast())
                } ?? 0
            if best == nil || width > best!.width { best = (String(url), width) }
        }
        return best?.url
    }

    /// The `src` of every source in a Flowplayer `data-item` JSON.
    static func flowplayerSources(_ json: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let sources = object["sources"] as? [[String: Any]]
        else { return [] }
        return sources.compactMap { $0["src"] as? String }
    }

    private static func resolve(_ raw: String, against base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.lowercased().hasPrefix("javascript:") else { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    /// Two addresses of one picture count once: the same file at another
    /// size, or with another cache-buster.
    private static func identity(of url: URL) -> String {
        let file = siteFile(url)
        return (withoutSizeSuffix(file) ?? file).absoluteString.lowercased()
    }

    // MARK: - Tags

    struct Tag: Equatable {
        let name: String
        let isClosing: Bool
        let attributes: [String: String]
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>"#)
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([a-zA-Z_:@][-a-zA-Z0-9_:.@]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'<>`]+)))?"#)

    /// Every start and end tag, in order, attribute values unescaped.
    static func tags(in html: String) -> [Tag] {
        let ns = html as NSString
        return tagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
            let closing = ns.substring(with: match.range(at: 1)) == "/"
            let name = ns.substring(with: match.range(at: 2)).lowercased()
            var body = ns.substring(with: match.range(at: 3))
            // "<img src=a.jpg/>": the "/" closes the tag, it is not the value's.
            if body.hasSuffix("/") { body.removeLast() }
            return Tag(name: name, isClosing: closing, attributes: closing ? [:] : attributes(in: body))
        }
    }

    static func attributes(in body: String) -> [String: String] {
        let ns = body as NSString
        var result: [String: String] = [:]
        for match in attributePattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            guard result[name] == nil else { continue }
            let value =
                (2...4).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
                .map { ns.substring(with: $0) } ?? ""
            result[name] = decodeEntities(value)
        }
        return result
    }

    /// The character references WordPress writes into attributes and titles.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&quot;": "\"", "&#039;": "'", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, character) in named { result = result.replacingOccurrences(of: entity, with: character) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            let ns = result as NSString
            var out = ""
            var last = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let code = ns.substring(with: match.range(at: 1))
                let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                out += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: match.range)
                last = match.range.location + match.range.length
            }
            out += ns.substring(from: last)
            result = out
        }
        // Last, so "&amp;quot;" stays the text "&quot;".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    // MARK: - Failure messages

    static let notAPostLinkMessage =
        "This femdomdestiny.com link isn't a single post — open the post and paste its own link instead."
    static let notFoundMessage =
        "Post not found on femdomdestiny.com — it may have been removed, or the link may be incomplete; check the link, then Retry."
    static let noMediaMessage = "This page has no pictures or videos to download."
    static let noArticleMessage =
        "femdomdestiny.com sent a page without a post — wait a moment, then Retry. If it persists, the site may have changed its layout."

    static func pageUnreachableMessage(_ failure: DirectDownload.FileFailure) -> String {
        "Couldn't load the post from femdomdestiny.com — \(DirectDownload.shortReason(for: failure)). Check the connection, then Retry."
    }

    static func nothingSavedMessage(lastFailure: DirectDownload.FileFailure?) -> String {
        guard let lastFailure else { return "None of this post's files could be saved — Retry." }
        return "None of this post's files could be saved — \(DirectDownload.shortReason(for: lastFailure)). Retry fetches them again."
    }

    static func message(for failure: Failure) -> String {
        switch failure {
        case .noArticle: return noArticleMessage
        case .noMedia: return noMediaMessage
        }
    }
}
