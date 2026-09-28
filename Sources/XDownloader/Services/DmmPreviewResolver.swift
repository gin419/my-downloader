import Foundation

/// Finds the free preview material of a work page: its preview clip and its
/// sample pictures (the cover first). The page itself carries no data (it
/// is filled in by script), so the work's content id is read from the link
/// and the site's data endpoint is asked once for the addresses of what it
/// shows every logged-out visitor.
///
/// Only that material is in scope. The answer's free-sample and picture
/// fields are the only ones asked for and the only ones read: purchased,
/// rental and subscription videos are never looked up, tried or fallen back
/// to, and a work with neither a clip nor a picture ends with a message
/// saying so. The request is made logged out — no cookie is stored or sent —
/// and nothing resolved is kept: the addresses are asked for again on every
/// run.
enum DmmPreviewResolver {

    // MARK: - The data request (everything the site can change)

    // A change on the site's side is fixed HERE: the endpoint, the query and
    // the names of the fields read from the answer. Nothing below this
    // section spells a field name of its own.

    static let endpoint = URL(string: "https://api.video.dmm.co.jp/graphql")!

    static let operationName = "PreviewResolve"

    /// Asks for the visitor's region status, the names the files are called
    /// after, the free-sample addresses and the addresses of the pictures the
    /// page shows. Nothing else of the work.
    static let query =
        "query PreviewResolve($id: ID!) { ipInfo { accessStatus } "
        + "ppvContent(id: $id) { id title isAllowForeign maker { name } "
        + "sample2DMovie { highestMovieUrl hlsMovieUrl } sampleVRMovie { highestMovieUrl } "
        + "packageImage { largeUrl mediumUrl } sampleImages { number imageUrl largeImageUrl } } }"

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
        static let cover = "packageImage"
        static let coverLarge = "largeUrl"
        static let coverSmaller = "mediumUrl"
        static let samplePictures = "sampleImages"
        static let pictureNumber = "number"
        static let pictureLarge = "largeImageUrl"
        static let pictureSmaller = "imageUrl"
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
    struct Clip: Equatable {
        let address: URL
        let kind: Kind
    }

    /// One picture of the work's gallery. `position` is its place in the
    /// gallery the page shows (1 is the cover when there is one): it numbers
    /// the file, so a picture keeps its name whichever others fail.
    struct Picture: Equatable {
        let position: Int
        let address: URL
    }

    /// Everything free a work page offers: at least a clip or one picture.
    struct Preview: Equatable {
        let clip: Clip?
        /// In gallery order.
        let pictures: [Picture]
        /// What the answer offered that cannot be downloaded — an address
        /// turned down, an entry of a type this resolver does not read. Each
        /// counts as one file that failed: the row must not report a clean
        /// finish with a silently smaller count.
        let unusable: Int
        let title: String
        let maker: String
        let contentID: String
    }

    /// Why a link yielded nothing to download. One cause, one message.
    enum Failure: Error, Equatable, CaseIterable {
        /// A link on the site that names no single work.
        case notAWorkPage
        /// The site knows no work by this content id.
        case notFound
        /// The work exists and offers no free preview clip and no picture.
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
    /// for, only to learn where it was sent. The pictures' downloads refuse
    /// redirects with it too. Internal (not private) for tests.
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

    /// Reads the answer's free-sample and picture fields. The work resolves
    /// when it offers a clip or at least one picture; "no preview" is said
    /// only when everything is plainly empty. Anything of a type this
    /// resolver does not read, or an address it turns down, is a changed
    /// format when nothing else is left to download, and otherwise one
    /// failed file among the ones that do download — or every work would
    /// read as having nothing the day the site reshapes one field.
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
        guard let work = work as? [String: Any] else { return .failure(.changedFormat) }
        if let status, status != RegionStatus.allowed, work[Field.offeredAbroad] as? Bool == false {
            return .failure(.regionBlocked)
        }

        let clip = readClip(of: work)
        let gallery = readGallery(of: work)
        let unusable = gallery.unusable + (clip == .unusable ? 1 : 0)
        guard case .found(let found) = clip else {
            guard !gallery.pictures.isEmpty else { return .failure(unusable == 0 ? .noPreview : .changedFormat) }
            return .success(preview(of: work, contentID: contentID, clip: nil, gallery: gallery, unusable: unusable))
        }
        return .success(preview(of: work, contentID: contentID, clip: found, gallery: gallery, unusable: unusable))
    }

    private static func preview(
        of work: [String: Any], contentID: String, clip: Clip?, gallery: Gallery, unusable: Int
    ) -> Preview {
        // The id names the files: the site's own spelling of it when that
        // is a usable one, else the id the link carried.
        let named = text(work[Field.contentID]).map { $0.lowercased() }.flatMap { isContentID($0) ? $0 : nil }
        return Preview(
            clip: clip,
            pictures: gallery.pictures,
            unusable: unusable,
            title: text(work[Field.title]) ?? "",
            maker: text((work[Field.maker] as? [String: Any])?[Field.makerName]) ?? unknownMaker,
            contentID: named ?? contentID)
    }

    private enum ClipReading: Equatable {
        case found(Clip)
        /// The samples are there and plainly empty.
        case none
        case unusable
    }

    /// Preference: the standard preview file, then the VR preview file, then
    /// the standard preview as a stream. An address that is not the expected
    /// kind of address is unusable — nothing else is tried in its place.
    /// Samples that are missing, or of a type this resolver does not read,
    /// are unusable too, not empty.
    private static func readClip(of work: [String: Any]) -> ClipReading {
        guard work[Field.standardSample] != nil, work[Field.vrSample] != nil else { return .unusable }
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
            return plainlyEmpty ? .none : .unusable
        }
        guard let address = previewAddress(raw) else { return .unusable }
        return .found(Clip(address: address, kind: pick.kind))
    }

    private struct Gallery {
        let pictures: [Picture]
        let unusable: Int
    }

    private enum PictureReading {
        case found(URL)
        /// Both sizes are null or empty: there is no picture here.
        case empty
        case unusable
    }

    /// The gallery the page builds: the cover first, then the sample
    /// pictures sorted by their number (the answer's own order is not the
    /// page's), each at its largest size. An entry that holds an address,
    /// usable or not, takes its place in the gallery, so the pictures after
    /// it keep their numbers; one without a number has no place and only
    /// counts as unusable.
    private static func readGallery(of work: [String: Any]) -> Gallery {
        var places: [URL?] = []
        var unusable = 0

        // A missing field takes the cover's place: the query asks for it, so
        // an answer without it has been reshaped.
        let cover = work[Field.cover] ?? [String: Any]()
        if !(cover is NSNull) {
            switch readPicture(cover, large: Field.coverLarge, smaller: Field.coverSmaller) {
            case .found(let address): places.append(address)
            case .empty: break
            case .unusable: places.append(nil)
            }
        }

        // A missing list is read like one of another type (the `default`).
        switch work[Field.samplePictures] ?? 0 {
        case is NSNull:
            break
        case let list as [Any]:
            var numbered: [(number: Int, reading: PictureReading)] = []
            for element in list {
                guard let entry = element as? [String: Any], let number = entry[Field.pictureNumber] as? Int else {
                    unusable += 1
                    continue
                }
                numbered.append((number, readPicture(entry, large: Field.pictureLarge, smaller: Field.pictureSmaller)))
            }
            // Stable: two entries with one number keep the answer's order.
            let sorted = numbered.enumerated().sorted { ($0.element.number, $0.offset) < ($1.element.number, $1.offset) }
            for (_, entry) in sorted {
                switch entry.reading {
                case .found(let address): places.append(address)
                case .empty: break
                case .unusable: places.append(nil)
                }
            }
        default:
            unusable += 1
        }

        let pictures = places.enumerated().compactMap { index, address in
            address.map { Picture(position: index + 1, address: $0) }
        }
        return Gallery(pictures: pictures, unusable: unusable + places.filter { $0 == nil }.count)
    }

    /// The largest size of one picture. The smaller one is taken only when
    /// the large one is null or empty — never when the large one is there
    /// and turned down, or the thumbnail would stand in for a picture that
    /// exists. Both fields must be present: a renamed one is the site having
    /// reshaped its answer, not a picture without that size.
    private static func readPicture(_ value: Any, large: String, smaller: String) -> PictureReading {
        guard let entry = value as? [String: Any] else { return .unusable }
        for name in [large, smaller] {
            guard let field = entry[name] else { return .unusable }
            if field is NSNull { continue }
            guard let raw = field as? String else { return .unusable }
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            return pictureAddress(raw).map(PictureReading.found) ?? .unusable
        }
        return .empty
    }

    /// Only an https address of a file or stream on one of the site's own
    /// hosts is a preview. The answer is the only source of the address and
    /// it goes to the downloader as it is, so anything else in that place is
    /// turned down here. This checks the address as written, no more: what
    /// the host answers with is the downloader's to deal with, and an answer
    /// that is no media ends the row with a fixed message (see
    /// YtDlpService.resolvedAddressFailureMessage).
    static func previewAddress(_ raw: String) -> URL? {
        siteAddress(raw, extensions: previewExtensions)
    }

    /// The same check for a picture: an https address of a picture file on
    /// one of the site's own hosts. It is fetched in-app, so anything else
    /// in its place would be saved into the download folder as a picture.
    /// What the host answers is checked when it arrives (see
    /// `downloadPictures`).
    static func pictureAddress(_ raw: String) -> URL? {
        siteAddress(raw, extensions: pictureExtensions)
    }

    private static func siteAddress(_ raw: String, extensions: [String]) -> URL? {
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
            components.user == nil, components.password == nil,
            let host = components.host?.lowercased(), host.hasSuffix(siteHostSuffix), host.count > siteHostSuffix.count
        else { return nil }
        let path = components.path.lowercased()
        guard extensions.contains(where: { path.hasSuffix($0) }) else { return nil }
        return URL(string: raw)
    }

    private static let siteHostSuffix = ".dmm.co.jp"
    private static let previewExtensions = [".mp4", ".m3u8"]
    private static let pictureExtensions = [".jpg", ".jpeg", ".png", ".webp"]

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

    // MARK: - Downloading the pictures

    /// How the pictures' downloads ended.
    enum PictureRun {
        /// `saved` holds every picture on disk, in gallery order — this
        /// run's downloads and the ones an earlier run saved.
        /// `lastFailure` is the last download that failed, nil when none did:
        /// with several, the freshest evidence (see DirectDownload.FileFailure).
        case finished(saved: [URL], lastFailure: DirectDownload.FileFailure?)
        /// The wrapping Task was cancelled (Stop / remove): no outcome.
        case cancelled
    }

    /// Downloads the pictures into `directory` in-app, one at a time, with
    /// the session that keeps and sends no cookies: the pictures are served
    /// to every visitor, and yt-dlp has nothing to offer for a plain file.
    /// A picture already on disk is not fetched again, so a Retry only
    /// fetches what is missing. The row reads "downloading" only while a
    /// transfer runs; the outcome is the caller's to put on the row.
    ///
    /// The address was checked as written, so it must also be where the
    /// picture comes from: a redirect is refused, not followed, and fails as
    /// its status. Only an answer that is a picture is saved; anything else
    /// fails instead of landing in the folder under a picture's name, where
    /// a Retry would take it for one already downloaded.
    ///
    /// `session` is a seam for tests; the default keeps and sends no cookies.
    @MainActor
    static func downloadPictures(
        _ pictures: [Picture], stem: String, to directory: URL, item: DownloadItem, session: URLSession = DirectDownload.session
    ) async -> PictureRun {
        var saved: [URL] = []
        var lastFailure: DirectDownload.FileFailure?
        for (index, picture) in pictures.enumerated() {
            // Stop and the row's ✕ cancel the wrapping Task: end between
            // files; a transfer in flight reports .cancelled itself.
            if Task.isCancelled { return .cancelled }
            let name = pictureBaseName(stem: stem, position: picture.position)
            if let existing = DirectDownload.existingFile(baseName: name, in: directory) {
                saved.append(existing)
                continue
            }
            item.status = .downloading
            let outcome = await DirectDownload.download(
                picture.address, to: directory, baseName: name, fallbackExtension: nil, accepting: MediaExtensions.image,
                item: item, fileIndex: index, fileCount: pictures.count, session: session, delegate: RedirectRefusal())
            switch outcome {
            case .saved(let url): saved.append(url)
            case .failed(let failure): lastFailure = failure
            case .cancelled: return .cancelled
            }
        }
        if Task.isCancelled { return .cancelled }
        return .finished(saved: saved, lastFailure: lastFailure)
    }

    /// File name of a picture, without its extension (the server's answer
    /// names that): the clip's stem numbered in gallery order, the way the
    /// files of a multi-file X post are numbered. The clip keeps the plain
    /// stem, as it always has.
    static func pictureBaseName(stem: String, position: Int) -> String {
        "\(stem) #\(position)"
    }

    /// Why a file the answer offered was counted as failed without being
    /// requested: an address turned down, an entry that could not be read.
    static let unusableEntryReason = "the site's answer held an address that couldn't be used"

    /// No clip, and not one picture could be saved. A Retry asks for the
    /// addresses again.
    static func noPictureSavedMessage(reason: String) -> String {
        "None of the sample pictures could be saved — \(reason). Retry fetches them again."
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
    static let noPreviewMessage =
        "This work has no free preview clip or sample pictures, so there is nothing to download. " + paidVideosNotSupportedMessage
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
