import XCTest

@testable import XDownloader

/// Where the fxtwitter rescue saves a tweet's files: a tweet of two or more
/// into a folder of its own, made only with a complete file to put in it; a
/// one-file tweet loose, as before; and into a folder an earlier run made
/// for the tweet whatever the number. The lookup and the files are answered
/// by the URLProtocol stub on an injected session, so nothing here touches
/// the network. Every name and id is invented.
@MainActor
final class FxTwitterFolderTests: XCTestCase {

    private let id = "1234567890123"
    private var downloads: URL!

    override func setUpWithError() throws {
        downloads = FileManager.default.temporaryDirectory.appendingPathComponent("FxTwitterFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: downloads)
    }

    func testATwoFileTweetGoesIntoItsFolder() async throws {
        let media = stubTweet(text: "two photos", photos: 2)
        let item = DownloadItem(url: "https://x.com/someone/status/\(id)")

        let finished = await FxTwitterService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        let stem = "someone - two photos [\(id)]"
        XCTAssertEqual(try contents(of: downloads), [stem])
        let folder = downloads.appendingPathComponent(stem)
        XCTAssertEqual(try contents(of: folder), ["\(stem) #1.jpg", "\(stem) #2.jpg"])
        XCTAssertEqual(item.outputPath, folder.appendingPathComponent("\(stem) #1.jpg").path)
        XCTAssertEqual(item.imageCount, 2)

        // A second run finds both and fetches neither again.
        let again = DownloadItem(url: item.url)
        let finishedAgain = await FxTwitterService.run(item: again, outputDirectory: downloads, session: stubSession())
        XCTAssertTrue(finishedAgain)
        for url in media {
            XCTAssertEqual(StubProtocol.requests(to: url).count, 1, url.absoluteString)
        }
        XCTAssertEqual(try contents(of: folder), ["\(stem) #1.jpg", "\(stem) #2.jpg"])
    }

    func testAOneFileTweetStaysLoose() async throws {
        stubTweet(text: "one photo", photos: 1)
        let item = DownloadItem(url: "https://x.com/someone/status/\(id)")

        let finished = await FxTwitterService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(try contents(of: downloads), ["someone - one photo [\(id)] #1.jpg"])
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent("someone - one photo [\(id)] #1.jpg").path)
    }

    /// A folder an earlier run made for the tweet takes its files, even a
    /// lone one: the other tools spell the name their own way.
    func testAFoundFolderTakesTheFilesWhateverTheirNumber() async throws {
        stubTweet(text: "one photo", photos: 1)
        let found = downloads.appendingPathComponent("someone - one photo, spelled otherwise [\(id)]", isDirectory: true)
        try FileManager.default.createDirectory(at: found, withIntermediateDirectories: true)
        let item = DownloadItem(url: "https://x.com/someone/status/\(id)")

        let finished = await FxTwitterService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(try contents(of: found), ["someone - one photo [\(id)] #1.jpg"])
        XCTAssertEqual(try contents(of: downloads), [found.lastPathComponent])
    }

    /// A folder gallery-dl made for the tweet moments before, in the same
    /// run and under its own spelling of the stem, takes the rescue's files:
    /// the tweet is not split across two folders, and the next run finds
    /// the one folder there is.
    func testAFolderMadeEarlierInTheSameRunTakesTheFiles() async throws {
        stubTweet(text: "two photos", photos: 2)
        let item = DownloadItem(url: "https://x.com/someone/status/\(id)")
        let madeByGalleryDl = downloads.appendingPathComponent("someone - two  photos [\(id)]", isDirectory: true)
        try FileManager.default.createDirectory(at: madeByGalleryDl, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: madeByGalleryDl.appendingPathComponent("someone - two  photos [\(id)] #1.jpg"))

        let finished = await FxTwitterService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(try contents(of: downloads), [madeByGalleryDl.lastPathComponent])
        XCTAssertEqual(
            try contents(of: madeByGalleryDl),
            [
                "someone - two  photos [\(id)] #1.jpg", "someone - two photos [\(id)] #1.jpg",
                "someone - two photos [\(id)] #2.jpg",
            ])
    }

    /// A found folder whose name holds a "$" is passed over, as the tools
    /// pass it over: the rescue makes the tweet's own folder.
    func testAFoundFolderWhoseNameHoldsADollarSignIsPassedOver() async throws {
        stubTweet(text: "two photos", photos: 2)
        let odd = downloads.appendingPathComponent("someone - $HOME [\(id)]", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let item = DownloadItem(url: "https://x.com/someone/status/\(id)")

        let finished = await FxTwitterService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertTrue(finished)
        XCTAssertEqual(try contents(of: odd), [])
        let stem = "someone - two photos [\(id)]"
        XCTAssertEqual(try contents(of: downloads.appendingPathComponent(stem)), ["\(stem) #1.jpg", "\(stem) #2.jpg"])
    }

    /// Every transfer failing leaves no folder, and the prior failure stands.
    func testEveryFileFailingLeavesNoFolder() async throws {
        let media = stubTweet(text: "two photos", photos: 2)
        for url in media {
            StubProtocol.set(.init(status: 404, headers: [:], body: Data("not found".utf8)), for: url)
        }
        let item = DownloadItem(url: "https://x.com/someone/status/\(id)")
        item.status = .failed("earlier failure")

        let finished = await FxTwitterService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed("earlier failure"))
        XCTAssertEqual(try contents(of: downloads), [])
    }

    // MARK: - Helpers

    /// Stubs the lookup of a tweet by "someone" with `photos` photos, each
    /// answered with a few synthetic bytes, and returns their addresses as
    /// the rescue requests them.
    @discardableResult
    private func stubTweet(text: String, photos: Int) -> [URL] {
        let media = (1...photos).map { URL(string: "https://pbs.example.invalid/media/synthetic\($0).jpg")! }
        let tweet: [String: Any] = [
            "code": 200,
            "tweet": [
                "author": ["name": "someone"],
                "text": text,
                "media": ["all": media.map { ["type": "photo", "url": $0.absoluteString] }],
            ],
        ]
        let body = try! JSONSerialization.data(withJSONObject: tweet)
        StubProtocol.set(
            .init(status: 200, headers: ["Content-Type": "application/json"], body: body),
            for: URL(string: "https://api.fxtwitter.com/i/status/\(id)")!)
        let requested = media.map { URL(string: $0.absoluteString + "?name=orig")! }
        for url in requested {
            StubProtocol.set(.init(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data("synthetic".utf8)), for: url)
        }
        return requested
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
