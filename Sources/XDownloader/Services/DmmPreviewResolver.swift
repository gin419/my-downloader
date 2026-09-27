import Foundation

/// Finds the free preview clip of a work page. The page itself carries no
/// data (it is filled in by script), so the work's content id is read from
/// the link and the site's data endpoint is asked once for the address of
/// the preview clip it offers every logged-out visitor.
///
/// Only that clip is in scope. The answer's free-sample fields are the only
/// ones asked for and the only ones read: purchased, rental and subscription
/// videos are never looked up, tried or fallen back to, and a work without a
/// preview ends with a message saying so. The request is made logged out —
/// no cookie is stored or sent — and nothing resolved is kept: the address
/// is asked for again on every run.
enum DmmPreviewResolver {

    // MARK: - The data request (everything the site can change)

    // A change on the site's side is fixed HERE: the endpoint, the query and
    // the names of the fields read from the answer. Nothing below this
    // section spells a field name of its own.

    static let endpoint = URL(string: "https://api.video.dmm.co.jp/graphql")!

    static let operationName = "PreviewResolve"

    /// Asks for the visitor's region status, the names the file is called
    /// after, and the free-sample addresses. Nothing else of the work.
    static let query =
        "query PreviewResolve($id: ID!) { ipInfo { accessStatus } "
        + "ppvContent(id: $id) { id title isAllowForeign maker { name } "
        + "sample2DMovie { highestMovieUrl hlsMovieUrl } sampleVRMovie { highestMovieUrl } } }"

    private enum Field {
        static let data = "data"
        static let errors = "errors"
        static let region = "ipInfo"
        static let regionStatus = "accessStatus"
        static let work = "ppvContent"
        static let contentID = "id"
        static let title = "title"
        static let offeredAbroad = "isAllowForeign"
        static let maker = "maker"
        static let makerName = "name"
        static let standardSample = "sample2DMovie"
        static let vrSample = "sampleVRMovie"
        static let fileAddress = "highestMovieUrl"
        static let streamAddress = "hlsMovieUrl"
    }

    private enum RegionStatus {
        static let allowed = "ALLOW"
        static let denied = "DENY"
    }

    /// Where the site sends a visitor whose region it does not serve.
    private static let regionNoticeMarker = "not-available-in-your-region"

    /// What the request sends, and nothing else of ours.
    static let requestHeaders: [String: String] = [
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36",
        "Referer": "https://video.dmm.co.jp/",
    ]

    /// The one request of a download attempt: a POST carrying the content
    /// id. It takes no cookie with it and accepts none.
    static func request(contentID: String) -> URLRequest {
        var request = DirectDownload.request(for: endpoint, headers: requestHeaders)
        request.httpMethod = "POST"
        let body: [String: Any] = ["operationName": operationName, "query": query, "variables": ["id": contentID]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // MARK: - Resolving

    /// Which of the work's free samples the address belongs to, in the order
    /// they are preferred.
    enum Kind: String {
        /// The standard preview, as one file.
        case standard
        /// The VR preview, as one file.
        case vr
        /// The standard preview as a stream: the last resort, for a work
        /// that names no file.
        case stream
    }

    /// A work's free preview clip. `address` is handed to the downloader
    /// exactly as given.
    struct Preview: Equatable {
        let address: URL
        let title: String
        let maker: String
        let contentID: String
        let kind: Kind
    }

    /// Why a link yielded no preview clip. One cause, one message.
    enum Failure: Error, Equatable, CaseIterable {
        /// A link on the site that names no single work.
        case notAWorkPage
        /// The site knows no work by this content id.
        case notFound
        /// The work exists and offers no free preview.
        case noPreview
        /// The site does not serve this visitor's region.
        case regionBlocked
        /// The answer is not in the shape this resolver reads.
        case changedFormat
        /// No answer, or the server failed.
        case network
    }

    /// How one resolve ended.
    enum Outcome: Equatable {
        case resolved(Preview)
        case failed(Failure)
        /// The wrapping Task was cancelled (Stop / remove): not a failure to
        /// report.
        case cancelled
    }

    /// Resolves a work page link with one request. A link that names no
    /// work makes no request at all.
    ///
    /// `session` is a seam for tests; the default keeps and sends no cookies.
    static func resolve(link: String, session: URLSession = DirectDownload.session) async -> Outcome {
        guard let work = parseLink(link) else { return .failed(.notAWorkPage) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(contentID: work.contentID), delegate: RedirectRefusal())
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
            return .failed(.network)
        }
        if Task.isCancelled { return .cancelled }
        guard let http = response as? HTTPURLResponse else { return .failed(.changedFormat) }
        if let failure = classifyTransport(
            status: http.statusCode, redirectTarget: http.value(forHTTPHeaderField: "Location"),
            contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data)
        {
            return .failed(failure)
        }
        switch classify(response: data, contentID: work.contentID) {
        case .success(let preview): return .resolved(preview)
        case .failure(let failure): return .failed(failure)
        }
    }

    /// Keeps the attempt at one request: a redirect is not followed, it is
    /// the answer. Following it would fetch a page this resolver has no use
    /// for, only to learn where it was sent. Internal (not private) for tests.
    final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Classifies an answer that is not the data asked for; nil when the
    /// body is worth reading. `redirectTarget` is the address a redirect
    /// names, `body` what came instead of data.
    static func classifyTransport(status: Int, redirectTarget: String?, contentType: String?, body: Data) -> Failure? {
        if (300..<400).contains(status) {
            // The endpoint answers in place today. Sent to the region notice
            // the cause is known; sent anywhere else the site has changed
            // how it serves its data.
            return redirectTarget?.contains(regionNoticeMarker) == true ? .regionBlocked : .changedFormat
        }
        if status == 403 || status == 451 { return .regionBlocked }
        if status == 408 || status == 429 || status >= 500 { return .network }
        guard (200..<300).contains(status) else { return .changedFormat }
        if contentType?.lowercased().contains("json") != true {
            // A page where data was expected. Only its first part is looked
            // at, and only for the name of the notice it may be.
            let head = String(decoding: body.prefix(4000), as: UTF8.self)
            return head.contains(regionNoticeMarker) ? .regionBlocked : .changedFormat
        }
        return nil
    }

    /// Reads the answer's free-sample fields. Preference: the standard
    /// preview file, then the VR preview file, then the standard preview as
    /// a stream. An address that is not the expected kind of address means
    /// the format changed — nothing else is tried in its place. "No preview"
    /// is said only of samples that are plainly empty: a sample or an
    /// address of a type this resolver does not read is a changed format,
    /// or every work would read as having no preview the day the site
    /// reshapes them.
    static func classify(response: Data, contentID: String) -> Result<Preview, Failure> {
        guard let payload = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
            let data = payload[Field.data] as? [String: Any],
            let work = data[Field.work]
        else { return .failure(.changedFormat) }

        let region = data[Field.region] as? [String: Any]
        let status = region?[Field.regionStatus] as? String
        if status == RegionStatus.denied { return .failure(.regionBlocked) }

        if work is NSNull {
            // An unknown id is a plain null; a null that comes with errors
            // is a query the site no longer accepts.
            let errors = payload[Field.errors] as? [Any] ?? []
            return .failure(errors.isEmpty ? .notFound : .changedFormat)
        }
        guard let work = work as? [String: Any], work[Field.standardSample] != nil, work[Field.vrSample] != nil else {
            return .failure(.changedFormat)
        }
        if let status, status != RegionStatus.allowed, work[Field.offeredAbroad] as? Bool == false {
            return .failure(.regionBlocked)
        }

        let standard = work[Field.standardSample] as? [String: Any]
        let vr = work[Field.vrSample] as? [String: Any]
        let candidates: [(address: String?, kind: Kind)] = [
            (text(standard?[Field.fileAddress]), .standard),
            (text(vr?[Field.fileAddress]), .vr),
            (text(standard?[Field.streamAddress]), .stream),
        ]
        guard let pick = candidates.first(where: { $0.address != nil }), let raw = pick.address else {
            let samples: [(sample: Any?, addresses: [String])] = [
                (work[Field.standardSample], [Field.fileAddress, Field.streamAddress]),
                (work[Field.vrSample], [Field.fileAddress]),
            ]
            let plainlyEmpty = samples.allSatisfy { isEmptySample($0.sample, addresses: $0.addresses) }
            return .failure(plainlyEmpty ? .noPreview : .changedFormat)
        }
        guard let address = previewAddress(raw) else { return .failure(.changedFormat) }

        // The id names the file: the site's own spelling of it when that is
        // a usable one, else the id the link carried.
        let named = text(work[Field.contentID]).map { $0.lowercased() }.flatMap { isContentID($0) ? $0 : nil }
        return .success(
            Preview(
                address: address,
                title: text(work[Field.title]) ?? "",
                maker: text((work[Field.maker] as? [String: Any])?[Field.makerName]) ?? unknownMaker,
                contentID: named ?? contentID,
                kind: pick.kind))
    }

    /// Only an https address of a file or stream on one of the site's own
    /// hosts is a preview. The answer is the only source of the address and
    /// it goes to the downloader as it is, so anything else in that place is
    /// turned down here. This checks the address as written, no more: what
    /// the host answers with is the downloader's to deal with, and an answer
    /// that is no media ends the row with a fixed message (see
    /// YtDlpService.resolvedAddressFailureMessage).
    static func previewAddress(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
            components.user == nil, components.password == nil,
            let host = components.host?.lowercased(), host.hasSuffix(previewHostSuffix), host.count > previewHostSuffix.count
        else { return nil }
        let path = components.path.lowercased()
        guard previewExtensions.contains(where: { path.hasSuffix($0) }) else { return nil }
        return URL(string: raw)
    }

    private static let previewHostSuffix = ".dmm.co.jp"
    private static let previewExtensions = [".mp4", ".m3u8"]

    /// True for a sample that is there and offers nothing: null, or an
    /// object whose every address is null or a string. (A string that held
    /// an address would have been picked before this is asked.)
    private static func isEmptySample(_ sample: Any?, addresses: [String]) -> Bool {
        if sample is NSNull { return true }
        guard let sample = sample as? [String: Any] else { return false }
        return addresses.allSatisfy { name in
            guard let value = sample[name] else { return false }
            return value is NSNull || value is String
        }
    }

    /// A non-empty string, nil for everything else the answer may hold in
    /// its place.
    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: - Failure messages

    // Every failure names its own cause: the downloader never runs for a
    // link that did not resolve, so there is no other message to fall back
    // on. Internal (not private) so tests share one source of truth. Where a
    // Retry cannot change the outcome the copy does not promise one.
    static let notAWorkPageMessage =
        "This link isn't a work page — open the work's own page and paste its link instead."
    static let notFoundMessage =
        "Work not found — it may have been removed, or the link may be incomplete; check the link, then Retry."
    static let noPreviewMessage = "This work has no free preview clip, so there is nothing to download. " + paidVideosNotSupportedMessage
    static let regionBlockedMessage =
        "Not available in your region — the site doesn't offer this preview clip where your connection is located."
    static let changedFormatMessage =
        "The site changed its data format, so the preview clip couldn't be found — update XDownloader, then Retry."
    static let networkMessage =
        "Couldn't reach the site to find the preview clip — check the connection, then Retry."

    /// What this resolver never downloads, in one fixed sentence.
    static let paidVideosNotSupportedMessage = "Purchased, rental and subscription videos are not supported."

    /// The message a failure puts on the row.
    static func message(for failure: Failure) -> String {
        switch failure {
        case .notAWorkPage: return notAWorkPageMessage
        case .notFound: return notFoundMessage
        case .noPreview: return noPreviewMessage
        case .regionBlocked: return regionBlockedMessage
        case .changedFormat: return changedFormatMessage
        case .network: return networkMessage
        }
    }

    // MARK: - Link parsing

    /// The one work a page link names. Only `contentID` identifies it; the
    /// section is kept for the canonical link and never sent anywhere.
    struct WorkLink: Equatable {
        let section: String
        let contentID: String
    }

    /// The exact host, compared lowercased — never a substring or suffix
    /// test: either would also claim the hosts that serve the preview files
    /// themselves, whose direct links download through the generic path.
    static let host = "video.dmm.co.jp"

    /// Where wrapper links live: the site's interposed page, whose links
    /// wrap the page the visitor was on the way to.
    private static let wrapperHost = "www.dmm.co.jp"
    private static let wrapperPathPrefix = "/age_check/"
    private static let wrapperReturnParameter = "rurl"

    private static let pagePathPattern = "^/([a-z][a-z0-9_-]{0,19})/content/?$"
    private static let contentIDPattern = "^[0-9a-z_]{3,40}$"

    /// True for a link on the site, in any letter case. Wider than
    /// `parseLink` on purpose: a link on the site that names no work still
    /// belongs to it, and is turned down with a message of its own.
    static func isSiteHost(_ link: String) -> Bool {
        webComponents(of: link)?.host?.lowercased() == host
    }

    /// Parses a link to a work page; nil for everything else — other sites,
    /// the site's other hosts, listing pages, a missing or malformed id. The
    /// id is the `id` parameter and nothing else of the query is read.
    static func parseLink(_ link: String) -> WorkLink? {
        guard let components = webComponents(of: link), components.host?.lowercased() == host,
            let section = captures(of: pagePathPattern, in: components.path.lowercased())?.first,
            // Lowercased BEFORE it is checked: the site's ids are lowercase,
            // and a link typed or shared in capitals names the same work.
            let contentID = components.queryItems?.first(where: { $0.name == "id" })?.value?.lowercased(),
            isContentID(contentID)
        else { return nil }
        return WorkLink(section: section, contentID: contentID)
    }

    /// The one form a work's link is kept in, whatever was pasted (letter
    /// case, http, no trailing slash, share parameters), so the same work is
    /// recognised as the same download.
    static func canonicalURL(for link: WorkLink) -> URL? {
        URL(string: "\(pageLinkPrefix)\(link.section)\(pageLinkSuffix(for: link))")
    }

    /// What every canonical link starts with, and what those of one work
    /// end with — the two parts that stay the same across sections, for
    /// finding a work in history under whichever section it was saved.
    static let pageLinkPrefix = "https://\(host)/"
    static func pageLinkSuffix(for link: WorkLink) -> String {
        "/content/?id=\(link.contentID)"
    }

    /// The canonical page link inside a wrapper link; nil when the link is
    /// not one, or wraps anything but a work page.
    static func unwrapWrapperLink(_ link: String) -> String? {
        guard let components = webComponents(of: link), components.host?.lowercased() == wrapperHost,
            components.path.lowercased().hasPrefix(wrapperPathPrefix),
            let inner = components.queryItems?.first(where: { $0.name == wrapperReturnParameter })?.value,
            let work = parseLink(inner)
        else { return nil }
        return canonicalURL(for: work)?.absoluteString
    }

    private static func isContentID(_ text: String) -> Bool {
        captures(of: contentIDPattern, in: text) != nil
    }

    private static func webComponents(of link: String) -> URLComponents? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return nil }
        return components
    }

    // MARK: - File names

    /// Stands in for a maker the answer doesn't name.
    static let unknownMaker = "dmm"

    /// "<maker> - <title, 100 characters> [<content id>]" — the shape X
    /// downloads have, with the sanitizing and the byte cap of
    /// ThreadsService.fileStem. The id keeps two works of one maker with the
    /// same title from colliding and being skipped as already downloaded.
    static func fileStem(maker: String, title: String, contentID: String) -> String {
        let name = leadingNamePart(maker)
        let maker = name.isEmpty ? unknownMaker : name
        var cut = String(ThreadsService.printable(title).prefix(100))
        var stem = DirectDownload.sanitize("\(maker) - \(cut) [\(contentID)]")
        while stem.utf8.count > ThreadsService.maxStemBytes, !cut.isEmpty {
            cut.removeLast()
            stem = DirectDownload.sanitize("\(maker) - \(cut) [\(contentID)]")
        }
        return stem
    }

    /// Row title: the stem without its id, as the rows of Threads posts
    /// have it.
    static func displayTitle(maker: String, title: String) -> String {
        let name = leadingNamePart(maker)
        let text = DirectDownload.sanitize("\(name.isEmpty ? unknownMaker : name) - \(String(ThreadsService.printable(title).prefix(100)))")
        return text.hasSuffix("-") ? String(text.dropLast()).trimmingCharacters(in: .whitespaces) : text
    }

    /// The maker as the first part of a name. A leading "." would make the
    /// saved file a hidden one: the row says Done and Finder shows nothing.
    private static func leadingNamePart(_ maker: String) -> String {
        var name = Substring(ThreadsService.printable(maker).trimmingCharacters(in: .whitespacesAndNewlines))
        while name.first == "." { name = name.dropFirst().drop(while: \.isWhitespace) }
        return String(name)
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
