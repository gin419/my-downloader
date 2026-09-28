import XCTest

@testable import XDownloader

/// `ThreadsService.run` from link to files on disk: what it requests, what it
/// leaves on the row at every exit, and that it never reports more than
/// happened, and that a post of two or more files keeps them in a folder
/// of its own. The pages are the synthetic fixtures; page and media requests
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
        // A test may have taken the folder's write permission away.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloads.path)
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
        // One file: loose in the download folder, as it always was.
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent(saved[0]).path)
        XCTAssertNil(item.destination)
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
        let folder = try postFolder()
        let saved = try contents(of: folder)
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
        XCTAssertEqual(item.outputPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }, folder.path)
    }

    func testCarouselGoesIntoAFolderNamedAfterItsFiles() async throws {
        let post = try fixture("threads_image_carousel.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        for address in post.media { StubProtocol.set(jpeg(), for: address) }
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        let folder = try postFolder()
        XCTAssertTrue(folder.lastPathComponent.hasSuffix(" [SYNcarousel1]"), folder.lastPathComponent)
        // The folder is the files' name without their number.
        let names = (1...post.media.count).map { "\(folder.lastPathComponent) #\($0).jpg" }
        XCTAssertEqual(try contents(of: folder), names)
        XCTAssertEqual(item.outputPath, folder.appendingPathComponent(names[0]).path)
        XCTAssertEqual(item.imageCount, post.media.count)
        XCTAssertEqual(item.destination?.path, folder.path)
        XCTAssertFalse(item.destinationExistedAtStart)
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
        let folder = try postFolder()
        let saved = try contents(of: folder)
        XCTAssertEqual(saved.count, post.media.count)

        let second = DownloadItem(url: post.link)
        let secondRun = await ThreadsService.run(item: second, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(secondRun)
        XCTAssertEqual(second.status, .completed)
        XCTAssertEqual(try postFolder(), folder)
        XCTAssertEqual(try contents(of: folder), saved)
        XCTAssertEqual(second.outputPath, first.outputPath)
        // The folder was there as the second run began.
        XCTAssertTrue(second.destinationExistedAtStart)
        XCTAssertEqual(second.imageCount, post.media.count)
        // The post is resolved afresh every run; the files are not fetched twice.
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 2)
        for address in post.media {
            XCTAssertEqual(StubProtocol.requests(to: address).count, 1)
        }
    }

    func testOnePostRunTwiceAtOnceEndsWithOneFileAndNoFailure() async throws {
        // Two rows for one post: both find the name free, both download,
        // and the second one to finish finds it taken.
        let post = try fixture("threads_single_video.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        var slow = mp4()
        slow.pieces = 2
        slow.pause = 0.3
        StubProtocol.set(slow, for: post.media[0])
        let first = DownloadItem(url: post.link)
        let second = DownloadItem(url: post.link)
        let session = stubSession()
        let downloads: URL = downloads

        let runs = [first, second].map { item in
            Task { @MainActor in await ThreadsService.run(item: item, outputDirectory: downloads, session: session) }
        }
        var finished: [Bool] = []
        for run in runs { finished.append(await run.value) }

        XCTAssertEqual(StubProtocol.requests(to: post.media[0]).count, 2, "the runs did not overlap")
        XCTAssertEqual(finished, [true, true])
        XCTAssertEqual(first.status, .completed)
        XCTAssertEqual(second.status, .completed)
        let saved = try contents(of: downloads)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(first.outputPath, saved.first.map { downloads.appendingPathComponent($0).path })
        XCTAssertEqual(second.outputPath, first.outputPath)
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
        XCTAssertEqual(try contents(of: postFolder()).count, count - 1)
        XCTAssertEqual(item.imageCount, count - 1)
        XCTAssertNotNil(item.outputPath)
        XCTAssertNotNil(item.title)
        XCTAssertNil(item.speed)
        XCTAssertFalse(item.emptySuccessFailure, "a partial result must not be re-run automatically")
        // Only a refused address (403) is worth resolving the post again.
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
        for address in post.media { XCTAssertEqual(StubProtocol.requests(to: address).count, 1) }
    }

    /// The folder follows the files the post declares, not the ones that
    /// arrived: the Retry finds what the first run saved and fetches only
    /// what is missing, into the same folder.
    func testRetryAfterAPartialResultFetchesOnlyTheMissingFileIntoTheSameFolder() async throws {
        let post = try fixture("threads_image_carousel.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        for address in post.media { StubProtocol.set(jpeg(), for: address) }
        let last = try XCTUnwrap(post.media.last)
        StubProtocol.set([.init(status: 404, headers: [:], body: Data()), jpeg()], for: last)
        let item = DownloadItem(url: post.link)
        let partial = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())
        XCTAssertFalse(partial)
        let folder = try postFolder()
        XCTAssertEqual(try contents(of: folder).count, post.media.count - 1)

        let retried = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(retried)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try postFolder(), folder)
        XCTAssertEqual(try contents(of: folder).count, post.media.count)
        XCTAssertEqual(item.imageCount, post.media.count)
        for address in post.media.dropLast() { XCTAssertEqual(StubProtocol.requests(to: address).count, 1) }
        XCTAssertEqual(StubProtocol.requests(to: last).count, 2)
    }

    /// The folder is made with the first file saved: a post none of whose
    /// files arrive leaves nothing behind.
    func testEveryFileFailingLeavesNoFolder() async throws {
        let post = try fixture("threads_image_carousel.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        for address in post.media { StubProtocol.set(.init(status: 404, headers: [:], body: Data()), for: address) }
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(
            item.status,
            .failed("None of this post's files could be saved — the server returned HTTP 404. Retry fetches them again."))
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertNil(item.outputPath)
    }

    func testRefusedFileInTheMiddleOfAPostIsFetchedFromTheFreshAddress() async throws {
        let post = try fixture("threads_image_carousel.html")
        XCTAssertEqual(post.media.count, 3)
        let fresh = try freshAddress(for: post, file: 1, named: "img_SYNc1b_n")
        StubProtocol.set([page(post.html), page(fresh.html)], for: post.pageURL)
        StubProtocol.set(jpeg(), for: post.media[0])
        StubProtocol.set(.init(status: 403, headers: [:], body: Data("expired".utf8)), for: post.media[1])
        StubProtocol.set(jpeg(), for: fresh.address)
        StubProtocol.set(jpeg(), for: post.media[2])
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        let saved = try contents(of: postFolder())
        XCTAssertEqual(saved.count, 3)
        for number in 1...3 {
            XCTAssertEqual(saved.filter { $0.hasSuffix(" [SYNcarousel1] #\(number).jpg") }.count, 1, "\(saved)")
        }
        XCTAssertEqual(item.imageCount, 3)
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 2)
        // The file saved before the refusal is not fetched a second time.
        XCTAssertEqual(StubProtocol.requests(to: post.media[0]).count, 1)
        XCTAssertEqual(StubProtocol.requests(to: post.media[1]).count, 1)
        XCTAssertEqual(StubProtocol.requests(to: fresh.address).count, 1)
        XCTAssertEqual(StubProtocol.requests(to: post.media[2]).count, 1)
    }

    func testFreshResolveWithAnotherFileCountIsNotMixedIntoTheRun() async throws {
        // The post changed between the two resolves (here: down to one
        // file). Its new list can't be matched to the files already saved,
        // and numbering against the new count would rename the rest.
        let post = try fixture("threads_image_carousel.html")
        let single = try fixture("threads_single_image.html")
        let changed = single.html.replacingOccurrences(of: "SYNimage0001", with: "SYNcarousel1")
        let changedAddress = try XCTUnwrap(
            URL(string: single.media[0].absoluteString.replacingOccurrences(of: "SYNimage0001", with: "SYNcarousel1")))
        guard case .success(let shorter) = ThreadsService.resolve(html: changed, finalURL: post.pageURL, code: "SYNcarousel1") else {
            return XCTFail("the changed page must resolve, or this test proves nothing")
        }
        XCTAssertEqual(shorter.media.map(\.url), [changedAddress])

        StubProtocol.set([page(post.html), page(changed)], for: post.pageURL)
        StubProtocol.set(jpeg(), for: post.media[0])
        StubProtocol.set(.init(status: 403, headers: [:], body: Data("expired".utf8)), for: post.media[1])
        StubProtocol.set(jpeg(), for: post.media[2])
        StubProtocol.set(jpeg(), for: changedAddress)
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed("Saved 2 of 3 files — the server returned HTTP 403. Retry fetches the rest."))
        let saved = try contents(of: postFolder())
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.filter { $0.hasSuffix(" [SYNcarousel1] #1.jpg") }.count, 1, "\(saved)")
        XCTAssertEqual(saved.filter { $0.hasSuffix(" [SYNcarousel1] #3.jpg") }.count, 1, "\(saved)")
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 2)
        XCTAssertEqual(StubProtocol.requests(to: post.media[1]).count, 1)
        XCTAssertEqual(StubProtocol.requests(to: changedAddress).count, 0)
    }

    func testUnwritableDownloadFolderIsNamedInsteadOfThePost() async throws {
        let post = try fixture("threads_image_carousel.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        for address in post.media { StubProtocol.set(jpeg(), for: address) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: downloads.path)
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(DirectDownload.diskUnwritableMessage))
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertNil(item.outputPath)
        XCTAssertNil(item.speed)
        XCTAssertFalse(item.emptySuccessFailure)
        // A local cause: asking Threads again can't help.
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
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

    func testRedirectedPageIsClassifiedByTheAddressItEndsAt() async throws {
        // Both pages answer HTTP 200 and neither holds a word about the
        // post: only the address the redirect ended at tells them apart.
        let cases: [(fixture: String, message: String, retriedOnce: Bool)] = [
            ("threads_fail_not_found_invalid_post.html", ThreadsService.notFoundMessage, true),
            ("threads_fail_login_redirect.html", ThreadsService.loginRequiredMessage, false),
        ]
        for entry in cases {
            let post = try fixture(entry.fixture)
            let landing = try XCTUnwrap(post.finalURL, entry.fixture)
            XCTAssertNotEqual(landing, post.pageURL, entry.fixture)
            StubProtocol.set(.redirect(to: landing), for: post.pageURL)
            StubProtocol.set(page(post.html), for: landing)
            let item = DownloadItem(url: post.link)
            item.emptySuccessFailure = !entry.retriedOnce

            let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

            XCTAssertFalse(finished, entry.fixture)
            XCTAssertEqual(item.status, .failed(entry.message), entry.fixture)
            XCTAssertEqual(item.emptySuccessFailure, entry.retriedOnce, entry.fixture)
            XCTAssertEqual(DownloadManager.shouldAutoRetryEmptySuccess(item), entry.retriedOnce, entry.fixture)
            XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1, entry.fixture)
            XCTAssertEqual(StubProtocol.requests(to: landing).count, 1, entry.fixture)
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

    func testCancelDuringTheFirstFileOfACarouselLeavesNoFolder() async throws {
        let post = try fixture("threads_image_carousel.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        for address in post.media { StubProtocol.set(jpeg(), for: address) }
        var stalled = jpeg()
        stalled.ending = .never
        StubProtocol.set(stalled, for: post.media[0])
        let item = DownloadItem(url: post.link)
        let session = stubSession()
        let downloads: URL = downloads

        let task = Task { @MainActor in
            await ThreadsService.run(item: item, outputDirectory: downloads, session: session)
        }
        for _ in 0..<500 where StubProtocol.requests(to: post.media[0]).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(StubProtocol.requests(to: post.media[0]).count, 1, "the transfer never started")
        task.cancel()
        let finished = await task.value

        XCTAssertFalse(finished)
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertNil(item.outputPath)
        for address in post.media.dropFirst() { XCTAssertTrue(StubProtocol.requests(to: address).isEmpty) }
    }

    // MARK: - Helpers

    private struct Post {
        let link: String
        let pageURL: URL
        let html: String
        /// Media addresses in post order, as the manifest expects them.
        let media: [URL]
        let kinds: [String]
        /// Where the manifest says the page request ends up, when it states it.
        let finalURL: URL?
    }

    private struct ManifestEntry: Decodable {
        struct Media: Decodable {
            let type: String
            let url: String
        }

        let link: String
        let final_url: String?
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
            kinds: entry.expect_media.map(\.type),
            finalURL: entry.final_url.flatMap(URL.init(string:)))
    }

    /// The same page with one media file at another address, as a second
    /// resolve of a post returns it. `name` is the part of that file's
    /// address that tells it from the post's other files.
    private func freshAddress(
        for post: Post, file index: Int = 0, named old: String = "img_SYNimage0001_n"
    ) throws -> (html: String, address: URL) {
        let new = old.replacingOccurrences(of: "_n", with: "_fresh_n")
        XCTAssertTrue(post.html.contains(old))
        let address = try XCTUnwrap(URL(string: post.media[index].absoluteString.replacingOccurrences(of: old, with: new)))
        XCTAssertNotEqual(address, post.media[index])
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

    /// The one folder a post of two or more files was saved into: the only
    /// entry of the download folder.
    private func postFolder() throws -> URL {
        let names = try contents(of: downloads)
        XCTAssertEqual(names.count, 1, "\(names)")
        let folder = downloads.appendingPathComponent(try XCTUnwrap(names.first), isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "\(folder.lastPathComponent) is not a folder")
        return folder
    }
}
