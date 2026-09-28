import XCTest

@testable import XDownloader

/// A Threads link through DownloadManager itself: the row is in the
/// manager's list and its run is the one the queue starts. What is held here
/// is the orchestration around the resolver — yt-dlp is never started, Stop
/// ends paused, the row's ✕ leaves nothing behind, a resolver failure is
/// finalized under its own message, and only a post Threads withholds from
/// logged-out visitors starts yt-dlp, once, for the signed-in page. The
/// pages are the synthetic fixtures; every request is answered by the
/// URLProtocol stub on the injected session, and the yt-dlp the manager is
/// given is a script that leaves a mark and prints synthetic output, so
/// nothing here touches the network, a browser or a cookie.
@MainActor
final class ThreadsDownloadManagerTests: XCTestCase {

    private var root: URL!
    private var downloads: URL!
    private var history: HistoryStore!
    /// Exists only if the manager started yt-dlp; one line per start.
    private var ytDlpMark: URL!
    /// The arguments of the last start, one per line.
    private var ytDlpArguments: URL!
    /// The process the tool last ran as.
    private var ytDlpProcessID: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadsDownloadManagerTests-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        history = HistoryStore(directory: root.appendingPathComponent("stores"))
        ytDlpMark = root.appendingPathComponent("yt-dlp-ran")
        ytDlpArguments = root.appendingPathComponent("yt-dlp-arguments")
        ytDlpProcessID = root.appendingPathComponent("yt-dlp-process")
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Completing

    func testThreadsLinkCompletesWithoutStartingYtDlp() async throws {
        let post = try fixture("threads_single_image.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        StubProtocol.set(jpeg(), for: post.media[0])
        let manager = try makeManager()

        let result = manager.capture(text: post.link + "?xmt=AQF0abc", source: .field)

        XCTAssertEqual(result.queued, 1)
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(manager.items.count, 1)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let saved = try contents(of: downloads)
        XCTAssertEqual(saved.count, 1)
        let name = try XCTUnwrap(saved.first)
        XCTAssertTrue(name.hasSuffix(" [SYNimage0001].jpg"), name)
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent(name).path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ytDlpMark.path), "yt-dlp was started for a Threads link")
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
    }

    /// A post of two or more files ends Done in a folder of its own; the
    /// row and history name a file inside it, and history knows its size.
    func testAMultiFilePostEndsDoneInItsFolderAndHistoryRecordsTheFile() async throws {
        let post = try fixture("threads_image_carousel.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        for address in post.media { StubProtocol.set(jpeg(), for: address) }
        let manager = try makeManager()

        manager.capture(text: post.link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let entries = try contents(of: downloads)
        XCTAssertEqual(entries.count, 1)
        let folder = downloads.appendingPathComponent(try XCTUnwrap(entries.first), isDirectory: true)
        let names = (1...post.media.count).map { "\(folder.lastPathComponent) #\($0).jpg" }
        XCTAssertEqual(try contents(of: folder), names)
        let outputPath = folder.appendingPathComponent(names[0]).path
        XCTAssertEqual(item.outputPath, outputPath)
        let entry = try XCTUnwrap(history.mostRecentCompleted(for: item.url))
        XCTAssertEqual(entry.outputPath, outputPath)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int64)
        XCTAssertEqual(entry.fileSizeBytes, size)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ytDlpMark.path))
    }

    func testResumedRowIsResolvedAgainInsteadOfTrustingWhatItCarries() async throws {
        // A row that still names a file from an earlier run. With yt-dlp
        // skipped there is no yt-dlp result to read as "exit 0, file on
        // disk": only the resolver may complete the row.
        let post = try fixture("threads_single_image.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        StubProtocol.set(jpeg(), for: post.media[0])
        let manager = try makeManager()
        let item = DownloadItem(url: post.link)
        item.status = .paused
        item.outputPath = downloads.appendingPathComponent("an earlier file.jpg").path
        manager.items.insert(item, at: 0)

        manager.resumeItem(item)

        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
        let saved = try contents(of: downloads)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(item.outputPath, saved.first.map { downloads.appendingPathComponent($0).path })
        XCTAssertFalse(FileManager.default.fileExists(atPath: ytDlpMark.path))
    }

    func testSecondSpellingOfAPostInTheListIsNotQueuedAgain() async throws {
        let post = try fixture("threads_single_video.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        var stalled = mp4()
        stalled.ending = .never
        StubProtocol.set(stalled, for: post.media[0])
        let manager = try makeManager()
        XCTAssertGreaterThanOrEqual(manager.maxConcurrent, 2)

        XCTAssertEqual(manager.capture(text: post.link, source: .field).queued, 1)
        let again = manager.capture(text: "https://threads.net/t/SYNvideo0001", source: .field)

        XCTAssertEqual(again.queued, 0)
        XCTAssertEqual(again.alreadyPresent, 1)
        XCTAssertEqual(manager.items.count, 1)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntilTheTransferIsUnderWay(item, from: post.media[0])
        manager.removeItem(item)
        try await waitUntil("the transfer was cancelled") { StubProtocol.wasStopped(post.media[0]) }
    }

    // MARK: - Stop and remove

    func testStopDuringTheTransferEndsPausedWithNothingSaved() async throws {
        let post = try fixture("threads_single_video.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        var stalled = mp4()
        stalled.ending = .never
        StubProtocol.set(stalled, for: post.media[0])
        let manager = try makeManager()
        manager.capture(text: post.link, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntilTheTransferIsUnderWay(item, from: post.media[0])

        manager.pauseItem(item)

        // Well inside the request timeout: the transfer is cancelled, not
        // waited out.
        try await waitUntil("the row is paused", seconds: 5) { item.status == .paused }
        XCTAssertTrue(StubProtocol.wasStopped(post.media[0]))
        XCTAssertNil(item.speed)
        XCTAssertNil(item.eta)
        XCTAssertNil(item.outputPath)
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertEqual(manager.items.count, 1)
        // Give a run that wrongly carried on the time to show itself.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(item.status, .paused)
        XCTAssertEqual(history.count(), 0, "a paused download is not a finished one")
    }

    func testRemoveDuringTheTransferLeavesNoOutcomeAndNoHistory() async throws {
        let post = try fixture("threads_single_video.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        var stalled = mp4()
        stalled.ending = .never
        StubProtocol.set(stalled, for: post.media[0])
        let manager = try makeManager()
        manager.capture(text: post.link, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntilTheTransferIsUnderWay(item, from: post.media[0])

        manager.removeItem(item)

        XCTAssertTrue(manager.items.isEmpty)
        try await waitUntil("the transfer was cancelled", seconds: 5) { StubProtocol.wasStopped(post.media[0]) }
        // The run winds down after the cancel; nothing it does from here on
        // may touch a row the user has removed.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(item.status, .downloading)
        XCTAssertNil(item.outputPath)
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertEqual(history.count(), 0)
        XCTAssertTrue(manager.items.isEmpty)
    }

    // MARK: - Signed-in second try

    func testPublicLinkNeverStartsTheToolWhateverTheCookieSettings() async throws {
        let post = try fixture("threads_linked_inline_video.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        StubProtocol.set(mp4(), for: post.media[0])
        // A tool that would hand back a page, and a browser to take the
        // login from: everything the second try needs is there.
        let manager = try makeManager(toolPrints: post.html, endingAt: post.pageURL)
        manager.cookieBrowser = .chrome
        manager.cookieBrowserProfile = "Default"

        manager.capture(text: post.link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try contents(of: downloads).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ytDlpMark.path), "yt-dlp was started for a public Threads post")
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
    }

    func testRestrictedLinkStartsTheToolOnceAndDownloadsThePost() async throws {
        let post = try fixture("threads_linked_inline_video.html")
        let restricted = try fixture("threads_fail_restricted_audience.html")
        StubProtocol.set(page(restricted.html), for: post.pageURL)
        StubProtocol.set(mp4(), for: post.media[0])
        let manager = try makeManager(toolPrints: post.html, endingAt: post.pageURL)
        manager.cookieBrowser = .firefox
        manager.cookieBrowserProfile = "Work"

        manager.capture(text: post.link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let saved = try contents(of: downloads)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].hasSuffix(" [SYNreel00001].mp4"), saved[0])
        XCTAssertEqual(try toolStarts(), 1)
        XCTAssertEqual(
            try toolArguments(),
            ThreadsSignedInPage.arguments(cookieArguments: ["--cookies-from-browser", "firefox:Work"], pageURL: post.pageURL))
        XCTAssertFalse(item.autoRetryAttempted)
        // Logged out once; the media without anything attached.
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
        XCTAssertEqual(StubProtocol.requests(to: post.media[0]).first?.allHTTPHeaderFields ?? [:], [:])
    }

    func testStillRestrictedSignedInFailsAfterOneStartOfTheTool() async throws {
        let post = try fixture("threads_fail_restricted_audience.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        let manager = try makeManager(toolPrints: post.html, endingAt: post.pageURL)
        manager.cookieBrowser = .chrome
        manager.capture(text: post.link, source: .field)
        let item = try XCTUnwrap(manager.items.first)

        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        // Time for an automatic retry to show itself, were one armed.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(item.status, .failed(ThreadsService.signInMissingInBrowserMessage))
        XCTAssertFalse(item.emptySuccessFailure)
        XCTAssertFalse(item.autoRetryAttempted)
        XCTAssertEqual(try toolStarts(), 1)
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
        XCTAssertEqual(try contents(of: downloads), [])
    }

    func testStopDuringTheSignedInTryTerminatesTheToolAndEndsPaused() async throws {
        let post = try fixture("threads_fail_restricted_audience.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        let manager = try makeManager(tool: "exec sleep 30\n")
        manager.cookieBrowser = .chrome
        manager.capture(text: post.link, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the tool started") { FileManager.default.fileExists(atPath: self.ytDlpMark.path) }

        manager.pauseItem(item)

        // Far inside the tool's 30 seconds: it was terminated, not waited out.
        try await waitUntil("the row is paused", seconds: 5) { item.status == .paused }
        XCTAssertFalse(toolIsRunning())
        XCTAssertEqual(try toolStarts(), 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(item.status, .paused)
        XCTAssertEqual(history.count(), 0, "a paused download is not a finished one")
        XCTAssertEqual(try contents(of: downloads), [])
    }

    func testRemoveDuringTheSignedInTryTerminatesTheToolAndLeavesNoOutcome() async throws {
        let post = try fixture("threads_fail_restricted_audience.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        let manager = try makeManager(tool: "exec sleep 30\n")
        manager.cookieBrowser = .chrome
        manager.capture(text: post.link, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the tool started") { FileManager.default.fileExists(atPath: self.ytDlpMark.path) }
        let started = Date()

        manager.removeItem(item)

        XCTAssertTrue(manager.items.isEmpty)
        try await waitUntil("the tool was terminated", seconds: 5) { !self.toolIsRunning() }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // The run winds down after that; nothing it does from here on may
        // touch a row the user has removed.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(item.status, .fetching)
        XCTAssertEqual(history.count(), 0)
        XCTAssertEqual(try contents(of: downloads), [])
    }

    // MARK: - Failing

    func testResolverFailureIsFinalizedUnderItsOwnMessage() async throws {
        let post = try fixture("threads_fail_restricted_audience.html")
        StubProtocol.set(page(post.html), for: post.pageURL)
        let manager = try makeManager()
        // No browser and no cookies.txt to take a login from: the post
        // stays restricted, and the tool is not started to find that out.
        manager.cookieBrowser = .none
        manager.capture(text: post.link, source: .field)
        let item = try XCTUnwrap(manager.items.first)

        try await waitUntil("the failure was recorded") { self.history.count() == 1 }

        XCTAssertEqual(item.status, .failed(ThreadsService.restrictedMessage))
        XCTAssertFalse(item.emptySuccessFailure)
        XCTAssertFalse(item.autoRetryAttempted)
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ytDlpMark.path))
        XCTAssertNil(history.mostRecentCompleted(for: item.url))
    }

    func testNonPostLinkFailsWithTheFixedMessageAndNoRequest() async throws {
        let link = "https://www.threads.com/@someone.invented"
        let manager = try makeManager()
        manager.capture(text: link, source: .field)
        let item = try XCTUnwrap(manager.items.first)

        try await waitUntil("the failure was recorded") { self.history.count() == 1 }

        XCTAssertEqual(item.status, .failed(ThreadsService.notAPostLinkMessage))
        XCTAssertEqual(StubProtocol.requests(to: try XCTUnwrap(URL(string: link))).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ytDlpMark.path))
    }

    // MARK: - Helpers

    private struct Post {
        let link: String
        let pageURL: URL
        let html: String
        let media: [URL]
    }

    private struct ManifestEntry: Decodable {
        struct Media: Decodable {
            let url: String
        }

        let link: String
        let fixture: String
        let expect_media: [Media]
    }

    private func fixture(_ name: String) throws -> Post {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let manifest = try JSONDecoder().decode(
            [ManifestEntry].self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        let entry = try XCTUnwrap(manifest.first { $0.fixture == name }, "no manifest entry for \(name)")
        let link = try XCTUnwrap(ThreadsService.parseLink(entry.link))
        return Post(
            link: entry.link,
            pageURL: try XCTUnwrap(ThreadsService.canonicalURL(for: link)),
            html: try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
            media: try entry.expect_media.map { try XCTUnwrap(URL(string: $0.url)) })
    }

    /// A manager whose yt-dlp prints `html` the way the tool prints a page
    /// it was asked to dump, then fails with "Unsupported URL" as the tool
    /// does.
    private func makeManager(toolPrints html: String, endingAt address: URL) throws -> DownloadManager {
        let encoded = root.appendingPathComponent("page.b64")
        try Data(html.utf8).base64EncodedData().write(to: encoded)
        return try makeManager(
            tool: """
                echo '[generic] Extracting URL: \(address.absoluteString)'
                echo '[generic] Dumping request to \(address.absoluteString)'
                cat "\(encoded.path)"
                echo
                echo 'ERROR: Unsupported URL: \(address.absoluteString)' >&2
                exit 1

                """)
    }

    private func toolStarts() throws -> Int {
        guard FileManager.default.fileExists(atPath: ytDlpMark.path) else { return 0 }
        return try String(contentsOf: ytDlpMark, encoding: .utf8).split(separator: "\n").count
    }

    /// Whether the process the tool last ran as is still there.
    private func toolIsRunning() -> Bool {
        guard let text = try? String(contentsOf: ytDlpProcessID, encoding: .utf8),
            let id = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return kill(id, 0) == 0
    }

    private func toolArguments() throws -> [String] {
        try String(contentsOf: ytDlpArguments, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// A manager on temporary stores whose Threads requests go to the stub
    /// and whose yt-dlp, if it were ever started, leaves `ytDlpMark` and
    /// then does what `tool` says.
    private func makeManager(tool: String = "exit 1\n") throws -> DownloadManager {
        let stores = root.appendingPathComponent("stores")
        let script = root.appendingPathComponent("yt-dlp")
        let header = """
            #!/bin/sh
            echo $$ > "\(ytDlpProcessID.path)"
            printf '%s\\n' "$@" > "\(ytDlpArguments.path)"
            echo started >> "\(ytDlpMark.path)"

            """
        try Data((header + tool).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        let manager = DownloadManager(
            history: history,
            queueStore: QueueStore(directory: stores),
            settingsStore: SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "threads-mgr-\(UUID().uuidString)"))),
            likesSyncStore: LikesSyncStore(directory: stores),
            galleryDlPathProvider: { nil },
            ytDlpPathProvider: { script.path },
            threadsSession: URLSession(configuration: configuration))
        manager.outputDirectory = downloads
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(manager.saveHistoryEnabled)
        return manager
    }

    /// The row reads downloading before its request is made, and a request
    /// cancelled while the session is still setting it up may never be
    /// started — so there is nothing for the session to stop. A test that
    /// goes on to require the stop waits for the request itself.
    private func waitUntilTheTransferIsUnderWay(_ item: DownloadItem, from address: URL, line: UInt = #line) async throws {
        try await waitUntil("the transfer started", line: line) {
            item.status == .downloading && !StubProtocol.requests(to: address).isEmpty
        }
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

    private func page(_ html: String) -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    private func jpeg() -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 3, count: 2_000))
    }

    private func mp4() -> StubProtocol.Stub {
        .init(
            status: 200, headers: ["Content-Type": "video/mp4"],
            body: Data([0x00, 0x00, 0x00, 0x20]) + Data("ftypisom".utf8) + Data(repeating: 9, count: 200_000))
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
