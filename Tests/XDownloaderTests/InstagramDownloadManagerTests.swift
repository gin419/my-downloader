import XCTest

@testable import XDownloader

/// An Instagram link through DownloadManager itself: the row is in the
/// manager's list and its run is the one the queue starts. What is held here
/// is the single-item guard — a link that names an account or a page of the
/// site fails at once under the fixed message, with neither tool started, no
/// cookie source looked up and no auto-retry armed, whether it was just
/// pasted or restored from a saved queue; a link to one post reaches the
/// tools exactly as before. The yt-dlp and gallery-dl the manager is given
/// are scripts that record that they were started, so nothing here touches
/// the network, a browser or a cookie. Every username and code is invented.
@MainActor
final class InstagramDownloadManagerTests: XCTestCase {

    private let post = "https://www.instagram.com/p/SYNpost0001_/"
    private let profile = "https://www.instagram.com/someone.invented/"

    private var root: URL!
    private var downloads: URL!
    private var stores: URL!
    private var history: HistoryStore!
    /// Exist only if the manager started the tool; one line per start.
    private var ytDlpMark: URL!
    private var galleryDlMark: URL!
    /// The arguments of yt-dlp's last start, one per line.
    private var ytDlpArguments: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("InstagramDownloadManagerTests-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("downloads")
        stores = root.appendingPathComponent("stores")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        history = HistoryStore(directory: stores)
        ytDlpMark = root.appendingPathComponent("yt-dlp-ran")
        galleryDlMark = root.appendingPathComponent("gallery-dl-ran")
        ytDlpArguments = root.appendingPathComponent("yt-dlp-arguments")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Turned down

    func testAccountWideLinksFailWithTheFixedMessageAndStartNoTool() async throws {
        let links = [
            profile,
            "https://instagram.com/someone.invented",
            "https://WWW.INSTAGRAM.COM/someone.invented/reels/",
            "https://www.instagram.com/someone.invented/tagged/",
            "https://www.instagram.com/someone.invented/saved/",
            "https://www.instagram.com/stories/someone.invented/",
            "https://www.instagram.com/stories/highlights/17900000000000000/",
            "https://www.instagram.com/explore/tags/invented/",
            "https://www.instagram.com/reels/audio/1234567890/",
            "https://instagr.am/someone.invented/",
            // Routed to the twitter profile, by the "x.com/" in it.
            "https://www.instagram.com/invented.x.com/",
            // An escaped slash, which gallery-dl reads as the reels tab.
            "https://www.instagram.com/someone.invented/reels%2FSYNreel0001_",
        ]
        for (index, link) in links.enumerated() {
            // What an earlier link left behind is not this link's doing.
            for leftover in [ytDlpMark, galleryDlMark, downloads] {
                try? FileManager.default.removeItem(at: try XCTUnwrap(leftover))
            }
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let manager = try makeManager()
            // A cookies file that is not there: looking the cookie source
            // up would say so (see the accepted link below).
            manager.cookieBrowser = .chrome
            manager.cookiesFilePath = root.appendingPathComponent("missing/cookies.txt").path

            let result = manager.capture(text: link, source: .field)

            XCTAssertEqual(result.queued, 1, link)
            let item = try XCTUnwrap(manager.items.first, link)
            try await waitUntil("the failure was recorded (\(link))") { self.history.count() == index + 1 }
            // Time for an automatic retry to show itself, were one armed.
            try await Task.sleep(nanoseconds: 200_000_000)

            XCTAssertEqual(item.status, .failed(InstagramLink.notASingleItemMessage), link)
            XCTAssertFalse(item.emptySuccessFailure, link)
            XCTAssertFalse(item.autoRetryAttempted, link)
            XCTAssertEqual(try starts(of: ytDlpMark), 0, "yt-dlp was started for \(link)")
            XCTAssertEqual(try starts(of: galleryDlMark), 0, "gallery-dl was started for \(link)")
            XCTAssertNotEqual(manager.captureFeedback?.message, DownloadManager.cookiesFileInaccessibleFeedbackMessage, link)
            XCTAssertEqual(try contents(of: downloads), [], link)
            XCTAssertEqual(history.count(), index + 1, link)
            XCTAssertNil(history.mostRecentCompleted(for: item.url), link)
        }
    }

    func testRetryOfATurnedDownLinkIsTurnedDownAgain() async throws {
        let manager = try makeManager()
        manager.capture(text: profile, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the failure was recorded") { self.history.count() == 1 }

        manager.retryItem(item)

        XCTAssertEqual(item.status, .queued)
        try await waitUntil("the second run ended") { item.status != .queued && item.status != .fetching }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.status, .failed(InstagramLink.notASingleItemMessage))
        XCTAssertFalse(item.autoRetryAttempted)
        XCTAssertEqual(try starts(of: ytDlpMark), 0)
        XCTAssertEqual(try starts(of: galleryDlMark), 0)
    }

    /// A row saved by an earlier version, which would have run the link.
    func testRowRestoredFromASavedQueueIsTurnedDownWhenItRuns() async throws {
        let saved = DownloadItem(url: "https://www.instagram.com/someone.invented/reels/")
        XCTAssertEqual(saved.status, .queued)
        let queue = root.appendingPathComponent("saved-queue")
        QueueStore(directory: queue).save([saved.toPersisted()])

        // The restored queue starts by itself.
        let manager = try makeManager(queue: queue)

        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.url, saved.url)
        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.status, .failed(InstagramLink.notASingleItemMessage))
        XCTAssertFalse(item.emptySuccessFailure)
        XCTAssertFalse(item.autoRetryAttempted)
        XCTAssertEqual(try starts(of: ytDlpMark), 0)
        XCTAssertEqual(try starts(of: galleryDlMark), 0)
        XCTAssertEqual(QueueStore(directory: queue).load().first?.status, .failed(InstagramLink.notASingleItemMessage))
    }

    /// A paused row of an earlier session, resumed.
    func testResumedRowIsTurnedDown() async throws {
        let manager = try makeManager()
        let item = DownloadItem(url: profile)
        item.status = .paused
        manager.items.insert(item, at: 0)

        manager.resumeItem(item)

        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .failed(InstagramLink.notASingleItemMessage))
        XCTAssertEqual(try starts(of: ytDlpMark), 0)
        XCTAssertEqual(try starts(of: galleryDlMark), 0)
    }

    // MARK: - Accepted

    func testSinglePostStillReachesTheToolExactlyAsBefore() async throws {
        let links = [
            post,
            "https://www.instagram.com/reel/SYNreel0001_/",
            "https://www.instagram.com/someone.invented/p/SYNpost0001_/",
            "https://www.instagram.com/stories/someone.invented/3456789012345678901/",
            "https://www.instagram.com/share/p/SYNshare01/",
            "https://instagr.am/p/SYNpost0001_/",
            // A link that lost its "?".
            "https://www.instagram.com/reel/SYNreel0001_&igsh=SYNtracking",
        ]
        for (index, link) in links.enumerated() {
            let manager = try makeManager()
            manager.cookieBrowser = .chrome
            manager.cookieBrowserProfile = ""

            manager.capture(text: link, source: .field)

            let item = try XCTUnwrap(manager.items.first, link)
            XCTAssertEqual(item.url, link)
            try await waitUntil("the download finished (\(link))") { self.history.count() == index + 1 }
            XCTAssertEqual(item.status, .completed, link)
            XCTAssertEqual(try starts(of: ytDlpMark), index + 1, link)
            let expected = YtDlpService.buildArguments(
                for: DownloadItem(url: link), outputDirectory: downloads, format: manager.youtubeFormat,
                videoQuality: manager.videoQuality, audioQuality: manager.audioQuality,
                subtitleLanguage: manager.subtitleLanguage, embedSubtitles: manager.embedSubtitles,
                cookieBrowser: .chrome, cookieBrowserProfile: "", cookiesFile: nil)
            XCTAssertEqual(try toolArguments(), expected, link)
            XCTAssertEqual(Array(expected.prefix(2)), ["--cookies-from-browser", "chrome"])
            XCTAssertEqual(expected.last, link)
            XCTAssertEqual(history.mostRecentCompleted(for: link)?.site, "instagram", link)
        }
    }

    /// The other half of the cookie check above: an accepted link does look
    /// the cookie source up, and says so when the file is gone.
    func testAcceptedLinkLooksTheCookieSourceUp() async throws {
        let manager = try makeManager()
        manager.cookiesFilePath = root.appendingPathComponent("missing/cookies.txt").path

        manager.capture(text: post, source: .field)

        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(manager.captureFeedback?.message, DownloadManager.cookiesFileInaccessibleFeedbackMessage)
        XCTAssertEqual(try starts(of: ytDlpMark), 1)
    }

    /// yt-dlp finds no video in a photo post; gallery-dl is still the one
    /// that downloads it.
    func testPhotoPostStillFallsBackToGalleryDl() async throws {
        let manager = try makeManager(ytDlp: "echo 'ERROR: [Instagram] SYNpost0001_: No video formats found!' >&2\nexit 1\n")

        manager.capture(text: post, source: .field)

        try await waitUntil("the run ended") { self.history.count() == 1 }
        XCTAssertEqual(try starts(of: ytDlpMark), 1)
        XCTAssertEqual(try starts(of: galleryDlMark), 1)
    }

    // MARK: - Other sites

    /// Links the Instagram profile is handed without their being Instagram
    /// page links — a media file address, a look-alike host — and an
    /// account link of another site: all run as they always have.
    func testLinksThatAreNotInstagramPageLinksAreNotJudged() async throws {
        let links = [
            "https://scontent.cdninstagram.com/v/t51.2885-15/synthetic_0001_n.mp4",
            "https://notinstagram.com/someone.invented/",
            "https://example.com/someone.invented/",
            "https://www.youtube.com/@someone.invented/videos",
        ]
        for (index, link) in links.enumerated() {
            let manager = try makeManager()

            manager.capture(text: link, source: .field)

            let item = try XCTUnwrap(manager.items.first, link)
            try await waitUntil("the download finished (\(link))") { self.history.count() == index + 1 }
            XCTAssertEqual(item.status, .completed, link)
            XCTAssertEqual(try starts(of: ytDlpMark), index + 1, link)
            XCTAssertEqual(try toolArguments().last, link)
        }
    }

    // MARK: - Helpers

    private func starts(of mark: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: mark.path) else { return 0 }
        return try String(contentsOf: mark, encoding: .utf8).split(separator: "\n").count
    }

    private func toolArguments() throws -> [String] {
        try String(contentsOf: ytDlpArguments, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// What yt-dlp does by default after recording its start: leaves a file
    /// and reports it the way yt-dlp reports a download.
    private var saving: String {
        let path = downloads.appendingPathComponent("synthetic.mp4").path
        return """
            printf 'synthetic' > "\(path)"
            echo "[download] Destination: \(path)"
            echo "[download] 100% of 9.00B in 00:00"
            exit 0

            """
    }

    /// A manager on temporary stores whose yt-dlp and gallery-dl record
    /// that they were started. The queue is one of its own — a test that
    /// builds several managers must not hand one the rows of another —
    /// unless `queue` names a saved one to restore.
    private func makeManager(ytDlp: String? = nil, queue: URL? = nil) throws -> DownloadManager {
        let ytDlpScript = root.appendingPathComponent("yt-dlp")
        let galleryDlScript = root.appendingPathComponent("gallery-dl")
        let ytDlpHeader = """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(ytDlpArguments.path)"
            echo started >> "\(ytDlpMark.path)"

            """
        let galleryDl = """
            #!/bin/sh
            echo started >> "\(galleryDlMark.path)"
            exit 1

            """
        try Data((ytDlpHeader + (ytDlp ?? saving)).utf8).write(to: ytDlpScript)
        try Data(galleryDl.utf8).write(to: galleryDlScript)
        for script in [ytDlpScript, galleryDlScript] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let manager = DownloadManager(
            history: history,
            queueStore: QueueStore(directory: queue ?? root.appendingPathComponent("queue-\(UUID().uuidString)")),
            settingsStore: SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "instagram-mgr-\(UUID().uuidString)"))),
            likesSyncStore: LikesSyncStore(directory: stores),
            galleryDlPathProvider: { galleryDlScript.path },
            ytDlpPathProvider: { ytDlpScript.path })
        manager.outputDirectory = downloads
        XCTAssertEqual(manager.items.count, queue == nil ? 0 : 1)
        XCTAssertTrue(manager.saveHistoryEnabled)
        return manager
    }

    private func waitUntil(
        _ what: String, seconds: TimeInterval = 10, line: UInt = #line, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting until \(what)", line: line)
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
