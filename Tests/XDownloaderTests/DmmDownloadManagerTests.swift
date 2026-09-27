import XCTest

@testable import XDownloader

/// A work page link through DownloadManager itself: the row is in the
/// manager's list and its run is the one the queue starts. What is held here
/// is the orchestration around the resolver — the address is looked up
/// first and handed to yt-dlp without any cookie argument, a link that
/// resolves nothing fails under its cause's own message with yt-dlp never
/// started, Stop ends paused, the row's ✕ leaves nothing behind, and every
/// further run asks for the address again. The answers are the synthetic
/// fixtures; every request is answered by the URLProtocol stub on the
/// injected session, and the yt-dlp the manager is given is a script that
/// records its arguments, so nothing here touches the network, a browser or
/// a cookie.
@MainActor
final class DmmDownloadManagerTests: XCTestCase {

    private typealias Resolver = DmmPreviewResolver

    private let link = "https://video.dmm.co.jp/cinema/content/?id=test00123"
    private let address = "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/test00123hhb.mp4"
    private let stem = "Synthetic Maker - Synthetic Sample Title [test00123]"

    private var root: URL!
    private var downloads: URL!
    private var history: HistoryStore!
    /// Exists only if the manager started yt-dlp; one line per start.
    private var ytDlpMark: URL!
    /// The arguments of the last start, one per line.
    private var ytDlpArguments: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DmmDownloadManagerTests-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        history = HistoryStore(directory: root.appendingPathComponent("stores"))
        ytDlpMark = root.appendingPathComponent("yt-dlp-ran")
        ytDlpArguments = root.appendingPathComponent("yt-dlp-arguments")
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Completing

    func testResolvedAddressGoesToTheToolWithoutCookieArguments() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_2d.json")), for: Resolver.endpoint)
        let manager = try makeManager(tool: saving(stem))
        // Everything a login could be taken from is there, and none of it
        // may be used.
        let cookiesFile = root.appendingPathComponent("cookies.txt")
        try Data("# Netscape HTTP Cookie File\n".utf8).write(to: cookiesFile)
        manager.cookieBrowser = .chrome
        manager.cookieBrowserProfile = "Default"
        manager.cookiesFilePath = cookiesFile.path

        let result = manager.capture(text: link + "&utm_source=share", source: .field)

        XCTAssertEqual(result.queued, 1)
        XCTAssertEqual(manager.items.count, 1)
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.url, link)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.title, "Synthetic Maker - Synthetic Sample Title")
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent(stem + ".mp4").path)
        XCTAssertEqual(try contents(of: downloads), [stem + ".mp4"])

        XCTAssertEqual(try toolStarts(), 1)
        let arguments = try toolArguments()
        XCTAssertEqual(arguments.last, address)
        XCTAssertFalse(arguments.contains(link), "the page link was handed to the tool")
        XCTAssertEqual(arguments[try XCTUnwrap(arguments.firstIndex(of: "--output")) + 1], downloads.path + "/" + stem + ".%(ext)s")
        XCTAssertEqual(arguments.first, "--format")
        for argument in arguments {
            XCTAssertFalse(argument.lowercased().contains("cookie"), argument)
            XCTAssertFalse(argument.contains("chrome"), argument)
        }

        // One request, with nothing attached.
        let requests = StubProtocol.requests(to: Resolver.endpoint)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))

        // The row's identity is the page link: that is what history keeps,
        // under the site's label, and nothing of the address.
        let entry = try XCTUnwrap(history.mostRecentCompleted(for: link))
        XCTAssertEqual(entry.site, "dmm")
        XCTAssertEqual(entry.url, link)
        XCTAssertNil(history.mostRecentCompleted(for: address))
    }

    func testVRPreviewDownloadsLikeAnyOther() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_vr.json")), for: Resolver.endpoint)
        let vrStem = "Synthetic Maker - Synthetic Sample Title [testvr00045]"
        let manager = try makeManager(tool: saving(vrStem))

        manager.capture(text: "https://video.dmm.co.jp/cinema/content/?id=testvr00045", source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(
            try toolArguments().last,
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/testvr00045vruhq.mp4")
        XCTAssertEqual(try contents(of: downloads), [vrStem + ".mp4"])
    }

    func testPercentSignInATitleReachesTheFileName() async throws {
        let title = "100% Synthetic"
        let answer: [String: Any] = [
            "data": [
                "ipInfo": ["accessStatus": "ALLOW"],
                "ppvContent": [
                    "id": "test00123", "title": title, "isAllowForeign": true, "maker": ["name": "Synthetic Maker"],
                    "sample2DMovie": ["highestMovieUrl": address, "hlsMovieUrl": NSNull()], "sampleVRMovie": NSNull(),
                ],
            ]
        ]
        StubProtocol.set(json(try JSONSerialization.data(withJSONObject: answer)), for: Resolver.endpoint)
        let name = "Synthetic Maker - 100% Synthetic [test00123]"
        let manager = try makeManager(tool: saving(name))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.title, "Synthetic Maker - 100% Synthetic")
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent(name + ".mp4").path)
        let arguments = try toolArguments()
        XCTAssertEqual(
            arguments[try XCTUnwrap(arguments.firstIndex(of: "--output")) + 1],
            downloads.path + "/Synthetic Maker - 100%% Synthetic [test00123].%(ext)s")
    }

    // MARK: - Failing

    func testEachCauseFailsUnderItsOwnMessageAndNeverStartsTheTool() async throws {
        let cases: [(name: String, link: String, stub: StubProtocol.Stub?, requests: Int, expected: Resolver.Failure)] = [
            ("list page", "https://video.dmm.co.jp/cinema/list/", nil, 0, .notAWorkPage),
            ("unknown id", link, json(try fixture("dmm_not_found.json")), 1, .notFound),
            ("no preview", link, json(try fixture("dmm_no_preview.json")), 1, .noPreview),
            ("region", link, json(try fixture("dmm_region_denied.json")), 1, .regionBlocked),
            ("format", link, json(try fixture("dmm_changed_format.json")), 1, .changedFormat),
            ("server", link, .init(status: 503, headers: ["Content-Type": "text/html"], body: Data()), 1, .network),
            (
                "connection", link,
                .init(status: 200, headers: [:], body: Data(), ending: .error(URLError(.notConnectedToInternet))), 1, .network
            ),
        ]
        for (index, c) in cases.enumerated() {
            StubProtocol.removeAll()
            if let stub = c.stub { StubProtocol.set(stub, for: Resolver.endpoint) }
            let manager = try makeManager(tool: saving(stem))
            manager.cookieBrowser = .chrome

            manager.capture(text: c.link, source: .field)

            let item = try XCTUnwrap(manager.items.first, c.name)
            try await waitUntil("the failure was recorded (\(c.name))") { self.history.count() == index + 1 }
            // Time for an automatic retry to show itself, were one armed.
            try await Task.sleep(nanoseconds: 200_000_000)

            XCTAssertEqual(item.status, .failed(Resolver.message(for: c.expected)), c.name)
            XCTAssertFalse(item.emptySuccessFailure, c.name)
            XCTAssertFalse(item.autoRetryAttempted, c.name)
            XCTAssertNil(item.resolvedAddress, c.name)
            XCTAssertNil(item.resolvedFileStem, c.name)
            XCTAssertEqual(try toolStarts(), 0, "yt-dlp was started for a link that resolved nothing (\(c.name))")
            XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, c.requests, c.name)
            XCTAssertEqual(try contents(of: downloads), [], c.name)
            XCTAssertEqual(history.count(), index + 1, c.name)
        }
    }

    func testNoPreviewAndChangedFormatAreToldApart() {
        XCTAssertNotEqual(Resolver.message(for: .noPreview), Resolver.message(for: .changedFormat))
        XCTAssertTrue(Resolver.message(for: .noPreview).contains(Resolver.paidVideosNotSupportedMessage))
    }

    /// The download itself was turned down: the copy for this site never
    /// points at cookies, which it is not sent.
    func testRejectedDownloadDoesNotSuggestDifferentCookies() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_2d.json")), for: Resolver.endpoint)
        let manager = try makeManager(
            tool: """
                echo 'ERROR: unable to download video data: HTTP Error 403: Forbidden' >&2
                exit 1

                """)

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .failed(YtDlpService.http403WithoutCookiesMessage))
        guard case .failed(let message) = item.status else { return XCTFail("expected a failure") }
        XCTAssertFalse(message.lowercased().contains("cookie"), message)
        XCTAssertNotEqual(message, YtDlpService.genericHttp403Message)
        XCTAssertEqual(try toolStarts(), 1)
    }

    /// The tool quotes the address it was given. Whatever it says, the
    /// address reaches neither the row nor history.
    func testToolOutputNeverPutsTheResolvedAddressOnTheRowOrInHistory() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_2d.json")), for: Resolver.endpoint)
        let tools = [
            "echo 'ERROR: Unsupported URL: \(address)' >&2\nexit 1\n": Resolver.changedFormatMessage,
            "echo 'WARNING: [generic] Falling back on generic information extractor: \(address)' >&2\nexit 1\n":
                YtDlpService.resolvedAddressFailedMessage,
        ]
        for (tool, expected) in tools {
            let manager = try makeManager(tool: tool)
            let before = history.count()
            manager.capture(text: link, source: .field)
            let item = try XCTUnwrap(manager.items.first)
            try await waitUntil("the failure was recorded") { self.history.count() == before + 1 }
            XCTAssertEqual(item.status, .failed(expected))
            XCTAssertEqual(try toolArguments().last, address)
        }
        // Nothing the app wrote — history, queue — holds the address. (The
        // stand-in tool and its record of arguments are the test's own.)
        let own = ["yt-dlp", ytDlpArguments.lastPathComponent]
        let token = Data("SYNTHETICtoken".utf8)
        var read = 0
        for file in try files(under: root) {
            guard !own.contains(file.lastPathComponent), let bytes = try? Data(contentsOf: file) else { continue }
            read += 1
            XCTAssertNil(bytes.range(of: token), file.lastPathComponent)
        }
        XCTAssertGreaterThan(read, 0)
    }

    // MARK: - Stop and remove

    func testRemoveWhileResolvingStartsNothing() async throws {
        var stalled = json(try fixture("dmm_preview_2d.json"))
        stalled.ending = .never
        StubProtocol.set(stalled, for: Resolver.endpoint)
        let manager = try makeManager(tool: saving(stem))
        manager.capture(text: link, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the request was made") { !StubProtocol.requests(to: Resolver.endpoint).isEmpty }
        XCTAssertEqual(item.status, .fetching)

        manager.removeItem(item)

        XCTAssertTrue(manager.items.isEmpty)
        try await waitUntil("the request was cancelled", seconds: 5) { StubProtocol.wasStopped(Resolver.endpoint) }
        // The run winds down after the cancel; nothing it does from here on
        // may touch a row the user has removed.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(item.status, .fetching)
        XCTAssertNil(item.resolvedAddress)
        XCTAssertEqual(try toolStarts(), 0)
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertEqual(history.count(), 0)
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 1)
    }

    func testStopWhileResolvingEndsPausedAndResumeResolvesAgain() async throws {
        var stalled = json(try fixture("dmm_preview_2d.json"))
        stalled.ending = .never
        StubProtocol.set(stalled, for: Resolver.endpoint)
        let manager = try makeManager(tool: saving(stem))
        manager.capture(text: link, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the request was made") { !StubProtocol.requests(to: Resolver.endpoint).isEmpty }

        manager.pauseItem(item)

        try await waitUntil("the row is paused", seconds: 5) { item.status == .paused }
        XCTAssertTrue(StubProtocol.wasStopped(Resolver.endpoint))
        // Give a run that wrongly carried on the time to show itself.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(item.status, .paused)
        XCTAssertEqual(try toolStarts(), 0)
        XCTAssertEqual(history.count(), 0, "a paused download is not a finished one")

        StubProtocol.set(json(try fixture("dmm_preview_2d.json")), for: Resolver.endpoint)
        manager.resumeItem(item)

        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 2)
        XCTAssertEqual(try toolStarts(), 1)
        XCTAssertEqual(try toolArguments().last, address)
    }

    // MARK: - Resolving again

    func testRetryResolvesAgain() async throws {
        StubProtocol.set(
            [
                .init(status: 503, headers: ["Content-Type": "text/html"], body: Data()),
                json(try fixture("dmm_preview_2d.json")),
            ], for: Resolver.endpoint)
        let manager = try makeManager(tool: saving(stem))
        manager.capture(text: link, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .failed(Resolver.networkMessage))
        XCTAssertEqual(try toolStarts(), 0)

        manager.retryItem(item)

        try await waitUntil("the download finished") { item.status == .completed }
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 2)
        XCTAssertEqual(try toolStarts(), 1)
        XCTAssertEqual(try toolArguments().last, address)
    }

    func testAnAddressTheRowCarriesIsNeverTrusted() async throws {
        // The second answer names another address: that is the one the
        // second run downloads, not the one the first run left on the row.
        let later = address.replacingOccurrences(of: "tokenAAAA", with: "tokenZZZZ")
        let second = String(decoding: try fixture("dmm_preview_2d.json"), as: UTF8.self)
            .replacingOccurrences(of: "tokenAAAA", with: "tokenZZZZ")
        StubProtocol.set([json(try fixture("dmm_preview_2d.json")), json(Data(second.utf8))], for: Resolver.endpoint)
        let manager = try makeManager(tool: saving(stem))
        manager.capture(text: link, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(try toolArguments().last, address)
        XCTAssertEqual(item.resolvedAddress, address)

        manager.retryItem(item)

        try await waitUntil("the second run started the tool") { (try? self.toolStarts()) == 2 }
        try await waitUntil("the second run finished") { item.status == .completed }
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 2)
        XCTAssertEqual(try toolArguments().last, later)
    }

    // MARK: - Identity

    func testOneWorkIsOneRowWhateverWasPasted() async throws {
        var stalled = json(try fixture("dmm_preview_2d.json"))
        stalled.ending = .never
        StubProtocol.set(stalled, for: Resolver.endpoint)
        let manager = try makeManager(tool: saving(stem))

        let wrapped = "https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fcinema%2Fcontent%2F%3Fid%3Dtest00123"
        XCTAssertEqual(manager.capture(text: wrapped, source: .field).queued, 1)
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.url, link)

        for spelling in [link, "http://VIDEO.DMM.CO.JP/cinema/content?id=TEST00123&utm_source=share", wrapped] {
            let again = manager.capture(text: spelling, source: .field)
            XCTAssertEqual(again.queued, 0, spelling)
            XCTAssertEqual(again.alreadyPresent, 1, spelling)
        }
        XCTAssertEqual(manager.items.count, 1)
        try await waitUntil("the request was made") { !StubProtocol.requests(to: Resolver.endpoint).isEmpty }
        manager.removeItem(item)
        try await waitUntil("the request was cancelled", seconds: 5) { StubProtocol.wasStopped(Resolver.endpoint) }
    }

    /// The section is no part of what names a work: the id alone is sent
    /// and the id alone names the file, so the same id under two sections
    /// would be two rows writing one file.
    func testOneWorkUnderAnotherSectionIsTheSameRow() async throws {
        var stalled = json(try fixture("dmm_preview_2d.json"))
        stalled.ending = .never
        StubProtocol.set(stalled, for: Resolver.endpoint)
        let manager = try makeManager(tool: saving(stem))
        XCTAssertEqual(manager.capture(text: link, source: .field).queued, 1)
        let item = try XCTUnwrap(manager.items.first)

        let again = manager.capture(text: "https://video.dmm.co.jp/vr/content/?id=test00123", source: .field)

        XCTAssertEqual(again.queued, 0)
        XCTAssertEqual(again.alreadyPresent, 1)
        XCTAssertEqual(manager.items.count, 1)
        // Another work under either section is another row.
        XCTAssertFalse(DownloadManager.isSameDownload(link, "https://video.dmm.co.jp/vr/content/?id=test00124"))
        XCTAssertFalse(DownloadManager.isSameDownload(link, "https://video.dmm.co.jp/cinema/content/?id=xtest00123"))
        XCTAssertFalse(DownloadManager.isSameDownload(link, "https://cc3001.dmm.co.jp/pv/SYNTHETICtoken/test00123hhb.mp4"))
        XCTAssertFalse(DownloadManager.isSameDownload(link, "https://example.com/cinema/content/?id=test00123"))
        try await waitUntil("the request was made") { !StubProtocol.requests(to: Resolver.endpoint).isEmpty }
        manager.removeItem(item)
        try await waitUntil("the request was cancelled", seconds: 5) { StubProtocol.wasStopped(Resolver.endpoint) }
    }

    func testFinishedWorkUnderAnotherSectionIsRecognisedAsADuplicate() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_2d.json")), for: Resolver.endpoint)
        let manager = try makeManager(tool: saving(stem))
        manager.capture(text: link, source: .field)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        manager.clearCompleted()

        let again = manager.capture(text: "https://video.dmm.co.jp/vr/content/?id=test00123", source: .field)
        XCTAssertEqual(again.queued, 0)
        XCTAssertEqual(again.toConfirm, 1)

        // An id that merely ends or starts the same names another work.
        for other in ["xtest00123", "test001230", "test_0123"] {
            XCTAssertNil(
                history.mostRecentCompleted(
                    urlPrefix: Resolver.pageLinkPrefix,
                    urlSuffix: Resolver.pageLinkSuffix(for: .init(section: "vr", contentID: other))), other)
        }
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 1)
    }

    func testFinishedWorkIsRecognisedAsADuplicate() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_2d.json")), for: Resolver.endpoint)
        let manager = try makeManager(tool: saving(stem))
        manager.capture(text: link, source: .field)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        manager.clearCompleted()
        XCTAssertTrue(manager.items.isEmpty)

        let again = manager.capture(text: "https://video.dmm.co.jp/cinema/content?id=TEST00123", source: .field)

        XCTAssertEqual(again.queued, 0)
        XCTAssertEqual(again.toConfirm, 1)
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 1, "a link waiting for an answer is not resolved")
    }

    // MARK: - Direct links

    /// A direct preview file link resolves nothing: it goes to the tool as
    /// pasted, with the cookie arguments every generic link gets.
    func testDirectFileLinkStillTakesTheGenericPath() async throws {
        let direct = [
            address,
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/playlist.m3u8",
        ]
        for (index, pasted) in direct.enumerated() {
            let manager = try makeManager(tool: saving("direct \(index)"))
            manager.cookieBrowser = .chrome
            manager.cookieBrowserProfile = ""

            manager.capture(text: pasted, source: .field)

            let item = try XCTUnwrap(manager.items.first)
            XCTAssertEqual(item.url, pasted)
            try await waitUntil("the download finished") { self.history.count() == index + 1 }
            XCTAssertEqual(item.status, .completed)
            XCTAssertNil(item.resolvedAddress)
            XCTAssertNil(item.resolvedFileStem)
            let expected = YtDlpService.buildArguments(
                for: DownloadItem(url: pasted), outputDirectory: downloads, format: manager.youtubeFormat,
                videoQuality: manager.videoQuality, audioQuality: manager.audioQuality,
                subtitleLanguage: manager.subtitleLanguage, embedSubtitles: manager.embedSubtitles,
                cookieBrowser: .chrome, cookieBrowserProfile: "", cookiesFile: nil)
            XCTAssertEqual(try toolArguments(), expected)
            XCTAssertEqual(Array(expected.prefix(2)), ["--cookies-from-browser", "chrome"])
            XCTAssertEqual(expected.last, pasted)
            XCTAssertEqual(history.mostRecentCompleted(for: pasted)?.site, "other")
        }
        XCTAssertTrue(StubProtocol.requests(to: Resolver.endpoint).isEmpty, "a direct link was resolved")
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func json(_ body: Data) -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "application/json; charset=utf-8"], body: body)
    }

    /// What the tool does after recording its arguments: leaves a file
    /// named `stem` and reports it the way yt-dlp reports a download.
    private func saving(_ stem: String) -> String {
        let path = downloads.appendingPathComponent(stem + ".mp4").path
        return """
            printf 'synthetic' > "\(path)"
            echo "[download] Destination: \(path)"
            echo "[download] 100% of 9.00B in 00:00"
            exit 0

            """
    }

    private func toolStarts() throws -> Int {
        guard FileManager.default.fileExists(atPath: ytDlpMark.path) else { return 0 }
        return try String(contentsOf: ytDlpMark, encoding: .utf8).split(separator: "\n").count
    }

    private func toolArguments() throws -> [String] {
        try String(contentsOf: ytDlpArguments, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// A manager on temporary stores whose resolver requests go to the stub
    /// and whose yt-dlp records its arguments, leaves `ytDlpMark` and then
    /// does what `tool` says.
    private func makeManager(tool: String) throws -> DownloadManager {
        // A queue of its own: a test that builds several managers must not
        // hand one the rows of another.
        let stores = root.appendingPathComponent("stores-\(UUID().uuidString)")
        let script = root.appendingPathComponent("yt-dlp")
        let header = """
            #!/bin/sh
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
            settingsStore: SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "dmm-mgr-\(UUID().uuidString)"))),
            likesSyncStore: LikesSyncStore(directory: stores),
            galleryDlPathProvider: { nil },
            ytDlpPathProvider: { script.path },
            dmmSession: URLSession(configuration: configuration))
        manager.outputDirectory = downloads
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(manager.saveHistoryEnabled)
        return manager
    }

    /// Every file below `folder`. Walking a folder is synchronous work, kept
    /// out of the asynchronous test bodies.
    private func files(under folder: URL) throws -> [URL] {
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        return walk.compactMap { $0 as? URL }
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
