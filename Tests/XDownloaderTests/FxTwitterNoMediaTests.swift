import XCTest

@testable import XDownloader

/// The fxtwitter rescue for a tweet with no media of its own: a link to a
/// Pixiv artwork is followed, a tweet that is only text says so (and arms no
/// retry), and a tweet fxtwitter cannot see keeps the tools' own message —
/// "X returned no results … Retry later" stays for that case. Answers come
/// from the URLProtocol stub; every name and id is invented.
@MainActor
final class FxTwitterNoMediaTests: XCTestCase {

    private let id = "2113896359925338275"
    private var downloads: URL!

    override func setUpWithError() throws {
        downloads = FileManager.default.temporaryDirectory.appendingPathComponent("FxTwitterNoMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: downloads)
    }

    private let priorMessage = "No media found — X returned no results — the tweet may be temporarily limited or hidden. Retry later."

    // MARK: - Choosing the outcome

    func testPixivLinkInTheTextIsFollowed() {
        let tweet: [String: Any] = ["text": "❤️\nlisten on my channel 🎶\n\n#art\n\nhttps://www.pixiv.net/en/artworks/151217762"]
        XCTAssertEqual(FxTwitterService.noMediaOutcome(tweet: tweet), .pixivArtwork("151217762"))
    }

    func testTextOnlyTweetHasNoMedia() {
        XCTAssertEqual(
            FxTwitterService.noMediaOutcome(tweet: ["text": "good morning"]),
            .noMedia("This post has no pictures or video — only text, so there is nothing to download."))
    }

    func testTweetLinkingElsewhereNamesTheSite() {
        XCTAssertEqual(
            FxTwitterService.noMediaOutcome(tweet: ["text": "new video https://www.youtube.com/watch?v=abc https://x.com/a/status/1"]),
            .noMedia("This post has no pictures or video of its own — it links to youtube.com. Paste that link to download from there."))
    }

    func testQuotedMediaKeepsTheToolsFailure() {
        let tweet: [String: Any] = [
            "text": "look https://www.pixiv.net/artworks/1",
            "quote": ["media": ["all": [["type": "photo", "url": "https://pbs.twimg.com/media/x.jpg"]]]],
        ]
        XCTAssertEqual(FxTwitterService.noMediaOutcome(tweet: tweet), .keepPrior)
    }

    // MARK: - Running the rescue

    func testTweetLinkingToPixivDownloadsTheArtwork() async throws {
        stubTweet(["text": "Kafka fan art https://www.pixiv.net/en/artworks/151217762", "author": ["name": "someone"]])
        let original = try XCTUnwrap(URL(string: "https://i.pximg.net/img-original/img/2026/10/24/16/31/23/151217762_p0.png"))
        StubProtocol.set(
            json(["error": false, "body": [["urls": ["original": original.absoluteString]]]]), for: PixivService.pagesURL(for: "151217762"))
        StubProtocol.set(
            json(["error": false, "body": ["userName": "Example Artist", "illustTitle": "Kafka"]]), for: PixivService.infoURL(for: "151217762"))
        StubProtocol.set(
            .init(
                status: 200, headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(count: 500)),
            for: original)
        let item = failedTweetRow()

        let finished = await FxTwitterService.run(item: item, outputDirectory: downloads, session: stubSession(), pixivSession: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), ["Example Artist - Kafka [151217762].png"])
        XCTAssertEqual(StubProtocol.requests(to: original).first?.value(forHTTPHeaderField: "Referer"), "https://www.pixiv.net/")
    }

    func testTextOnlyTweetFailsForGoodWithoutRetry() async {
        stubTweet(["text": "just words", "author": ["name": "someone"]])
        let item = failedTweetRow()

        let finished = await FxTwitterService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(FxTwitterService.noMediaMessage(linkedHost: nil)))
        XCTAssertFalse(item.emptySuccessFailure)
        XCTAssertFalse(DownloadManager.shouldAutoRetryEmptySuccess(item))
    }

    func testTweetFxtwitterCannotSeeKeepsTheLimitedMessage() async {
        StubProtocol.set(.init(status: 404, headers: [:], body: Data("{\"code\":404}".utf8)), for: fxURL())
        let item = failedTweetRow()

        let finished = await FxTwitterService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(priorMessage))
        XCTAssertTrue(item.emptySuccessFailure)
    }

    // MARK: - Helpers

    /// A tweet row as the tools leave it: failed with gallery-dl's empty
    /// result, the empty-success flag set.
    private func failedTweetRow() -> DownloadItem {
        let item = DownloadItem(url: "https://x.com/someone/status/\(id)")
        item.emptySuccessFailure = true
        item.status = .failed(priorMessage)
        return item
    }

    private func fxURL() -> URL { URL(string: "https://api.fxtwitter.com/i/status/\(id)")! }

    private func stubTweet(_ tweet: [String: Any]) {
        StubProtocol.set(json(["code": 200, "message": "OK", "tweet": tweet]), for: fxURL())
    }

    private func json(_ object: [String: Any]) -> StubProtocol.Stub {
        .init(
            status: 200, headers: ["Content-Type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func stubSession() -> URLSession {
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}
