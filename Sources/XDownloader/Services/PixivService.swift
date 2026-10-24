import Foundation

/// In-app resolver for Pixiv artworks ("pixiv.net/artworks/<id>"). gallery-dl
/// has a Pixiv extractor, but it refuses to run without an OAuth
/// refresh-token most people never set up; the site's own web API answers
/// logged-out visitors with every page's original address, so two small
/// requests resolve an artwork. The files are served only to requests that
/// say they come from Pixiv ("Referer"), and need nothing else: no cookie is
/// sent anywhere. Also used for an X post whose only content is a link to
/// an artwork (see `FxTwitterService`).
enum PixivService {

    // MARK: - Running a download

    /// Resolves artwork `artworkID` and downloads every page of it into
    /// `outputDirectory` (two or more pages into a folder of their own).
    /// Returns true only when every page is on disk. Every exit but a
    /// cancel leaves the row completed or failed with a message of its own.
    @MainActor
    static func run(
        item: DownloadItem, artworkID: String, outputDirectory: URL, session: URLSession = DirectDownload.session
    ) async -> Bool {
        item.status = .fetching
        item.eta = nil
        item.emptySuccessFailure = false

        let pages: [URL]
        switch await fetchJSON(pagesURL(for: artworkID), artworkID: artworkID, session: session) {
        case .cancelled: return false
        case .unreachable(let failure):
            item.status = .failed(pageUnreachableMessage(failure))
            return false
        case .answered(let json):
            switch readPages(json) {
            case .success(let found): pages = found
            case .failure(.noPages):
                // An artwork withheld from logged-out visitors and one that
                // is not there answer alike; the artwork's own record tells
                // them apart.
                let failure: Failure
                switch await fetchJSON(infoURL(for: artworkID), artworkID: artworkID, session: session) {
                case .cancelled: return false
                case .answered(let info): failure = classifyMissingPages(info: info)
                case .unreachable: failure = .notFound
                }
                item.status = .failed(message(for: failure))
                return false
            case .failure(let failure):
                item.status = .failed(message(for: failure))
                return false
            }
        }
        if Task.isCancelled { return false }

        // The names come from the artwork's record; without it the files
        // are still named, after the id.
        var author = unknownAuthor
        var title = ""
        if case .answered(let info) = await fetchJSON(infoURL(for: artworkID), artworkID: artworkID, session: session),
            let details = readDetails(info)
        {
            author = details.author
            title = details.title
        }
        if Task.isCancelled { return false }

        let stem = ThreadsService.fileStem(author: author, text: title, code: artworkID)
        let folder = RowFolder.folder(in: outputDirectory, name: stem, fileCount: pages.count)
        RowFolder.use(folder, for: item)
        let directory = folder ?? outputDirectory
        var savedPaths: [String] = []
        var lastFailure: DirectDownload.FileFailure?
        for (index, address) in pages.enumerated() {
            if Task.isCancelled { return false }
            let name = ThreadsService.baseName(stem: stem, index: index, count: pages.count)
            if let existing = DirectDownload.existingFile(baseName: name, in: directory) {
                savedPaths.append(existing.path)
                continue
            }
            item.status = .downloading
            let outcome = await DirectDownload.download(
                address, headers: fileHeaders, to: directory, baseName: name, fallbackExtension: nil,
                accepting: MediaExtensions.image, item: item, fileIndex: index, fileCount: pages.count, session: session)
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
        if item.title == nil { item.title = ThreadsService.displayTitle(author: author, text: title) }
        if let lastFailure {
            item.speed = nil
            item.status = .failed(
                DirectDownload.partialFailureMessage(saved: savedPaths.count, attempted: pages.count, lastFailure: lastFailure))
            return false
        }
        item.markCompleted()
        return true
    }

    private enum JSONOutcome {
        case answered([String: Any])
        case unreachable(DirectDownload.FileFailure)
        case cancelled
    }

    /// One API request. Pixiv answers a missing artwork with an HTTP error
    /// status and a JSON body saying so, so the body is read whatever the
    /// status.
    @MainActor
    private static func fetchJSON(_ url: URL, artworkID: String, session: URLSession) async -> JSONOutcome {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: DirectDownload.request(for: url, headers: apiHeaders(for: artworkID)))
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
            return .unreachable(.transport(error))
        }
        if Task.isCancelled { return .cancelled }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return .answered(json) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return .unreachable(.httpStatus(status))
    }

    // MARK: - Requests

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"

    static func apiHeaders(for artworkID: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "application/json",
            "Referer": canonicalLink(for: artworkID),
        ]
    }

    /// Without the Referer the file host answers HTTP 403.
    static let fileHeaders: [String: String] = [
        "User-Agent": userAgent,
        "Referer": "https://www.pixiv.net/",
    ]

    static func pagesURL(for artworkID: String) -> URL {
        URL(string: "https://www.pixiv.net/ajax/illust/\(artworkID)/pages")!
    }

    static func infoURL(for artworkID: String) -> URL {
        URL(string: "https://www.pixiv.net/ajax/illust/\(artworkID)")!
    }

    // MARK: - Links

    static let hosts: Set<String> = ["pixiv.net", "www.pixiv.net", "touch.pixiv.net"]

    /// The artwork id a link names: "/artworks/<id>", "/<language>/artworks/<id>",
    /// "/i/<id>" and the old "/member_illust.php?illust_id=<id>". Nil for
    /// every other link — a user page, a novel, a search.
    static func artworkID(of link: String) -> String? {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(), hosts.contains(host)
        else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        var candidate: String?
        if parts.count == 2, parts[0] == "artworks" || parts[0] == "i" {
            candidate = parts[1]
        } else if parts.count == 3, parts[1] == "artworks", parts[0].count <= 5, parts[0].allSatisfy({ $0.isLetter || $0 == "-" }) {
            candidate = parts[2]
        } else if parts == ["member_illust.php"] {
            candidate = components.queryItems?.first { $0.name == "illust_id" }?.value
        }
        guard let candidate, isArtworkID(candidate) else { return nil }
        return candidate
    }

    static func isArtworkLink(_ link: String) -> Bool { artworkID(of: link) != nil }

    static func canonicalLink(for artworkID: String) -> String { "https://www.pixiv.net/artworks/\(artworkID)" }

    /// The first artwork a piece of text links to (an X post's text, with
    /// its links expanded), or nil.
    static func firstArtworkID(in text: String) -> String? {
        DownloadManager.extractURLs(from: text).lazy.compactMap(artworkID(of:)).first
    }

    private static func isArtworkID(_ text: String) -> Bool {
        (1...12).contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Reading the answers

    enum Failure: Error, Equatable {
        case notFound
        /// Pixiv shows the artwork only to signed-in visitors (R-18 works).
        case needsSignIn
        /// The answer had pages, but none with an address that could be used.
        case changedFormat
        /// The pages answer was an error or empty.
        case noPages
    }

    /// The original address of every page, in order.
    static func readPages(_ json: [String: Any]) -> Result<[URL], Failure> {
        guard json["error"] as? Bool == false, let body = json["body"] as? [Any], !body.isEmpty else {
            return .failure(.noPages)
        }
        let addresses = body.compactMap { page -> URL? in
            guard let urls = (page as? [String: Any])?["urls"] as? [String: Any],
                let raw = urls["original"] as? String
            else { return nil }
            return fileAddress(raw)
        }
        return addresses.isEmpty ? .failure(.changedFormat) : .success(addresses)
    }

    /// Why an artwork has no pages for a logged-out visitor, judged by its
    /// record: no record is a missing artwork; a record marked R-18, or one
    /// whose pages are withheld all the same, needs a sign-in.
    static func classifyMissingPages(info: [String: Any]) -> Failure {
        guard info["error"] as? Bool == false, let body = info["body"] as? [String: Any] else { return .notFound }
        return body.isEmpty ? .notFound : .needsSignIn
    }

    struct Details: Equatable {
        let author: String
        let title: String
    }

    static func readDetails(_ json: [String: Any]) -> Details? {
        guard json["error"] as? Bool == false, let body = json["body"] as? [String: Any] else { return nil }
        let author = (body["userName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? unknownAuthor
        return Details(author: author, title: body["illustTitle"] as? String ?? "")
    }

    /// Only Pixiv's own file host, over https.
    static func fileAddress(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host?.lowercased() == "i.pximg.net" else {
            return nil
        }
        return url
    }

    static let unknownAuthor = "pixiv"

    // MARK: - Failure messages

    static let notFoundMessage =
        "Pixiv artwork not found — it may be deleted or private, or the link may be incomplete; check the link, then Retry."
    static let needsSignInMessage =
        "Pixiv only shows this artwork to signed-in visitors (it may be R-18), so it can't be downloaded."
    static let changedFormatMessage =
        "Pixiv changed its data format, so the artwork's pictures couldn't be found — update XDownloader, then Retry."

    static func pageUnreachableMessage(_ failure: DirectDownload.FileFailure) -> String {
        "Couldn't reach Pixiv to find the artwork — \(DirectDownload.shortReason(for: failure)). Check the connection, then Retry."
    }

    static func nothingSavedMessage(lastFailure: DirectDownload.FileFailure?) -> String {
        guard let lastFailure else { return "None of this artwork's pictures could be saved — Retry." }
        return "None of this artwork's pictures could be saved — \(DirectDownload.shortReason(for: lastFailure)). Retry fetches them again."
    }

    static func message(for failure: Failure) -> String {
        switch failure {
        case .notFound, .noPages: return notFoundMessage
        case .needsSignIn: return needsSignInMessage
        case .changedFormat: return changedFormatMessage
        }
    }
}
