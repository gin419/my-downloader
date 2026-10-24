import XCTest

@testable import XDownloader

/// Pixiv artworks: which links are artworks, how the API's answers are read,
/// routing, and `PixivService.run` from id to files on disk. Requests are
/// answered by a URLProtocol stub, so nothing here touches the network.
@MainActor
final class PixivServiceTests: XCTestCase {

    private var downloads: URL!

    override func setUpWithError() throws {
        downloads = FileManager.default.temporaryDirectory.appendingPathComponent("PixivServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: downloads)
    }

    // MARK: - Links

    func testArtworkLinksAreRecognised() {
        for link in [
            "https://www.pixiv.net/en/artworks/151217762",
            "https://www.pixiv.net/artworks/151217762",
            "http://pixiv.net/artworks/151217762/",
            "https://www.pixiv.net/zh-tw/artworks/151217762?utm_source=x",
            "https://www.pixiv.net/i/151217762",
            "https://www.pixiv.net/member_illust.php?mode=medium&illust_id=151217762",
            "https://touch.pixiv.net/artworks/151217762",
        ] {
            XCTAssertEqual(PixivService.artworkID(of: link), "151217762", link)
        }
    }

    func testOtherLinksAreNotArtworks() {
        for link in [
            "https://www.pixiv.net/en/users/99199972",
            "https://www.pixiv.net/novel/show.php?id=123",
            "https://www.pixiv.net/artworks/abc",
            "https://www.pixiv.net/artworks/",
            "https://notpixiv.net/artworks/151217762",
            "https://i.pximg.net/img-original/img/2026/10/24/16/31/23/151217762_p0.png",
            "https://example.com/?u=https://www.pixiv.net/artworks/151217762",
        ] {
            XCTAssertNil(PixivService.artworkID(of: link), link)
        }
    }

    func testFirstArtworkInPostText() {
        let text = "Do you like what I do? 🎶\n\n#art #fanart\n\nhttps://www.pixiv.net/en/artworks/151217762"
        XCTAssertEqual(PixivService.firstArtworkID(in: text), "151217762")
        XCTAssertNil(PixivService.firstArtworkID(in: "just text https://www.youtube.com/@someone"))
    }

    func testArtworkLinksRouteToTheResolverAndSkipYtDlp() {
        let profile = SiteRegistry.profile(for: "https://www.pixiv.net/en/artworks/151217762")
        XCTAssertEqual(profile.id, SiteRegistry.pixiv.id)
        XCTAssertFalse(profile.usesYtDlp)
        XCTAssertFalse(profile.fallbacks.contains { $0.needsExternalTool })
        // A user page is not an artwork: it stays with the generic route.
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.pixiv.net/en/users/99199972").id, SiteRegistry.other.id)
    }

    func testStoredLinkIsTheCanonicalArtworkLink() {
        XCTAssertEqual(
            DownloadManager.storedLink("https://www.pixiv.net/en/artworks/151217762?utm_source=x"),
            "https://www.pixiv.net/artworks/151217762")
    }

    // MARK: - Reading the answers

    func testPagesAnswerGivesEveryOriginal() {
        let json = pagesJSON([
            "https://i.pximg.net/img-original/img/2026/01/01/00/00/00/1_p0.png", "https://i.pximg.net/img-original/img/2026/01/01/00/00/00/1_p1.jpg",
        ])
        XCTAssertEqual(
            try? PixivService.readPages(json).get().map(\.absoluteString),
            [
                "https://i.pximg.net/img-original/img/2026/01/01/00/00/00/1_p0.png",
                "https://i.pximg.net/img-original/img/2026/01/01/00/00/00/1_p1.jpg",
            ])
    }

    func testPagesAnswerErrorOrEmptyHasNoPages() {
        XCTAssertEqual(failure(PixivService.readPages(["error": true, "message": "", "body": []])), .noPages)
        XCTAssertEqual(failure(PixivService.readPages(["error": false, "body": []])), .noPages)
    }

    func testAddressOffPixivsFileHostIsNotUsed() {
        let json = pagesJSON(["https://example.com/1_p0.png", "http://i.pximg.net/1_p0.png"])
        XCTAssertEqual(failure(PixivService.readPages(json)), .changedFormat)
    }

    func testMissingPagesAreToldApartByTheArtworksRecord() {
        XCTAssertEqual(PixivService.classifyMissingPages(info: ["error": true, "message": "", "body": []]), .notFound)
        XCTAssertEqual(
            PixivService.classifyMissingPages(info: ["error": false, "body": ["illustId": "1", "xRestrict": 1]]), .needsSignIn)
    }

    func testDetailsNameTheAuthorAndTitle() {
        XCTAssertEqual(
            PixivService.readDetails(["error": false, "body": ["userName": "Aaronier0O", "illustTitle": "Kafka"]]),
            .init(author: "Aaronier0O", title: "Kafka"))
        XCTAssertEqual(PixivService.readDetails(["error": false, "body": ["illustTitle": "x"]])?.author, "pixiv")
        XCTAssertNil(PixivService.readDetails(["error": true, "body": []]))
    }

    // MARK: - Running a download

    func testSinglePageArtworkIsSavedWithTheReferer() async throws {
        let original = try XCTUnwrap(URL(string: "https://i.pximg.net/img-original/img/2026/10/24/16/31/23/151217762_p0.png"))
        StubProtocol.set(json(pagesJSON([original.absoluteString])), for: PixivService.pagesURL(for: "151217762"))
        StubProtocol.set(
            json(["error": false, "body": ["userName": "Example Artist", "illustTitle": "Kafka"]]), for: PixivService.infoURL(for: "151217762"))
        StubProtocol.set(png(), for: original)
        let item = DownloadItem(url: "https://www.pixiv.net/en/artworks/151217762")

        let finished = await PixivService.run(item: item, artworkID: "151217762", outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.imageCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), ["Example Artist - Kafka [151217762].png"])
        XCTAssertEqual(item.title, "Example Artist - Kafka")
        let fileRequest = try XCTUnwrap(StubProtocol.requests(to: original).first)
        XCTAssertEqual(fileRequest.value(forHTTPHeaderField: "Referer"), "https://www.pixiv.net/")
        XCTAssertNil(fileRequest.value(forHTTPHeaderField: "Cookie"))
    }

    func testMultiPageArtworkGetsItsOwnFolder() async throws {
        let first = try XCTUnwrap(URL(string: "https://i.pximg.net/img-original/img/2026/01/01/00/00/00/42_p0.jpg"))
        let second = try XCTUnwrap(URL(string: "https://i.pximg.net/img-original/img/2026/01/01/00/00/00/42_p1.jpg"))
        StubProtocol.set(json(pagesJSON([first.absoluteString, second.absoluteString])), for: PixivService.pagesURL(for: "42"))
        StubProtocol.set(json(["error": false, "body": ["userName": "A", "illustTitle": "T"]]), for: PixivService.infoURL(for: "42"))
        StubProtocol.set(jpeg(), for: first)
        StubProtocol.set(jpeg(), for: second)
        let item = DownloadItem(url: "https://www.pixiv.net/artworks/42")

        let finished = await PixivService.run(item: item, artworkID: "42", outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), ["A - T [42]"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: downloads.appendingPathComponent("A - T [42]").path).sorted(),
            ["A - T [42] #1.jpg", "A - T [42] #2.jpg"])
    }

    func testRestrictedArtworkSaysItNeedsSignIn() async {
        StubProtocol.set(json(["error": true, "message": "", "body": []]), for: PixivService.pagesURL(for: "7"))
        StubProtocol.set(json(["error": false, "body": ["illustId": "7", "xRestrict": 1]]), for: PixivService.infoURL(for: "7"))
        let item = DownloadItem(url: "https://www.pixiv.net/artworks/7")

        let finished = await PixivService.run(item: item, artworkID: "7", outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(PixivService.needsSignInMessage))
    }

    func testMissingArtworkSaysNotFound() async {
        var notFound = json(["error": true, "message": "", "body": []])
        notFound.status = 404
        StubProtocol.set(notFound, for: PixivService.pagesURL(for: "1"))
        StubProtocol.set(notFound, for: PixivService.infoURL(for: "1"))
        let item = DownloadItem(url: "https://www.pixiv.net/artworks/1")

        let finished = await PixivService.run(item: item, artworkID: "1", outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(PixivService.notFoundMessage))
    }

    // MARK: - Helpers

    private func pagesJSON(_ originals: [String]) -> [String: Any] {
        ["error": false, "message": "", "body": originals.map { ["urls": ["original": $0], "width": 10, "height": 10] }]
    }

    private func failure(_ result: Result<[URL], PixivService.Failure>) -> PixivService.Failure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    private func json(_ object: [String: Any]) -> StubProtocol.Stub {
        .init(
            status: 200, headers: ["Content-Type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func png() -> StubProtocol.Stub {
        .init(
            status: 200, headers: ["Content-Type": "image/png"],
            body: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 1, count: 2_000))
    }

    private func jpeg() -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 3, count: 2_000))
    }

    private func stubSession() -> URLSession {
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}
