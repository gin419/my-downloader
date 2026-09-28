import XCTest

@testable import XDownloader

/// A work page link through DownloadManager itself: the row is in the
/// manager's list and its run is the one the queue starts. What is held here
/// is the orchestration around the resolver — the address is looked up
/// first and handed to yt-dlp without any cookie argument, a link that
/// resolves nothing fails under its cause's own message with yt-dlp never
/// started, the pictures download in-app after the clip or in its place,
/// Stop ends paused, the row's ✕ leaves nothing behind, and every further
/// run asks for the address again. The answers are the synthetic
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
                    "packageImage": NSNull(), "sampleImages": [Any](),
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

    // MARK: - Pictures

    func testPicturesWithoutAClipDownloadInAppAndNeverStartTheTool() async throws {
        StubProtocol.set(json(try fixture("dmm_pictures_only.json")), for: Resolver.endpoint)
        stubPictures(picturesOnlyNames, of: "testvr00046")
        // Were the tool started, the row would fail.
        let manager = try makeManager(tool: "exit 1\n")
        manager.cookieBrowser = .chrome
        manager.cookieBrowserProfile = "Default"

        manager.capture(text: picturesOnlyLink, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.imageCount, 4)
        XCTAssertNil(item.videoCount)
        XCTAssertEqual(item.title, "Synthetic Maker - Synthetic Sample Title")
        let names = (1...4).map { "\(picturesOnlyStem) #\($0).jpg" }
        XCTAssertEqual(try contents(of: downloads), names)
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent(names[0]).path)
        // Gallery order: the cover is #1, the samples follow by number.
        for (index, name) in picturesOnlyNames.enumerated() {
            XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent(names[index])), jpegBody(name), name)
        }

        XCTAssertEqual(try toolStarts(), 0)
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 1)
        for name in picturesOnlyNames {
            let requests = StubProtocol.requests(to: try pictureURL("testvr00046", name))
            XCTAssertEqual(requests.count, 1, name)
            XCTAssertEqual(requests.first?.httpMethod, "GET", name)
            XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"), name)
            XCTAssertEqual(requests.first?.httpShouldHandleCookies, false, name)
        }
        // Never the smaller size of a picture that has the large one.
        for name in ["cover-medium", "sample-1-thumb", "sample-2-thumb", "sample-3-thumb"] {
            XCTAssertTrue(StubProtocol.requests(to: try pictureURL("testvr00046", name)).isEmpty, name)
        }

        // Nothing the app wrote holds a picture address.
        let own = ["yt-dlp", ytDlpArguments.lastPathComponent]
        var read = 0
        for file in try files(under: root) where !own.contains(file.lastPathComponent) {
            guard let bytes = try? Data(contentsOf: file) else { continue }
            read += 1
            XCTAssertNil(bytes.range(of: Data("awsimgsrc".utf8)), file.lastPathComponent)
        }
        XCTAssertGreaterThan(read, 0)
    }

    func testClipAndPicturesStartTheToolOnceThenSaveThePictures() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_with_pictures.json")), for: Resolver.endpoint)
        stubPictures(withClipNames, of: "test00124")
        let manager = try makeManager(tool: saving(withClipStem))

        manager.capture(text: "https://video.dmm.co.jp/cinema/content/?id=test00124", source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.imageCount, 3)
        // The clip keeps its un-numbered name and stays the row's file.
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent(withClipStem + ".mp4").path)
        XCTAssertEqual(
            try contents(of: downloads), ((1...3).map { "\(withClipStem) #\($0).jpg" } + [withClipStem + ".mp4"]).sorted())

        XCTAssertEqual(try toolStarts(), 1)
        let arguments = try toolArguments()
        XCTAssertEqual(arguments.last, withClipAddress)
        XCTAssertEqual(arguments[try XCTUnwrap(arguments.firstIndex(of: "--output")) + 1], downloads.path + "/" + withClipStem + ".%(ext)s")
        for argument in arguments {
            XCTAssertFalse(argument.lowercased().contains("cookie"), argument)
            XCTAssertFalse(argument.contains("awsimgsrc"), "a picture was handed to the tool: \(argument)")
        }
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 1)
        for name in withClipNames {
            XCTAssertEqual(StubProtocol.requests(to: try pictureURL("test00124", name)).count, 1, name)
        }
    }

    func testAPictureThatFailsIsAPartialResultAndRetryFetchesOnlyIt() async throws {
        StubProtocol.set(json(try fixture("dmm_pictures_only.json")), for: Resolver.endpoint)
        stubPictures(picturesOnlyNames, of: "testvr00046")
        // The sample numbered 2 is the gallery's third picture.
        let failing = try pictureURL("testvr00046", "sample-2-large")
        StubProtocol.set([.init(status: 404, headers: ["Content-Type": "text/html"], body: Data()), jpeg("sample-2-large")], for: failing)
        let manager = try makeManager(tool: "exit 1\n")

        manager.capture(text: picturesOnlyLink, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        // Time for an automatic retry to show itself, were one armed.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.status, .failed("Saved 3 of 4 files — the server returned HTTP 404. Retry fetches the rest."))
        XCTAssertEqual(item.imageCount, 3)
        XCTAssertFalse(item.emptySuccessFailure)
        XCTAssertFalse(item.autoRetryAttempted)
        XCTAssertEqual(try contents(of: downloads), [1, 2, 4].map { "\(picturesOnlyStem) #\($0).jpg" })
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 1)

        manager.retryItem(item)

        try await waitUntil("the retry finished") { item.status == .completed }
        XCTAssertEqual(item.imageCount, 4)
        XCTAssertEqual(try contents(of: downloads), (1...4).map { "\(picturesOnlyStem) #\($0).jpg" })
        // Looked up again, and only the missing picture fetched again.
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 2)
        XCTAssertEqual(StubProtocol.requests(to: failing).count, 2)
        for name in picturesOnlyNames where name != "sample-2-large" {
            XCTAssertEqual(StubProtocol.requests(to: try pictureURL("testvr00046", name)).count, 1, name)
        }
        XCTAssertEqual(try toolStarts(), 0)
    }

    func testClipSavedAndAPictureFailedIsAPartialResult() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_with_pictures.json")), for: Resolver.endpoint)
        stubPictures(withClipNames, of: "test00124")
        StubProtocol.set(
            .init(status: 404, headers: ["Content-Type": "text/html"], body: Data()), for: try pictureURL("test00124", "sample-1-large"))
        let manager = try makeManager(tool: saving(withClipStem))

        manager.capture(text: "https://video.dmm.co.jp/cinema/content/?id=test00124", source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.status, .failed("Saved 3 of 4 files — the server returned HTTP 404. Retry fetches the rest."))
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.imageCount, 2)
        XCTAssertFalse(item.emptySuccessFailure)
        XCTAssertFalse(item.autoRetryAttempted)
        XCTAssertEqual(try toolStarts(), 1)
        XCTAssertEqual(
            try contents(of: downloads), ["\(withClipStem) #1.jpg", "\(withClipStem) #3.jpg", withClipStem + ".mp4"])
    }

    /// The clip failed: the pictures are saved all the same, and the row
    /// keeps the clip's own message, which names what is missing.
    func testClipFailedAndPicturesSavedKeepsTheClipsMessage() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_with_pictures.json")), for: Resolver.endpoint)
        stubPictures(withClipNames, of: "test00124")
        let manager = try makeManager(tool: "exit 1\n")

        manager.capture(text: "https://video.dmm.co.jp/cinema/content/?id=test00124", source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.status, .failed(YtDlpService.resolvedAddressFailedMessage))
        XCTAssertEqual(item.imageCount, 3)
        XCTAssertNil(item.videoCount)
        XCTAssertFalse(item.autoRetryAttempted)
        XCTAssertEqual(try toolStarts(), 1)
        XCTAssertEqual(try contents(of: downloads), (1...3).map { "\(withClipStem) #\($0).jpg" })
    }

    func testRemoveDuringPictureDownloadsLeavesNoFileAndStartsNothingFurther() async throws {
        StubProtocol.set(json(try fixture("dmm_pictures_only.json")), for: Resolver.endpoint)
        stubPictures(picturesOnlyNames, of: "testvr00046")
        // The cover starts arriving and never ends, like a transfer in flight.
        let cover = try pictureURL("testvr00046", "cover-large")
        var stalled = jpeg("cover-large")
        stalled.ending = .never
        StubProtocol.set(stalled, for: cover)
        let manager = try makeManager(tool: "exit 1\n")
        manager.capture(text: picturesOnlyLink, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the picture was requested") { !StubProtocol.requests(to: cover).isEmpty }

        manager.removeItem(item)

        XCTAssertTrue(manager.items.isEmpty)
        try await waitUntil("the transfer was cancelled", seconds: 5) { StubProtocol.wasStopped(cover) }
        // The run winds down after the cancel; nothing it does from here on
        // may touch the folder or start another transfer.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try contents(of: downloads), [])
        for name in picturesOnlyNames where name != "cover-large" {
            XCTAssertTrue(StubProtocol.requests(to: try pictureURL("testvr00046", name)).isEmpty, name)
        }
        XCTAssertEqual(StubProtocol.requests(to: cover).count, 1)
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 1)
        XCTAssertEqual(try toolStarts(), 0)
        XCTAssertEqual(history.count(), 0)
    }

    func testStopDuringPictureDownloadsEndsPausedAndResumeFetchesTheRest() async throws {
        StubProtocol.set(json(try fixture("dmm_pictures_only.json")), for: Resolver.endpoint)
        stubPictures(picturesOnlyNames, of: "testvr00046")
        let second = try pictureURL("testvr00046", "sample-1-large")
        var stalled = jpeg("sample-1-large")
        stalled.ending = .never
        StubProtocol.set([stalled, jpeg("sample-1-large")], for: second)
        let manager = try makeManager(tool: "exit 1\n")
        manager.capture(text: picturesOnlyLink, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the second picture was requested") { !StubProtocol.requests(to: second).isEmpty }

        manager.pauseItem(item)

        try await waitUntil("the row is paused", seconds: 5) { item.status == .paused }
        XCTAssertTrue(StubProtocol.wasStopped(second))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(item.status, .paused)
        XCTAssertEqual(history.count(), 0, "a paused download is not a finished one")
        XCTAssertEqual(try contents(of: downloads), ["\(picturesOnlyStem) #1.jpg"])

        manager.resumeItem(item)

        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.imageCount, 4)
        XCTAssertEqual(try contents(of: downloads), (1...4).map { "\(picturesOnlyStem) #\($0).jpg" })
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 2)
        XCTAssertEqual(StubProtocol.requests(to: try pictureURL("testvr00046", "cover-large")).count, 1)
        XCTAssertEqual(StubProtocol.requests(to: second).count, 2)
        XCTAssertEqual(try toolStarts(), 0)
    }

    /// A Stop that reaches the row once the clip's download has ended finds
    /// no process left to end. It must still stop the row before the first
    /// picture, not after the last. The tool here ignores the stop signal,
    /// so it exits cleanly after the Stop, as one that had already ended
    /// would.
    func testAStopAsTheClipEndsPausesBeforeAnyPictureAndResumeFetchesThem() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_with_pictures.json")), for: Resolver.endpoint)
        stubPictures(withClipNames, of: "test00124")
        let proceed = root.appendingPathComponent("proceed")
        let clip = downloads.appendingPathComponent(withClipStem + ".mp4").path
        let manager = try makeManager(
            tool: """
                trap '' TERM
                printf 'synthetic' > "\(clip)"
                echo "[download] Destination: \(clip)"
                while [ ! -f "\(proceed.path)" ]; do sleep 0.05; done
                echo "[download] 100% of 9.00B in 00:00"
                exit 0

                """)
        manager.capture(text: "https://video.dmm.co.jp/cinema/content/?id=test00124", source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the clip was reported") { item.outputPath != nil }

        manager.pauseItem(item)
        try Data().write(to: proceed)

        try await waitUntil("the row is paused", seconds: 5) { item.status == .paused }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(item.status, .paused)
        XCTAssertEqual(history.count(), 0, "a paused download is not a finished one")
        XCTAssertEqual(try contents(of: downloads), [withClipStem + ".mp4"])
        for name in withClipNames {
            XCTAssertTrue(StubProtocol.requests(to: try pictureURL("test00124", name)).isEmpty, name)
        }

        manager.resumeItem(item)

        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.imageCount, 3)
        XCTAssertEqual(
            try contents(of: downloads), ((1...3).map { "\(withClipStem) #\($0).jpg" } + [withClipStem + ".mp4"]).sorted())
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 2)
        XCTAssertEqual(try toolStarts(), 2)
    }

    /// Audio only opts out of visual media: the clip is the download and
    /// its pictures are not fetched.
    func testAudioOnlyDownloadsTheClipWithoutItsPictures() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_with_pictures.json")), for: Resolver.endpoint)
        stubPictures(withClipNames, of: "test00124")
        let manager = try makeManager(tool: saving(withClipStem))
        manager.youtubeFormat = .audioOnly

        manager.capture(text: "https://video.dmm.co.jp/cinema/content/?id=test00124", source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertNil(item.imageCount)
        XCTAssertNotEqual(item.mediaCategory, .mixed)
        XCTAssertNotEqual(item.mediaCategory, .image)
        XCTAssertEqual(try contents(of: downloads), [withClipStem + ".mp4"])
        XCTAssertTrue(try toolArguments().contains("--extract-audio"))
        for name in withClipNames {
            XCTAssertTrue(StubProtocol.requests(to: try pictureURL("test00124", name)).isEmpty, name)
        }
    }

    /// The clip failed in audio only: its pictures are not fetched as a
    /// consolation, and the clip's message stands.
    func testAudioOnlyWithAFailedClipFetchesNoPicture() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_with_pictures.json")), for: Resolver.endpoint)
        stubPictures(withClipNames, of: "test00124")
        let manager = try makeManager(tool: "exit 1\n")
        manager.youtubeFormat = .audioOnly

        manager.capture(text: "https://video.dmm.co.jp/cinema/content/?id=test00124", source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .failed(YtDlpService.resolvedAddressFailedMessage))
        XCTAssertNil(item.imageCount)
        XCTAssertEqual(try contents(of: downloads), [])
        for name in withClipNames {
            XCTAssertTrue(StubProtocol.requests(to: try pictureURL("test00124", name)).isEmpty, name)
        }
    }

    /// A work with only pictures has nothing else to give: they download in
    /// audio only too, as a photo post's do.
    func testAudioOnlyStillDownloadsAWorkThatOnlyHasPictures() async throws {
        StubProtocol.set(json(try fixture("dmm_pictures_only.json")), for: Resolver.endpoint)
        stubPictures(picturesOnlyNames, of: "testvr00046")
        let manager = try makeManager(tool: "exit 1\n")
        manager.youtubeFormat = .audioOnly

        manager.capture(text: picturesOnlyLink, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.imageCount, 4)
        XCTAssertEqual(try contents(of: downloads), (1...4).map { "\(picturesOnlyStem) #\($0).jpg" })
        XCTAssertEqual(try toolStarts(), 0)
    }

    /// A picture address was checked as written; where it redirects to was
    /// not, so the redirect is refused and the picture counts as failed.
    func testAPictureThatRedirectsIsNotFollowedAndCountsAsFailed() async throws {
        StubProtocol.set(json(try fixture("dmm_pictures_only.json")), for: Resolver.endpoint)
        stubPictures(picturesOnlyNames, of: "testvr00046")
        let elsewhere = try XCTUnwrap(URL(string: "https://elsewhere.example.invalid/SYNTHETICpicture.jpg"))
        StubProtocol.set(jpeg("elsewhere"), for: elsewhere)
        StubProtocol.set(.refusedRedirect(to: elsewhere), for: try pictureURL("testvr00046", "sample-1-large"))
        let manager = try makeManager(tool: "exit 1\n")

        manager.capture(text: picturesOnlyLink, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .failed("Saved 3 of 4 files — the server returned HTTP 302. Retry fetches the rest."))
        XCTAssertEqual(item.imageCount, 3)
        XCTAssertTrue(StubProtocol.requests(to: elsewhere).isEmpty, "the redirect was followed")
        XCTAssertEqual(try contents(of: downloads), [1, 3, 4].map { "\(picturesOnlyStem) #\($0).jpg" })
    }

    /// A page answered with success where a picture was expected is not
    /// saved under the picture's name, so a Retry fetches it again.
    func testAPictureAnsweredWithAPageIsNotSavedAndRetryFetchesIt() async throws {
        StubProtocol.set(json(try fixture("dmm_pictures_only.json")), for: Resolver.endpoint)
        stubPictures(picturesOnlyNames, of: "testvr00046")
        let notice = try pictureURL("testvr00046", "sample-2-large")
        StubProtocol.set(
            [
                .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<!DOCTYPE html><title>Notice</title>".utf8)),
                jpeg("sample-2-large"),
            ],
            for: notice)
        let manager = try makeManager(tool: "exit 1\n")

        manager.capture(text: picturesOnlyLink, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the failure was recorded") { self.history.count() == 1 }
        XCTAssertEqual(
            item.status, .failed("Saved 3 of 4 files — the server sent something other than the file. Retry fetches the rest."))
        XCTAssertEqual(try contents(of: downloads), [1, 2, 4].map { "\(picturesOnlyStem) #\($0).jpg" })

        manager.retryItem(item)

        try await waitUntil("the retry finished") { item.status == .completed }
        XCTAssertEqual(item.imageCount, 4)
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("\(picturesOnlyStem) #3.jpg")), jpegBody("sample-2-large"))
        XCTAssertEqual(StubProtocol.requests(to: notice).count, 2)
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

    private let picturesOnlyLink = "https://video.dmm.co.jp/vr/content/?id=testvr00046"
    private let picturesOnlyStem = "Synthetic Maker - Synthetic Sample Title [testvr00046]"
    /// The large pictures of dmm_pictures_only.json, in gallery order.
    private let picturesOnlyNames = ["cover-large", "sample-1-large", "sample-2-large", "sample-3-large"]
    private let withClipStem = "Synthetic Maker - Synthetic Sample Title [test00124]"
    private let withClipAddress =
        "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE/test00124hhb.mp4"
    /// The large pictures of dmm_preview_with_pictures.json, in gallery order.
    private let withClipNames = ["cover-large", "sample-1-large", "sample-2-large"]

    private func pictureURL(_ contentID: String, _ name: String) throws -> URL {
        try XCTUnwrap(URL(string: "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/\(contentID)/SYNTHETIC\(name).jpg"))
    }

    /// A JPEG signature followed by the picture's name, so each saved file
    /// shows which address it came from.
    private func jpegBody(_ name: String) -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(name.utf8)
    }

    private func jpeg(_ name: String) -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "image/jpeg"], body: jpegBody(name))
    }

    private func stubPictures(_ names: [String], of contentID: String) {
        for name in names {
            if let url = try? pictureURL(contentID, name) { StubProtocol.set(jpeg(name), for: url) }
        }
    }

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
