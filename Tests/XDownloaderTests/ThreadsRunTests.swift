import XCTest

@testable import XDownloader

/// `ThreadsService.run` from link to files on disk: what it requests, what it
/// leaves on the row at every exit, and that it never reports more than
/// happened. The pages are the synthetic fixtures; page and media requests
/// are answered by a URLProtocol stub on an injected session, so nothing
/// here touches the network.
@MainActor
final class ThreadsRunTests: XCTestCase {

    private var downloads: URL!

    override func setUpWithError() throws {
        downloads = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadsRunTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: downloads)
    }

    // MARK: - Success

    func testSingleImagePostIsSavedUnderTheNameOfXDownloads() async throws {
        let post = try fixture("threads_single_image.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        StubProtocol.set(jpeg(), for: post.media[0])
        let item = DownloadItem(url: post.link + "?xmt=AQF0abc")

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        let saved = try contents(of: downloads)
        XCTAssertEqual(saved.count, 1)
        // One file: no " #1".
        XCTAssertTrue(saved[0].hasPrefix("Example Author - "), saved[0])
        XCTAssertTrue(saved[0].hasSuffix(" [SYNimage0001].jpg"), saved[0])
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent(saved[0]).path)
        XCTAssertEqual(item.imageCount, 1)
        XCTAssertNil(item.videoCount)
        XCTAssertEqual(item.mediaCategory, .image)
        XCTAssertEqual(item.progress, 1.0, accuracy: 0.0001)
        XCTAssertNil(item.speed)
        XCTAssertNil(item.eta)
        XCTAssertFalse(item.emptySuccessFailure)
        // The row shows the name without the code.
        let title = try XCTUnwrap(item.title)
        XCTAssertTrue(title.hasPrefix("Example Author - "), title)
        XCTAssertFalse(title.contains("SYNimage0001"), title)
    }

    func testPageRequestCarriesExactlyTheThreeHeadersAndNoCookies() async throws {
        let post = try fixture("threads_single_image.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        StubProtocol.set(jpeg(), for: post.media[0])
        let item = DownloadItem(url: post.link)

        _ = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertEqual(Set(ThreadsService.pageHeaders.keys), ["User-Agent", "Accept", "Sec-Fetch-Mode"])
        XCTAssertEqual(ThreadsService.pageHeaders["Accept"], "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        XCTAssertEqual(ThreadsService.pageHeaders["Sec-Fetch-Mode"], "navigate")
        XCTAssertEqual(ThreadsService.pageHeaders["User-Agent"]?.contains("Chrome/"), true)

        let pageRequests = StubProtocol.requests(to: post.pageURL)
        XCTAssertEqual(pageRequests.count, 1)
        XCTAssertEqual(pageRequests.first?.allHTTPHeaderFields, ThreadsService.pageHeaders)
        XCTAssertEqual(pageRequests.first?.httpShouldHandleCookies, false)

        // The media address goes out as resolved, with nothing attached.
        let mediaRequests = StubProtocol.requests(to: post.media[0])
        XCTAssertEqual(mediaRequests.count, 1)
        XCTAssertEqual(mediaRequests.first?.allHTTPHeaderFields ?? [:], [:])
        XCTAssertEqual(mediaRequests.first?.httpShouldHandleCookies, false)
    }

    func testLinkFormsAllFetchTheCanonicalAddress() async throws {
        let post = try fixture("threads_single_image.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        StubProtocol.set(jpeg(), for: post.media[0])
        let item = DownloadItem(url: "https://THREADS.NET/@example_author/post/SYNimage0001/media?igshid=abc")

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
    }

    func testMixedPostIsNumberedCountedAndOpensOnTheVideo() async throws {
        let post = try fixture("threads_mixed_carousel.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        for (address, kind) in zip(post.media, post.kinds) {
            StubProtocol.set(kind == "video" ? mp4() : webp(), for: address)
        }
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        let saved = try contents(of: downloads)
        XCTAssertEqual(saved.count, post.media.count)
        for (index, kind) in post.kinds.enumerated() {
            // Named after what arrived: the images came as WebP.
            let ending = " [SYNmixed0001] #\(index + 1).\(kind == "video" ? "mp4" : "webp")"
            XCTAssertEqual(saved.filter { $0.hasSuffix(ending) }.count, 1, ending)
        }
        XCTAssertEqual(item.imageCount, post.kinds.filter { $0 == "image" }.count)
        XCTAssertEqual(item.videoCount, post.kinds.filter { $0 == "video" }.count)
        XCTAssertEqual(item.mediaCategory, .mixed)
        XCTAssertEqual(item.outputPath.map { URL(fileURLWithPath: $0).pathExtension }, "mp4")
    }

    func testQuotedMediaIsNamedAfterItsOriginalAuthor() async throws {
        let post = try fixture("threads_quote_with_video.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        StubProtocol.set(mp4(), for: post.media[0])
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        let saved = try contents(of: downloads)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].hasPrefix("Other Person - "), saved[0])
        XCTAssertTrue(saved[0].hasSuffix(" [SYNquoted001].mp4"), saved[0])
    }

    // MARK: - Re-download

    func testFilesAlreadyOnDiskAreNotRequestedAgain() async throws {
        let post = try fixture("threads_image_carousel.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        for address in post.media { StubProtocol.set(jpeg(), for: address) }
        let first = DownloadItem(url: post.link)
        let firstRun = await ThreadsService.run(item: first, outputDirectory: downloads, session: stubSession())
        XCTAssertTrue(firstRun)
        let saved = try contents(of: downloads)
        XCTAssertEqual(saved.count, post.media.count)

        let second = DownloadItem(url: post.link)
        let secondRun = await ThreadsService.run(item: second, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(secondRun)
        XCTAssertEqual(second.status, .completed)
        XCTAssertEqual(try contents(of: downloads), saved)
        XCTAssertEqual(second.imageCount, post.media.count)
        // The post is resolved afresh every run; the files are not fetched twice.
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 2)
        for address in post.media {
            XCTAssertEqual(StubProtocol.requests(to: address).count, 1)
        }
    }

    // MARK: - Partial and failed downloads

    func testPartialResultSaysHowManyAreSavedAndKeepsThem() async throws {
        let post = try fixture("threads_image_carousel.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        for address in post.media { StubProtocol.set(jpeg(), for: address) }
        StubProtocol.set(.init(status: 404, headers: [:], body: Data()), for: try XCTUnwrap(post.media.last))
        let item = DownloadItem(url: post.link)
        item.emptySuccessFailure = true

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        let count = post.media.count
        XCTAssertEqual(
            item.status, .failed("Saved \(count - 1) of \(count) files — the server returned HTTP 404. Retry fetches the rest."))
        XCTAssertEqual(try contents(of: downloads).count, count - 1)
        XCTAssertEqual(item.imageCount, count - 1)
        XCTAssertNotNil(item.outputPath)
        XCTAssertNotNil(item.title)
        XCTAssertNil(item.speed)
        XCTAssertFalse(item.emptySuccessFailure, "a partial result must not be re-run automatically")
    }

    func testRefusedMediaAddressResolvesThePostAgainOnce() async throws {
        let post = try fixture("threads_single_image.html")
        let fresh = try freshAddress(for: post)
        StubProtocol.set([page(post.html), page(fresh.html)], for: post.pageURL)
        StubProtocol.set(.init(status: 403, headers: [:], body: Data("expired".utf8)), for: post.media[0])
        StubProtocol.set(jpeg(), for: fresh.address)
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try contents(of: downloads).count, 1)
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 2)
        XCTAssertEqual(StubProtocol.requests(to: post.media[0]).count, 1)
        XCTAssertEqual(StubProtocol.requests(to: fresh.address).count, 1)
    }

    func testMediaRefusedTwiceFailsWithoutAThirdTry() async throws {
        let post = try fixture("threads_single_image.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        StubProtocol.set(.init(status: 403, headers: [:], body: Data("refused".utf8)), for: post.media[0])
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(
            item.status,
            .failed("None of this post's files could be saved — the server returned HTTP 403. Retry fetches them again."))
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 2)
        XCTAssertEqual(StubProtocol.requests(to: post.media[0]).count, 2)
        XCTAssertNil(item.outputPath)
        XCTAssertFalse(item.emptySuccessFailure)
    }

    // MARK: - Failures before any download

    func testProfileLinkIsTurnedDownWithoutAnyRequest() async throws {
        let links = [
            "https://www.threads.com/@someone.invented",
            "https://www.threads.com/",
            "https://www.threads.com/search?q=cats",
            "https://www.threads.com/@someone.invented/replies",
        ]
        for link in links {
            XCTAssertEqual(SiteRegistry.profile(for: link).id, "threads", link)
            let item = DownloadItem(url: link)
            item.emptySuccessFailure = true

            let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

            XCTAssertFalse(finished)
            XCTAssertEqual(item.status, .failed(ThreadsService.notAPostLinkMessage), link)
            XCTAssertFalse(item.emptySuccessFailure)
            XCTAssertEqual(StubProtocol.requests(to: try XCTUnwrap(URL(string: link))).count, 0, link)
        }
        XCTAssertEqual(try contents(of: downloads), [])
    }

    func testEveryPageFailureSetsItsOwnMessage() async throws {
        let cases: [(fixture: String, message: String, retriedOnce: Bool)] = [
            ("threads_fail_restricted_audience.html", ThreadsService.restrictedMessage, false),
            ("threads_fail_blocked_shell_404.html", ThreadsService.blockedShellMessage, false),
            ("threads_text_only.html", ThreadsService.noMediaMessage, false),
            ("threads_gif_placeholder.html", ThreadsService.noMediaMessage, false),
            ("threads_link_card_only.html", ThreadsService.noMediaMessage, false),
        ]
        for entry in cases {
            let post = try fixture(entry.fixture)
            StubProtocol.set(page(post.html), for: post.pageURL)
            let item = DownloadItem(url: post.link)
            // Whatever an earlier attempt left must not survive.
            item.status = .failed("an earlier message")
            item.emptySuccessFailure = true
            item.eta = "5 minutes (rate limited)"

            let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

            XCTAssertFalse(finished, entry.fixture)
            XCTAssertEqual(item.status, .failed(entry.message), entry.fixture)
            XCTAssertEqual(item.emptySuccessFailure, entry.retriedOnce, entry.fixture)
            XCTAssertNil(item.eta, entry.fixture)
            XCTAssertNil(item.outputPath, entry.fixture)
        }
        XCTAssertEqual(try contents(of: downloads), [])
    }

    func testPageWithoutPostDataArmsTheOneAutomaticRetry() async throws {
        let post = try fixture("threads_single_image.html")
        StubProtocol.set(page("<html><head><title>Threads</title></head><body>initialRouteInfo</body></html>"), for: post.pageURL)
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(ThreadsService.noPostDataMessage))
        XCTAssertTrue(item.emptySuccessFailure)
        XCTAssertTrue(DownloadManager.shouldAutoRetryEmptySuccess(item))
    }

    func testOnlyTheTwoPassingAnswersAreRetriedAutomatically() {
        let transient = ThreadsService.Failure.allCases.filter(ThreadsService.mayBeTransient)
        XCTAssertEqual(Set(transient), [.notFound, .noPostData])
    }

    func testUnreachablePageNamesTheReason() async throws {
        let post = try fixture("threads_single_image.html")
        let item = DownloadItem(url: post.link)

        // Nothing is stubbed: the request fails before any answer.
        let unreachable = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())
        XCTAssertFalse(unreachable)
        XCTAssertEqual(
            item.status,
            .failed("Couldn't load the post from Threads — a network error interrupted the transfer. Check the connection, then Retry."))
        XCTAssertFalse(item.emptySuccessFailure)

        StubProtocol.set(.init(status: 429, headers: [:], body: Data()), for: post.pageURL)
        let limited = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())
        XCTAssertFalse(limited)
        XCTAssertEqual(
            item.status,
            .failed("Couldn't load the post from Threads — the server returned HTTP 429. Check the connection, then Retry."))
        XCTAssertEqual(try contents(of: downloads), [])
    }

    // MARK: - Cancel

    func testCancelSavesNothingAndClaimsNoOutcome() async throws {
        let post = try fixture("threads_single_video.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        var stalled = mp4()
        stalled.ending = .never
        StubProtocol.set(stalled, for: post.media[0])
        let item = DownloadItem(url: post.link)
        let session = stubSession()
        let downloads: URL = downloads

        let task = Task { @MainActor in
            await ThreadsService.run(item: item, outputDirectory: downloads, session: session)
        }
        for _ in 0..<500 where item.status != .downloading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(item.status, .downloading, "the transfer never started")
        task.cancel()
        let finished = await task.value

        XCTAssertFalse(finished)
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertNotEqual(item.status, .completed)
        if case .failed(let message) = item.status { XCTFail("a cancel is not a failure: \(message)") }
        XCTAssertNil(item.outputPath)
    }

    // MARK: - Helpers

    private struct Post {
        let link: String
        let pageURL: URL
        let html: String
        /// Media addresses in post order, as the manifest expects them.
        let media: [URL]
        let kinds: [String]
    }

    private struct ManifestEntry: Decodable {
        struct Media: Decodable {
            let type: String
            let url: String
        }

        let link: String
        let fixture: String
        let expect_media: [Media]
    }

    private func fixtureFile(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent(name)
    }

    private func fixture(_ name: String) throws -> Post {
        let manifest = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: fixtureFile("manifest.json")))
        let entry = try XCTUnwrap(manifest.first { $0.fixture == name }, "no manifest entry for \(name)")
        let link = try XCTUnwrap(ThreadsService.parseLink(entry.link))
        return Post(
            link: entry.link,
            pageURL: try XCTUnwrap(ThreadsService.canonicalURL(for: link)),
            html: try String(contentsOf: fixtureFile(name), encoding: .utf8),
            media: try entry.expect_media.map { try XCTUnwrap(URL(string: $0.url)) },
            kinds: entry.expect_media.map(\.type))
    }

    /// The same page with its one media file at another address, as a second
    /// resolve of a post returns it.
    private func freshAddress(for post: Post) throws -> (html: String, address: URL) {
        let old = "img_SYNimage0001_n"
        let new = "img_SYNimage0001_fresh_n"
        XCTAssertTrue(post.html.contains(old))
        let address = try XCTUnwrap(URL(string: post.media[0].absoluteString.replacingOccurrences(of: old, with: new)))
        XCTAssertNotEqual(address, post.media[0])
        return (post.html.replacingOccurrences(of: old, with: new), address)
    }

    private func page(_ html: String) -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    private func jpeg() -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 3, count: 2_000))
    }

    private func webp() -> StubProtocol.Stub {
        .init(
            status: 200, headers: ["Content-Type": "image/webp"],
            body: Data("RIFF".utf8) + Data([0x24, 0x00, 0x00, 0x00]) + Data("WEBPVP8 ".utf8) + Data(repeating: 5, count: 2_000))
    }

    private func mp4() -> StubProtocol.Stub {
        .init(
            status: 200, headers: ["Content-Type": "video/mp4"],
            body: Data([0x00, 0x00, 0x00, 0x20]) + Data("ftypisom".utf8) + Data(repeating: 9, count: 200_000))
    }

    private func stubSession() -> URLSession {
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
