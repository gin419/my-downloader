import Foundation

/// Resolves one public Xiaohongshu note from the page's embedded state and
/// saves its video or every photo, plus the note caption as a text sidecar.
/// Signed media URLs are used exactly as supplied by the page and are never
/// persisted in the queue.
enum XiaohongshuService {

    static let signInRequiredMessage =
        "Xiaohongshu redirected this video to sign-in. Sign in to Xiaohongshu in the browser selected in Settings → Cookies, then Retry."

    static let hosts: Set<String> = [
        "xiaohongshu.com", "www.xiaohongshu.com", "rednote.com", "www.rednote.com",
        "xhslink.com", "www.xhslink.com", "xhslink.cn", "www.xhslink.cn",
    ]

    struct Note: Equatable {
        struct Media: Equatable {
            enum Kind: Equatable { case image, video }
            let url: URL
            let kind: Kind
        }
        let id: String
        let title: String
        let text: String
        let author: String
        let media: [Media]
    }

    static func isSiteURL(_ raw: String) -> Bool {
        guard let host = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func noteID(in raw: String) -> String? {
        guard isSiteURL(raw), let components = URLComponents(string: raw) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "explore") ?? parts.firstIndex(of: "item"),
            parts.indices.contains(index + 1)
        else { return nil }
        let id = parts[index + 1]
        guard id.range(of: #"^[A-Za-z0-9_-]{8,}$"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    private static func isShortLink(_ raw: String) -> Bool {
        guard let host = URLComponents(string: raw)?.host?.lowercased() else { return false }
        return ["xhslink.com", "www.xhslink.com", "xhslink.cn", "www.xhslink.cn"].contains(host)
    }

    @MainActor
    static func run(
        item: DownloadItem,
        outputDirectory: URL,
        session: URLSession = DirectDownload.session,
        signedInVideo: (@MainActor (String) async -> Bool)? = nil
    ) async -> Bool {
        item.status = .fetching
        item.emptySuccessFailure = false
        guard let pageURL = URL(string: item.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            item.status = .failed("The Xiaohongshu link is invalid.")
            return false
        }
        let originalID = noteID(in: item.url)
        guard originalID != nil || isShortLink(item.url) else {
            item.status = .failed("Paste a link to one Xiaohongshu note, not a profile, feed, or search page.")
            return false
        }
        var request = DirectDownload.request(for: pageURL, headers: [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml",
        ])
        request.httpShouldHandleCookies = false

        let note: Note
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return false }
            guard let http = response as? HTTPURLResponse else {
                item.status = .failed("Couldn't load the Xiaohongshu note. Check that the share link is current and publicly accessible, then Retry.")
                return false
            }
            if isLoginPage(response.url) {
                guard let signedInVideo else {
                    item.status = .failed(signInRequiredMessage)
                    return false
                }
                return await signedInVideo(item.url)
            }
            guard (200..<300).contains(http.statusCode) else {
                item.status = .failed("Couldn't load the Xiaohongshu note. Check that the share link is current and publicly accessible, then Retry.")
                return false
            }
            let html = String(decoding: data, as: UTF8.self)
            guard let id = response.url.flatMap({ noteID(in: $0.absoluteString) }) ?? originalID,
                let resolved = resolve(html: html, id: id) ?? resolveOpenGraph(html: html, id: id)
            else {
                item.status = .failed("Couldn't read this Xiaohongshu note. It may require sign-in or a fresh full share link; only publicly accessible notes are supported.")
                return false
            }
            note = resolved
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return false }
            item.status = .failed("Couldn't load the Xiaohongshu note — \(DirectDownload.shortReason(for: .transport(error))). Check the connection, then Retry.")
            return false
        }

        var stemTitle = String((note.title.isEmpty ? note.id : note.title).prefix(100))
        var stem = DirectDownload.sanitize(stemTitle) + " [" + note.id + "]"
        while stem.utf8.count > 220, !stemTitle.isEmpty {
            stemTitle.removeLast()
            stem = DirectDownload.sanitize(stemTitle) + " [" + note.id + "]"
        }
        let noteText = [note.title, note.text]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let hasText = !noteText.isEmpty
        let folder = RowFolder.folder(in: outputDirectory, name: stem, fileCount: note.media.count + (hasText ? 1 : 0))
        RowFolder.use(folder, for: item)
        let directory = folder ?? outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        item.title = note.title.isEmpty ? note.author : note.title

        var saved: [URL] = []
        var images = 0
        var videos = 0
        var failure: DirectDownload.FileFailure?
        for (index, media) in note.media.enumerated() {
            guard !Task.isCancelled else { return false }
            let name = note.media.count > 1 ? "\(stem) #\(index + 1)" : stem
            if let existing = DirectDownload.existingFile(baseName: name, in: directory) {
                saved.append(existing)
                if media.kind == .image { images += 1 } else { videos += 1 }
                continue
            }
            item.status = .downloading
            let outcome = await DirectDownload.download(
                media.url, headers: ["Referer": "https://www.xiaohongshu.com/"],
                to: directory, baseName: name,
                fallbackExtension: media.kind == .video ? "mp4" : "jpg",
                accepting: media.kind == .image ? Set(MediaExtensions.image) : Set(MediaExtensions.video),
                item: item, fileIndex: index, fileCount: note.media.count, session: session)
            switch outcome {
            case .saved(let url):
                saved.append(url)
                if media.kind == .image { images += 1 } else { videos += 1 }
            case .cancelled: return false
            case .failed(let reason): failure = reason
            }
        }

        // Preserve the complete caption even when a note contains no media.
        if hasText {
            let textURL = directory.appendingPathComponent(stem + ".txt")
            do {
                if !FileManager.default.fileExists(atPath: textURL.path) {
                    try noteText.write(to: textURL, atomically: true, encoding: .utf8)
                }
                saved.append(textURL)
            } catch {
                item.status = .failed("The note was read, but its text file couldn't be saved. Check the download folder's disk and permissions, then Retry.")
                return false
            }
        }

        guard let first = saved.first else {
            item.status = .failed(failure.map { "Couldn't save this Xiaohongshu note — \(DirectDownload.shortReason(for: $0)). Retry." }
                ?? "This Xiaohongshu note has no downloadable media or text.")
            return false
        }
        item.outputPath = saved.first(where: { MediaExtensions.video.contains($0.pathExtension.lowercased()) })?.path
            ?? saved.first(where: { MediaExtensions.image.contains($0.pathExtension.lowercased()) })?.path
            ?? first.path
        item.imageCount = images > 0 ? images : nil
        item.videoCount = videos > 0 ? videos : nil
        item.recomputeMediaCategory()
        if let failure {
            item.status = .failed(DirectDownload.partialFailureMessage(saved: images + videos, attempted: note.media.count, lastFailure: failure))
            return false
        }
        item.markCompleted()
        return true
    }

    static func resolve(html: String, id: String) -> Note? {
        guard let stateRange = html.range(of: "window.__INITIAL_STATE__") else { return nil }
        guard let equals = html[stateRange.upperBound...].firstIndex(of: "=") else { return nil }
        let jsonStart = html[html.index(after: equals)...].firstIndex(of: "{")
        guard let jsonStart, let jsonEnd = matchingObjectEnd(in: html, from: jsonStart),
            let object = try? JSONSerialization.jsonObject(with: Data(html[jsonStart...jsonEnd].utf8)) as? [String: Any],
            let noteRoot = object["note"] as? [String: Any],
            let detailMap = noteRoot["noteDetailMap"] as? [String: Any],
            let detail = detailMap[id] as? [String: Any],
            let note = detail["note"] as? [String: Any]
        else { return nil }

        let title = note["title"] as? String ?? ""
        let text = note["desc"] as? String ?? ""
        let author = (note["user"] as? [String: Any])?["nickname"] as? String ?? ""
        var media: [Note.Media] = []
        var videoURL: URL?
        if let video = note["video"] as? [String: Any], let videoMedia = video["media"] as? [String: Any],
            let streams = videoMedia["stream"]
        {
            videoURL = collectURLs(in: streams).compactMap(safeMediaURL).first
            if videoURL == nil, let key = (video["consumer"] as? [String: Any])?["originVideoKey"] as? String {
                videoURL = safeMediaURL("https://sns-video-bd.xhscdn.com/\(key)")
            }
            if let videoURL { media.append(.init(url: videoURL, kind: .video)) }
        }
        // A video note's imageList is its cover/preview set, not a photo
        // carousel. Saving those as attached images would produce duplicates.
        if videoURL == nil, let images = note["imageList"] as? [[String: Any]] {
            for image in images {
                let info = image["infoList"] as? [[String: Any]] ?? []
                let fullSize = info.first(where: { ($0["imageScene"] as? String) == "WB_DFT" })
                let preferred = fullSize ?? info.max { area($0) < area($1) }
                let raw = preferred?["url"] as? String ?? image["urlDefault"] as? String ?? image["urlPre"] as? String
                if let raw, let url = safeMediaURL(raw) { media.append(.init(url: url, kind: .image)) }
            }
        }
        guard !media.isEmpty
            || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return Note(id: id, title: title, text: text, author: author, media: media)
    }

    /// RedNote's current server-rendered page provides the caption and every
    /// carousel image as Open Graph tags, even when it omits the older
    /// `window.__INITIAL_STATE__` payload. Its own page declares
    /// `upgrade-insecure-requests`, so legacy `http` CDN URLs are upgraded
    /// to HTTPS before downloading.
    static func resolveOpenGraph(html: String, id: String) -> Note? {
        let tags = matches(#"<meta\b[^>]*>"#, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators])
        var title: String?
        var description: String?
        var imageURLs: [URL] = []
        var videoURLs: [URL] = []
        for tag in tags {
            guard let content = attribute("content", in: tag) else { continue }
            let property = (attribute("property", in: tag) ?? attribute("name", in: tag) ?? "").lowercased()
            switch property {
            case "og:title": title = decodeEntities(content)
            case "og:description": description = decodeEntities(content)
            case "og:image":
                let decoded = decodeEntities(content)
                guard decoded.contains("xhscdn.com"), let url = safeMediaURL(decoded) else { continue }
                if !imageURLs.contains(url) { imageURLs.append(url) }
            case "og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream":
                let decoded = decodeEntities(content)
                guard decoded.contains("xhscdn.com"), let url = safeMediaURL(decoded) else { continue }
                if !videoURLs.contains(url) { videoURLs.append(url) }
            default: break
            }
        }
        guard !imageURLs.isEmpty || !videoURLs.isEmpty
            || !(description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        let cleanTitle = (title ?? "").replacingOccurrences(of: #"\s+-\s+小红书$"#, with: "", options: .regularExpression)
        return Note(
            id: id,
            title: cleanTitle,
            text: description ?? "",
            author: "",
            media: !videoURLs.isEmpty
                ? videoURLs.map { Note.Media(url: $0, kind: .video) }
                : imageURLs.map { Note.Media(url: $0, kind: .image) })
    }

    static func isLoginPage(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let host = components.host?.lowercased() ?? ""
        return (host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com"))
            && components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "login"
    }

    private static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"(?:^|\s)"# + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*([\"'])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
            let range = Range(match.range(at: 2), in: tag)
        else { return nil }
        return String(tag[range])
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func collectURLs(in value: Any) -> [String] {
        if let string = value as? String, string.hasPrefix("http") { return [string] }
        if let dictionary = value as? [String: Any] {
            let preferred = ["masterUrl", "backupUrls", "url"]
            let direct = preferred.flatMap { key in dictionary[key].map(collectURLs(in:)) ?? [] }
            let nested = dictionary.keys.filter { !preferred.contains($0) }.sorted()
                .flatMap { dictionary[$0].map(collectURLs(in:)) ?? [] }
            return direct + nested
        }
        if let array = value as? [Any] { return array.flatMap(collectURLs(in:)) }
        return []
    }

    private static func safeMediaURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw), components.host != nil,
            components.scheme == "https" || components.scheme == "http"
        else { return nil }
        components.scheme = "https"
        return components.url
    }

    private static func area(_ info: [String: Any]) -> Int {
        (info["width"] as? Int ?? 0) * (info["height"] as? Int ?? 0)
    }

    private static func matchingObjectEnd(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in text[start...].indices {
            let char = text[index]
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
                continue
            }
            if char == "\"" { inString = true }
            else if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }
}
