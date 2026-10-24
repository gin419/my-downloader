import Foundation

/// In-app resolver for YouTube community posts ("youtube.com/post/<id>").
/// Neither yt-dlp nor gallery-dl reads them — yt-dlp takes the link for a
/// channel tab and fails with "This channel does not have a <id> tab" — but
/// the post's page carries the whole post in its `ytInitialData` JSON, so one
/// page request, made logged out, resolves it. Pictures are downloaded in-app
/// at their original size; a post whose attachment is a video hands the
/// video's watch link to the app's usual yt-dlp download. Everything but
/// `run` is a pure function of the link or the fetched page.
enum YouTubePostService {

    // MARK: - Running a download

    /// Downloads a post's video through the app's usual yt-dlp run for the
    /// row and returns true when it saved. It sets the row's failure itself.
    typealias VideoDownload = @MainActor (_ watchLink: String) async -> Bool

    /// Resolves the post and downloads its pictures, or hands its video to
    /// `video`. Returns true only when everything is on disk. Like the
    /// Threads resolver it is the only downloader for its links, so every
    /// exit but a cancel leaves the row completed or failed with a message
    /// of its own.
    @MainActor
    static func run(
        item: DownloadItem, outputDirectory: URL, session: URLSession = DirectDownload.session,
        video: VideoDownload? = nil
    ) async -> Bool {
        item.status = .fetching
        item.eta = nil
        item.emptySuccessFailure = false

        guard let postID = postID(of: item.url), let pageURL = pageURL(for: postID) else {
            item.status = .failed(notAPostLinkMessage)
            return false
        }

        // A page without its data is asked for once more after a pause:
        // YouTube now and then answers with a page whose data is missing or
        // shaped differently, and the next answer is usually whole. Both
        // answers are kept in the row's diagnostic record.
        var page = await fetchPage(pageURL, postID: postID, session: session)
        if case .failed(.noPageData) = page {
            try? await Task.sleep(nanoseconds: retryPause)
            if Task.isCancelled { return false }
            DiagnosticTrail.current?.step("youtube-post: page again after no data")
            page = await fetchPage(pageURL, postID: postID, session: session)
        }

        let post: Post
        switch page {
        case .resolved(let resolved): post = resolved
        case .cancelled: return false
        case .unreachable(let message):
            item.status = .failed(message)
            return false
        case .failed(let failure):
            item.status = .failed(message(for: failure))
            return false
        }

        if let videoID = post.videoID {
            guard let video else {
                item.status = .failed(videoNotDownloadableMessage)
                return false
            }
            return await video(watchLink(for: videoID))
        }

        let stem = ThreadsService.fileStem(author: post.author, text: post.text, code: post.postID)
        // Two or more pictures get a folder named after the stem, as every
        // other post of several files does.
        let folder = RowFolder.folder(in: outputDirectory, name: stem, fileCount: post.pictures.count)
        RowFolder.use(folder, for: item)
        let directory = folder ?? outputDirectory
        var savedPaths: [String] = []
        var lastFailure: DirectDownload.FileFailure?
        for (index, address) in post.pictures.enumerated() {
            if Task.isCancelled { return false }
            let name = ThreadsService.baseName(stem: stem, index: index, count: post.pictures.count)
            if let existing = DirectDownload.existingFile(baseName: name, in: directory) {
                savedPaths.append(existing.path)
                continue
            }
            item.status = .downloading
            let outcome = await DirectDownload.download(
                address, to: directory, baseName: name, fallbackExtension: nil, accepting: MediaExtensions.image,
                item: item, fileIndex: index, fileCount: post.pictures.count, session: session)
            switch outcome {
            case .saved(let url): savedPaths.append(url.path)
            case .failed(let failure): lastFailure = failure
            case .cancelled: return false
            }
        }

        if Task.isCancelled { return false }
        guard let first = savedPaths.first else {
            item.speed = nil
            item.status = .failed(
                DirectDownload.zeroSavedFailureMessage(lastFailure: lastFailure) ?? nothingSavedMessage(lastFailure: lastFailure))
            return false
        }
        item.outputPath = first
        item.imageCount = savedPaths.count
        item.videoCount = nil
        item.recomputeMediaCategory()
        if item.title == nil { item.title = ThreadsService.displayTitle(author: post.author, text: post.text) }
        if let lastFailure {
            item.speed = nil
            item.status = .failed(
                DirectDownload.partialFailureMessage(saved: savedPaths.count, attempted: post.pictures.count, lastFailure: lastFailure))
            return false
        }
        item.markCompleted()
        return true
    }

    /// Pause before the page is asked for again (`run`). A seam for tests.
    static var retryPause: UInt64 = 2_000_000_000

    enum PageOutcome {
        case resolved(Post)
        case failed(Failure)
        /// The page could not be loaded; the row's message.
        case unreachable(String)
        case cancelled
    }

    /// One page request, read.
    @MainActor
    private static func fetchPage(_ pageURL: URL, postID: String, session: URLSession) async -> PageOutcome {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await DiagnosticTrail.data(
                for: DirectDownload.request(for: pageURL, headers: pageHeaders), session: session, label: "youtube-post-page")
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
            return .unreachable(pageUnreachableMessage(.transport(error)))
        }
        if Task.isCancelled { return .cancelled }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .unreachable(http.statusCode == 404 ? notFoundMessage : pageUnreachableMessage(.httpStatus(http.statusCode)))
        }
        switch resolve(html: String(decoding: data, as: UTF8.self), postID: postID) {
        case .success(let post): return .resolved(post)
        case .failure(let failure): return .failed(failure)
        }
    }

    /// What the page request sends. The consent cookie keeps a visitor in
    /// Europe from being sent to the cookie-consent page instead of the
    /// post; it is a fixed value, nothing of the user's.
    static let pageHeaders: [String: String] = [
        "User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Cookie": "SOCS=CAI; CONSENT=YES+",
    ]

    // MARK: - Links

    /// Hosts a post link may carry. Matching is by exact host, never by
    /// substring, so a link that merely mentions YouTube in its query stays
    /// with its own site.
    static let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com"]

    /// The post id a link names, or nil when it is not a post link:
    /// "/post/<id>", and a channel's community tab opened on one post
    /// ("/channel/<id>/community?lb=<id>", "/@handle/community?lb=<id>").
    static func postID(of link: String) -> String? {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(), hosts.contains(host)
        else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "post" {
            return isPostID(parts[1]) ? parts[1] : nil
        }
        let isCommunityTab =
            (parts.count == 2 && parts[0].hasPrefix("@") && parts[1] == "community")
            || (parts.count == 3 && ["channel", "c", "user"].contains(parts[0]) && parts[2] == "community")
        if isCommunityTab, let lb = components.queryItems?.first(where: { $0.name == "lb" })?.value, isPostID(lb) {
            return lb
        }
        return nil
    }

    /// True for a YouTube community post link (see `postID`).
    static func isPostLink(_ link: String) -> Bool { postID(of: link) != nil }

    /// A post's one canonical link, the row's identity: whatever tracking
    /// query ("?surface=…&data=…") or community-tab spelling it was pasted
    /// in, the same post is the same download.
    static func canonicalLink(for postID: String) -> String { "https://www.youtube.com/post/\(postID)" }

    static func pageURL(for postID: String) -> URL? { URL(string: canonicalLink(for: postID)) }

    static func watchLink(for videoID: String) -> String { "https://www.youtube.com/watch?v=\(videoID)" }

    /// Post ids are URL-safe base64: letters, digits, "-" and "_".
    private static func isPostID(_ text: String) -> Bool {
        (8...64).contains(text.utf8.count)
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    // MARK: - Reading the page

    struct Post: Equatable {
        let postID: String
        let author: String
        let text: String
        /// Original-size picture addresses, in the post's order.
        let pictures: [URL]
        /// The video the post shares, when its attachment is one.
        let videoID: String?
    }

    enum Failure: Error, Equatable {
        /// The page carries no `ytInitialData`: a consent or error page, or
        /// YouTube changed its site.
        case noPageData
        /// The page has data but no post: deleted, private, or a bad id.
        case notFound
        /// Text, a poll or a quiz: nothing to download.
        case noMedia
    }

    static func resolve(html: String, postID: String) -> Result<Post, Failure> {
        guard let data = initialData(in: html) else { return .failure(.noPageData) }
        return resolve(initialData: data, postID: postID)
    }

    static func resolve(initialData: [String: Any], postID: String) -> Result<Post, Failure> {
        let renderers = postRenderers(in: initialData)
        // A shared post wraps the original one: its own renderer has no
        // attachment, so the post the link names is preferred, and any
        // other renderer on the page (the original) stands in for it.
        let ordered = renderers.filter { ($0["postId"] as? String) == postID } + renderers.filter { ($0["postId"] as? String) != postID }
        guard let named = ordered.first else { return .failure(.notFound) }
        for renderer in ordered {
            let attachment = renderer["backstageAttachment"] as? [String: Any] ?? [:]
            let pictures = pictureAddresses(in: attachment)
            let videoID = videoID(in: attachment)
            guard !pictures.isEmpty || videoID != nil else { continue }
            return .success(
                Post(
                    postID: postID, author: author(of: renderer) ?? author(of: named) ?? unknownAuthor,
                    text: text(of: named), pictures: pictures, videoID: pictures.isEmpty ? videoID : nil))
        }
        return .failure(.noMedia)
    }

    /// The `ytInitialData` object of a page, or nil. YouTube writes it as a
    /// script literal (`var ytInitialData = {…};`, or assigned on `window`),
    /// and on some pages as a string of escaped JSON
    /// (`var ytInitialData = '\x7b…';`, or wrapped in `JSON.parse('…')`).
    static func initialData(in html: String) -> [String: Any]? {
        let markers = [
            "var ytInitialData = ", "window[\"ytInitialData\"] = ", "window['ytInitialData'] = ", "ytInitialData = ",
            "var ytInitialData=", "window[\"ytInitialData\"]=", "window['ytInitialData']=", "ytInitialData=",
        ]
        for marker in markers {
            var searchStart = html.startIndex
            while let range = html.range(of: marker, range: searchStart..<html.endIndex) {
                searchStart = range.upperBound
                if let object = initialDataValue(in: html, from: range.upperBound) { return object }
            }
        }
        return nil
    }

    /// The object written at `start`: a literal, a quoted string of JSON, or
    /// `JSON.parse(<quoted string>)`.
    private static func initialDataValue(in html: String, from start: String.Index) -> [String: Any]? {
        var index = start
        while index < html.endIndex, html[index] == " " { index = html.index(after: index) }
        let jsonText: String
        if html[index...].hasPrefix("{") {
            guard let literal = balancedObject(in: html, from: index) else { return nil }
            jsonText = String(literal)
        } else {
            if html[index...].hasPrefix("JSON.parse(") {
                index = html.index(index, offsetBy: "JSON.parse(".count)
            }
            guard let decoded = quotedString(in: html, from: index) else { return nil }
            jsonText = decoded
        }
        return try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any]
    }

    /// The value of the JavaScript string literal (single or double quoted)
    /// starting at `start`, its escapes (`\xHH`, `\uHHHH`, `\n`, `\'`, …)
    /// decoded; nil when none starts there or it never closes.
    static func quotedString(in text: String, from start: String.Index) -> String? {
        let scalars = text.unicodeScalars
        var index = start
        guard index < scalars.endIndex, scalars[index] == "'" || scalars[index] == "\"" else { return nil }
        let quote = scalars[index]
        index = scalars.index(after: index)
        var out = String.UnicodeScalarView()
        // Pending UTF-16 high surrogate from a \uD8xx escape.
        var pendingHigh: UInt32?
        func hex(_ count: Int) -> UInt32? {
            var value: UInt32 = 0
            for _ in 0..<count {
                guard index < scalars.endIndex, let digit = UInt32(String(scalars[index]), radix: 16) else { return nil }
                value = value * 16 + digit
                index = scalars.index(after: index)
            }
            return value
        }
        func append(_ value: UInt32) {
            if let high = pendingHigh {
                pendingHigh = nil
                if (0xDC00...0xDFFF).contains(value) {
                    let combined = 0x10000 + ((high - 0xD800) << 10) + (value - 0xDC00)
                    if let scalar = Unicode.Scalar(combined) { out.append(scalar) }
                    return
                }
            }
            if (0xD800...0xDBFF).contains(value) {
                pendingHigh = value
                return
            }
            if let scalar = Unicode.Scalar(value) { out.append(scalar) }
        }
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == quote { return String(out) }
            index = scalars.index(after: index)
            guard scalar == "\\" else {
                out.append(scalar)
                continue
            }
            guard index < scalars.endIndex else { return nil }
            let escape = scalars[index]
            index = scalars.index(after: index)
            switch escape {
            case "x":
                guard let value = hex(2) else { return nil }
                append(value)
            case "u":
                guard let value = hex(4) else { return nil }
                append(value)
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "v": out.append("\u{0B}")
            case "0": out.append("\u{00}")
            default: out.append(escape)
            }
        }
        return nil
    }

    /// The JSON object starting at `start` (after optional whitespace), cut
    /// at its matching closing brace — strings and escapes respected — so
    /// whatever script follows it on the same line is left out.
    static func balancedObject(in text: String, from start: String.Index) -> Substring? {
        let utf8 = text.utf8
        var index = start
        while index < utf8.endIndex, utf8[index] == UInt8(ascii: " ") { index = utf8.index(after: index) }
        guard index < utf8.endIndex, utf8[index] == UInt8(ascii: "{") else { return nil }
        let begin = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < utf8.endIndex {
            let byte = utf8[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return text[begin...index] }
            }
            index = utf8.index(after: index)
        }
        return nil
    }

    /// Every `backstagePostRenderer` in the data, in document order.
    static func postRenderers(in value: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if let renderer = object["backstagePostRenderer"] as? [String: Any] { found.append(renderer) }
                for (key, child) in object where key != "backstagePostRenderer" { walk(child) }
                if let renderer = object["backstagePostRenderer"] as? [String: Any] {
                    // An original post nested inside one (never seen, but
                    // cheap to allow) still counts.
                    for (_, child) in renderer { walk(child) }
                }
            } else if let list = value as? [Any] {
                for child in list { walk(child) }
            }
        }
        walk(value)
        return found
    }

    /// The original-size address of every picture of the attachment.
    static func pictureAddresses(in attachment: [String: Any]) -> [URL] {
        var images: [[String: Any]] = []
        if let single = attachment["backstageImageRenderer"] as? [String: Any] { images.append(single) }
        if let multi = attachment["postMultiImageRenderer"] as? [String: Any], let list = multi["images"] as? [Any] {
            for entry in list {
                if let image = (entry as? [String: Any])?["backstageImageRenderer"] as? [String: Any] { images.append(image) }
            }
        }
        return images.compactMap { image in
            let thumbnails = (image["image"] as? [String: Any])?["thumbnails"] as? [Any] ?? []
            let addresses = thumbnails.compactMap { ($0 as? [String: Any])?["url"] as? String }
            return addresses.last.flatMap(fullSizeAddress)
        }
    }

    /// The video id of a shared-video attachment, or nil.
    static func videoID(in attachment: [String: Any]) -> String? {
        guard let video = attachment["videoRenderer"] as? [String: Any], let id = video["videoId"] as? String,
            !id.isEmpty, id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { return nil }
        return id
    }

    /// The thumbnail address rewritten to ask for the original: the image
    /// path is everything before its first "=" (the size and crop options
    /// follow it, and may hold "=" themselves), and "=s0" asks for the
    /// picture uncropped at its own size. Only Google's image hosts.
    static func fullSizeAddress(_ raw: String) -> URL? {
        let absolute = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let components = URLComponents(string: absolute), components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            imageHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }
        let base = absolute.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? absolute
        guard base.count > "https://".count + host.count + 1 else { return nil }
        return URL(string: base + "=s0")
    }

    private static let imageHostSuffixes = ["ggpht.com", "googleusercontent.com"]

    static let unknownAuthor = "youtube"

    private static func author(of renderer: [String: Any]) -> String? {
        let runs = (renderer["authorText"] as? [String: Any])?["runs"] as? [Any] ?? []
        let name = runs.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
        return name.isEmpty ? nil : name
    }

    private static func text(of renderer: [String: Any]) -> String {
        let runs = (renderer["contentText"] as? [String: Any])?["runs"] as? [Any] ?? []
        return runs.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
    }

    // MARK: - Failure messages

    static let notAPostLinkMessage =
        "This YouTube link isn't a single community post — open the post and paste its own link instead."
    static let notFoundMessage =
        "YouTube post not found — it may be deleted or members-only, or the link may be incomplete; check the link, then Retry."
    static let noPageDataMessage =
        "YouTube sent the post's page without its data — wait a moment, then Retry. If it persists, YouTube may have changed its site."
    static let noMediaMessage =
        "This YouTube post has no pictures or video — text and polls can't be downloaded."
    static let videoNotDownloadableMessage =
        "This YouTube post shares a video, and downloading it needs yt-dlp, which is not installed. Install yt-dlp, then Retry."

    static func pageUnreachableMessage(_ failure: DirectDownload.FileFailure) -> String {
        "Couldn't load the post from YouTube — \(DirectDownload.shortReason(for: failure)). Check the connection, then Retry."
    }

    static func nothingSavedMessage(lastFailure: DirectDownload.FileFailure?) -> String {
        guard let lastFailure else { return "None of this post's pictures could be saved — Retry." }
        return "None of this post's pictures could be saved — \(DirectDownload.shortReason(for: lastFailure)). Retry fetches them again."
    }

    static func message(for failure: Failure) -> String {
        switch failure {
        case .noPageData: return noPageDataMessage
        case .notFound: return notFoundMessage
        case .noMedia: return noMediaMessage
        }
    }
}
