import XCTest

@testable import XDownloader

/// YouTube community posts: which links are posts, how the page's data is
/// read, the original-size picture address, routing, the row's stored link,
/// and `YouTubePostService.run` from link to files on disk. The page data is
/// a synthetic fixture; requests are answered by a URLProtocol stub, so
/// nothing here touches the network.
@MainActor
final class YouTubePostTests: XCTestCase {

    private var downloads: URL!

    override func setUpWithError() throws {
        downloads = FileManager.default.temporaryDirectory.appendingPathComponent("YouTubePostTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: downloads)
    }

    private let postID = "UgkxSYNpost0000multi0000000000000000"

    // MARK: - Links

    func testPostLinksAreRecognisedWithTheirId() {
        let id = "Ugkx52a18BnjVlQMiW4AWA4F4fYeTxeVc-ZO"
        for link in [
            "https://youtube.com/post/\(id)?surface=shorts&data=AaErhFztqPYTVEiWklolcZAkVWpg",
            "https://www.youtube.com/post/\(id)",
            "https://m.youtube.com/post/\(id)/",
            "http://WWW.YouTube.com/post/\(id)",
            "https://www.youtube.com/channel/UCNDQLfRxar5biUYLED_UI9A/community?lb=\(id)",
            "https://www.youtube.com/@itsmstomato/community?lb=\(id)",
        ] {
            XCTAssertEqual(YouTubePostService.postID(of: link), id, link)
        }
    }

    func testOtherLinksAreNotPosts() {
        for link in [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/@itsmstomato/community",
            "https://www.youtube.com/@itsmstomato/posts",
            "https://www.youtube.com/post/",
            "https://www.youtube.com/post/abc",
            "https://notyoutube.com/post/Ugkx52a18BnjVlQMiW4AWA4F4fYeTxeVc-ZO",
            "https://example.com/?u=https://www.youtube.com/post/Ugkx52a18BnjVlQMiW4AWA4F4fYeTxeVc-ZO",
            "https://youtu.be/dQw4w9WgXcQ",
        ] {
            XCTAssertNil(YouTubePostService.postID(of: link), link)
        }
    }

    func testPostLinksRouteToTheResolverAndSkipYtDlp() {
        let profile = SiteRegistry.profile(for: "https://youtube.com/post/\(postID)?surface=shorts")
        XCTAssertEqual(profile.id, SiteRegistry.youtubePost.id)
        XCTAssertFalse(profile.usesYtDlp)
        XCTAssertEqual(profile.fallbacks.count, 1)
        XCTAssertFalse(profile.fallbacks.contains { $0.needsExternalTool })
        // Every other YouTube link stays with yt-dlp.
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ").id, SiteRegistry.youtube.id)
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.youtube.com/@someone/community").id, SiteRegistry.youtube.id)
    }

    func testStoredLinkDropsTheShareQueryAndTabSpelling() {
        let canonical = "https://www.youtube.com/post/\(postID)"
        XCTAssertEqual(DownloadManager.storedLink("https://youtube.com/post/\(postID)?surface=shorts&data=AaErhF"), canonical)
        XCTAssertEqual(DownloadManager.storedLink("https://www.youtube.com/@someone/community?lb=\(postID)"), canonical)
        XCTAssertEqual(DownloadManager.storedLink(canonical), canonical)
    }

    // MARK: - Original size

    func testThumbnailAddressIsRewrittenToTheOriginal() {
        XCTAssertEqual(
            YouTubePostService.fullSizeAddress("https://yt3.ggpht.com/LM5cdZpd_x-Y=s288-c-fcrop64=1,00001990ffffe66f-rw-nd-v1")?.absoluteString,
            "https://yt3.ggpht.com/LM5cdZpd_x-Y=s0")
        XCTAssertEqual(
            YouTubePostService.fullSizeAddress("//yt3.googleusercontent.com/abc_DEF=s1080")?.absoluteString,
            "https://yt3.googleusercontent.com/abc_DEF=s0")
        XCTAssertEqual(
            YouTubePostService.fullSizeAddress("https://yt3.ggpht.com/abcDEF")?.absoluteString,
            "https://yt3.ggpht.com/abcDEF=s0")
    }

    func testThumbnailOnAnotherHostIsNotUsed() {
        XCTAssertNil(YouTubePostService.fullSizeAddress("https://example.com/abc=s288"))
        XCTAssertNil(YouTubePostService.fullSizeAddress("https://ggpht.com.example.com/abc=s288"))
        XCTAssertNil(YouTubePostService.fullSizeAddress("http://yt3.ggpht.com/abc=s288"))
    }

    // MARK: - Reading the page

    func testMultiImagePostResolvesEveryPictureAtOriginalSize() throws {
        let post = try XCTUnwrap(try? YouTubePostService.resolve(initialData: fixtureData(), postID: postID).get())
        XCTAssertEqual(post.author, "Example Channel")
        XCTAssertEqual(post.text, "Two pictures\nfrom the studio #example")
        XCTAssertEqual(
            post.pictures.map(\.absoluteString),
            ["https://yt3.ggpht.com/SYNimageAAAA_one=s0", "https://yt3.ggpht.com/SYNimageBBBB-two=s0"])
        XCTAssertNil(post.videoID)
    }

    func testInitialDataIsCutFromThePageScript() throws {
        let json = try String(contentsOf: fixtureURL(), encoding: .utf8)
        let html =
            "<html><script nonce=\"x\">var ytInitialData = \(json);var other = {\"a\": \"}\"};</script></html>"
        guard case .success(let post) = YouTubePostService.resolve(html: html, postID: postID) else {
            return XCTFail("the page did not resolve")
        }
        XCTAssertEqual(post.pictures.count, 2)
    }

    func testBalancedObjectRespectsBracesInsideStrings() {
        let text = "x = {\"a\": \"} {\", \"b\": {\"c\": \"\\\"}\"}};trailing}"
        let start = text.index(text.startIndex, offsetBy: 4)
        XCTAssertEqual(
            YouTubePostService.balancedObject(in: text, from: start).map(String.init),
            "{\"a\": \"} {\", \"b\": {\"c\": \"\\\"}\"}}")
    }

    func testSingleImagePost() {
        let data = page(post: [
            "postId": postID,
            "authorText": ["runs": [["text": "Solo"]]],
            "backstageAttachment": [
                "backstageImageRenderer": ["image": ["thumbnails": [["url": "https://yt3.ggpht.com/ONE=s400"]]]]
            ],
        ])
        guard case .success(let post) = YouTubePostService.resolve(initialData: data, postID: postID) else {
            return XCTFail("did not resolve")
        }
        XCTAssertEqual(post.pictures.map(\.absoluteString), ["https://yt3.ggpht.com/ONE=s0"])
        XCTAssertEqual(post.author, "Solo")
    }

    func testVideoPostHandsOverTheVideoId() {
        let data = page(post: [
            "postId": postID,
            "backstageAttachment": ["videoRenderer": ["videoId": "dQw4w9WgXcQ"]],
        ])
        guard case .success(let post) = YouTubePostService.resolve(initialData: data, postID: postID) else {
            return XCTFail("did not resolve")
        }
        XCTAssertTrue(post.pictures.isEmpty)
        XCTAssertEqual(post.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubePostService.watchLink(for: "dQw4w9WgXcQ"), "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testSharedPostTakesTheOriginalPostsPictures() {
        let data: [String: Any] = [
            "contents": [
                "sharedPostRenderer": [
                    "postId": postID,
                    "originalPost": [
                        "backstagePostRenderer": [
                            "postId": "UgkxSYNoriginal00000000000000000000",
                            "authorText": ["runs": [["text": "Original Author"]]],
                            "backstageAttachment": [
                                "backstageImageRenderer": ["image": ["thumbnails": [["url": "https://yt3.ggpht.com/ORIG=s400"]]]]
                            ],
                        ]
                    ],
                ]
            ]
        ]
        guard case .success(let post) = YouTubePostService.resolve(initialData: data, postID: postID) else {
            return XCTFail("did not resolve")
        }
        XCTAssertEqual(post.pictures.map(\.absoluteString), ["https://yt3.ggpht.com/ORIG=s0"])
        XCTAssertEqual(post.author, "Original Author")
    }

    func testTextAndPollPostsHaveNoMedia() {
        let text = page(post: ["postId": postID, "contentText": ["runs": [["text": "hello"]]]])
        XCTAssertEqual(failure(YouTubePostService.resolve(initialData: text, postID: postID)), .noMedia)
        let poll = page(post: ["postId": postID, "backstageAttachment": ["pollRenderer": ["choices": []]]])
        XCTAssertEqual(failure(YouTubePostService.resolve(initialData: poll, postID: postID)), .noMedia)
        XCTAssertEqual(
            YouTubePostService.message(for: .noMedia), "This YouTube post has no pictures or video — text and polls can't be downloaded.")
    }

    func testPageWithoutPostOrDataFails() {
        XCTAssertEqual(failure(YouTubePostService.resolve(initialData: ["contents": [:]], postID: postID)), .notFound)
        XCTAssertEqual(failure(YouTubePostService.resolve(html: "<html>consent</html>", postID: postID)), .noPageData)
    }

    // MARK: - Running a download

    func testMultiImagePostSavesBothPicturesIntoItsOwnFolder() async throws {
        let json = try String(contentsOf: fixtureURL(), encoding: .utf8)
        let pageURL = try XCTUnwrap(YouTubePostService.pageURL(for: postID))
        StubProtocol.set(htmlStub("<script>var ytInitialData = \(json);</script>"), for: pageURL)
        StubProtocol.set(pngStub(), for: try XCTUnwrap(URL(string: "https://yt3.ggpht.com/SYNimageAAAA_one=s0")))
        StubProtocol.set(pngStub(), for: try XCTUnwrap(URL(string: "https://yt3.ggpht.com/SYNimageBBBB-two=s0")))
        let item = DownloadItem(url: "https://youtube.com/post/\(postID)?surface=shorts&data=Aa")

        let finished = await YouTubePostService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.imageCount, 2)
        XCTAssertEqual(item.mediaCategory, .image)
        let folders = try FileManager.default.contentsOfDirectory(atPath: downloads.path)
        XCTAssertEqual(folders.count, 1)
        XCTAssertTrue(folders[0].hasPrefix("Example Channel - "), folders[0])
        XCTAssertTrue(folders[0].hasSuffix("[\(postID)]"), folders[0])
        let files = try FileManager.default.contentsOfDirectory(atPath: downloads.appendingPathComponent(folders[0]).path).sorted()
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].hasSuffix(" #1.png"), files[0])
        XCTAssertTrue(files[1].hasSuffix(" #2.png"), files[1])
        // The page is asked for logged out, with the consent cookie only.
        let request = try XCTUnwrap(StubProtocol.requests(to: pageURL).first)
        XCTAssertEqual(request.allHTTPHeaderFields, YouTubePostService.pageHeaders)
        XCTAssertEqual(request.httpShouldHandleCookies, false)
    }

    func testVideoPostIsHandedToTheVideoDownload() async throws {
        let pageURL = try XCTUnwrap(YouTubePostService.pageURL(for: postID))
        let data = try JSONSerialization.data(
            withJSONObject: page(post: ["postId": postID, "backstageAttachment": ["videoRenderer": ["videoId": "dQw4w9WgXcQ"]]]))
        StubProtocol.set(htmlStub("<script>var ytInitialData = \(String(decoding: data, as: UTF8.self));</script>"), for: pageURL)
        let item = DownloadItem(url: "https://www.youtube.com/post/\(postID)")
        var handed: [String] = []

        let finished = await YouTubePostService.run(
            item: item, outputDirectory: downloads, session: stubSession(),
            video: { link in
                handed.append(link)
                return true
            })

        XCTAssertTrue(finished)
        XCTAssertEqual(handed, ["https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
    }

    func testTextPostFailsWithItsOwnMessage() async throws {
        let pageURL = try XCTUnwrap(YouTubePostService.pageURL(for: postID))
        let data = try JSONSerialization.data(withJSONObject: page(post: ["postId": postID]))
        StubProtocol.set(htmlStub("<script>var ytInitialData = \(String(decoding: data, as: UTF8.self));</script>"), for: pageURL)
        let item = DownloadItem(url: "https://www.youtube.com/post/\(postID)")

        let finished = await YouTubePostService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(YouTubePostService.noMediaMessage))
    }

    // MARK: - Page shapes and the second request

    func testDataWrittenAsEscapedStringOrOnWindowIsRead() throws {
        let data = try JSONSerialization.data(
            withJSONObject: page(post: ["postId": postID, "backstageAttachment": ["videoRenderer": ["videoId": "dQw4w9WgXcQ"]]]))
        let json = String(decoding: data, as: UTF8.self)
        // As some pages write it: every character a \xHH escape.
        let hexEscaped = json.utf8.map { String(format: "\\x%02x", $0) }.joined()
        let quoted = json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        for html in [
            "<script>var ytInitialData = '\(hexEscaped)';</script>",
            "<script>ytInitialData = JSON.parse('\(hexEscaped)');</script>",
            "<script>window['ytInitialData'] = \(json);</script>",
            "<script>var ytInitialData='\(quoted)';</script>",
        ] {
            let post = try? YouTubePostService.resolve(html: html, postID: postID).get()
            XCTAssertEqual(post?.videoID, "dQw4w9WgXcQ", String(html.prefix(60)))
        }
    }

    func testQuotedStringDecodesEscapesAndSurrogatePairs() {
        let text = #"'a\x7bé\n\'\"🍅z' tail"#
        XCTAssertEqual(YouTubePostService.quotedString(in: text, from: text.startIndex), "a{é\n'\"🍅z")
        let open = "'never closes"
        XCTAssertNil(YouTubePostService.quotedString(in: open, from: open.startIndex))
    }

    func testPageWithoutDataIsAskedForOnceMoreAndBothAnswersAreKept() async throws {
        let json = try String(contentsOf: fixtureURL(), encoding: .utf8)
        let pageURL = try XCTUnwrap(YouTubePostService.pageURL(for: postID))
        StubProtocol.set(
            [htmlStub("<html>no data here</html>"), htmlStub("<script>var ytInitialData = \(json);</script>")], for: pageURL)
        StubProtocol.set(pngStub(), for: try XCTUnwrap(URL(string: "https://yt3.ggpht.com/SYNimageAAAA_one=s0")))
        StubProtocol.set(pngStub(), for: try XCTUnwrap(URL(string: "https://yt3.ggpht.com/SYNimageBBBB-two=s0")))
        let item = DownloadItem(url: "https://www.youtube.com/post/\(postID)")
        let saved = YouTubePostService.retryPause
        YouTubePostService.retryPause = 0
        defer { YouTubePostService.retryPause = saved }
        let trail = DiagnosticTrail()

        let finished = await DiagnosticTrail.$current.withValue(trail) {
            await YouTubePostService.run(item: item, outputDirectory: downloads, session: stubSession())
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(StubProtocol.requests(to: pageURL).count, 2)
        let pages = trail.exchanges.filter { $0.label == "youtube-post-page" }
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.first?.body.map { String(decoding: $0, as: UTF8.self) }, "<html>no data here</html>")
        XCTAssertEqual(pages.first?.status, 200)
        XCTAssertEqual(pages.first?.finalURL, pageURL.absoluteString)
        // The fixed consent cookie is still a Cookie header: never kept.
        XCTAssertEqual(pages.first?.requestHeaders["Cookie"], DiagnosticRedaction.redacted)
    }

    func testPageWithoutDataTwiceFailsWithItsMessage() async throws {
        let pageURL = try XCTUnwrap(YouTubePostService.pageURL(for: postID))
        StubProtocol.set(htmlStub("<html>no data here</html>"), for: pageURL)
        let item = DownloadItem(url: "https://www.youtube.com/post/\(postID)")
        let saved = YouTubePostService.retryPause
        YouTubePostService.retryPause = 0
        defer { YouTubePostService.retryPause = saved }

        let finished = await YouTubePostService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(YouTubePostService.noPageDataMessage))
        XCTAssertEqual(StubProtocol.requests(to: pageURL).count, 2)
    }

    // MARK: - Helpers

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("youtube_post_multi_image.json")
    }

    private func fixtureData() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL())) as? [String: Any])
    }

    private func page(post: [String: Any]) -> [String: Any] {
        ["contents": ["backstagePostThreadRenderer": ["post": ["backstagePostRenderer": post]]]]
    }

    private func failure(_ result: Result<YouTubePostService.Post, YouTubePostService.Failure>) -> YouTubePostService.Failure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    private func htmlStub(_ html: String) -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    private func pngStub() -> StubProtocol.Stub {
        .init(
            status: 200, headers: ["Content-Type": "image/png"],
            body: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 1, count: 2_000))
    }

    private func stubSession() -> URLSession {
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}
