import XCTest

@testable import XDownloader

@MainActor
final class XiaohongshuServiceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("XiaohongshuServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    func testOpenGraphVideoIsResolvedAsVideo() throws {
        let note = try XCTUnwrap(
            XiaohongshuService.resolveOpenGraph(
                html: #"""
                    <meta property="og:title" content="Video note - 小红书">
                    <meta property="og:description" content="Caption">
                    <meta property="og:video" content="http://sns-video-qc.xhscdn.com/clip.mp4">
                    <meta property="og:image" content="http://sns-webpic-qc.xhscdn.com/cover.jpg">
                    """#, id: "12345678"))

        XCTAssertEqual(note.title, "Video note")
        XCTAssertEqual(note.text, "Caption")
        XCTAssertEqual(note.media.map(\.kind), [.video])
        XCTAssertEqual(note.media.first?.url.absoluteString, "https://sns-video-qc.xhscdn.com/clip.mp4")
    }

    func testLoginRedirectHandsOriginalShortLinkToSignedInVideoFallback() async throws {
        let shortLink = "http://xhslink.com/o/4kGLPgVk0OB"
        let loginURL = URL(string: "https://www.xiaohongshu.com/login?redirectPath=%2Fdiscovery%2Fitem%2F12345678")!
        StubProtocol.set(.redirect(to: loginURL), for: URL(string: shortLink)!)
        StubProtocol.set(.init(status: 200, headers: [:], body: Data("<html>Sign in</html>".utf8)), for: loginURL)

        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let item = DownloadItem(url: shortLink)
        var receivedLink: String?
        let succeeded = await XiaohongshuService.run(item: item, outputDirectory: root, session: session) { link in
            receivedLink = link
            return true
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(receivedLink, shortLink)
        XCTAssertTrue(XiaohongshuService.isLoginPage(loginURL))
        XCTAssertFalse(XiaohongshuService.isLoginPage(URL(string: "https://www.xiaohongshu.com/explore/12345678")))
    }
}
