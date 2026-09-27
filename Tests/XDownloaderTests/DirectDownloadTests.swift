import XCTest

@testable import XDownloader

/// The shared direct-download helper: the progress text must be readable by
/// the parsers the row and the menu bar already use, the saved file's
/// extension must follow what the server actually sent, and no exit — error
/// status, cancel — may leave a file behind, neither at the final name
/// (the re-download check would count it as saved) nor in the scratch
/// folder. The transfers run against a URLProtocol stub on an injected
/// session; nothing here touches the network.
@MainActor
final class DirectDownloadTests: XCTestCase {

    private var root: URL!
    private var downloads: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DirectDownloadTests-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("downloads")
        scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Progress text

    func testSizeTextRoundTripsThroughTheItemsSizeParsing() {
        let item = DownloadItem(url: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK")
        let exact: [(Int64, String)] = [
            (0, "0.00B"),
            (512, "512.00B"),
            (1_024, "1.00KiB"),
            (1_048_576, "1.00MiB"),
            (16_168_550, "15.42MiB"),
            (104_857_600, "100.00MiB"),
            (1_073_741_824, "1.00GiB"),
        ]
        for (bytes, text) in exact {
            XCTAssertEqual(DirectDownload.sizeText(bytes), text)
            item.totalSize = DirectDownload.sizeText(bytes)
            let parsed = item.totalBytes
            XCTAssertNotNil(parsed, text)
            // Two decimals of the unit is all the text carries.
            XCTAssertEqual(Double(parsed ?? -1), Double(bytes), accuracy: max(Double(bytes) * 0.005, 1), text)
        }
    }

    func testSizeTextAtTheLargeDownloadThresholdStillReadsAsLarge() {
        let item = DownloadItem(url: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK")
        item.totalSize = DirectDownload.sizeText(100 * 1024 * 1024)
        XCTAssertTrue(item.isLargeDownload)
        item.totalSize = DirectDownload.sizeText(2 * 1024 * 1024)
        XCTAssertFalse(item.isLargeDownload)
    }

    func testSpeedTextIsReadByTheMenuBarParser() {
        XCTAssertEqual(DirectDownload.speedText(bytesPerSecond: 1_289_748), "1.23MiB/s")
        XCTAssertEqual(MenuBarState.parseSpeed(DirectDownload.speedText(bytesPerSecond: 2_097_152)), 2_097_152)
        XCTAssertEqual(DirectDownload.speedText(bytesPerSecond: .infinity), "0.00B/s")
        XCTAssertEqual(DirectDownload.speedText(bytesPerSecond: -5), "0.00B/s")
    }

    // MARK: - Extension mapping

    func testExtensionFollowsTheContentType() {
        let cases: [(String, String)] = [
            ("image/jpeg", "jpg"),
            ("image/webp", "webp"),
            ("image/png", "png"),
            ("video/mp4", "mp4"),
            ("IMAGE/WEBP; charset=binary", "webp"),
        ]
        for (contentType, ext) in cases {
            XCTAssertEqual(DirectDownload.fileExtension(contentType: contentType, leadingBytes: Data()), ext, contentType)
        }
    }

    func testExtensionFallsBackToTheLeadingBytes() {
        let cases: [(Data, String)] = [
            (Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]), "jpg"),
            (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "png"),
            (Data("GIF89a".utf8), "gif"),
            (Data("RIFF".utf8) + Data([0x24, 0x00, 0x00, 0x00]) + Data("WEBPVP8 ".utf8), "webp"),
            (Data([0x00, 0x00, 0x00, 0x20]) + Data("ftypisom".utf8), "mp4"),
            (Data([0x00, 0x00, 0x00, 0x1C]) + Data("ftypavif".utf8), "avif"),
            (Data([0x00, 0x00, 0x00, 0x14]) + Data("ftypqt  ".utf8), "mov"),
            (Data([0x1A, 0x45, 0xDF, 0xA3, 0x01]), "webm"),
        ]
        for (bytes, ext) in cases {
            for contentType in [nil, "application/octet-stream", "binary/octet-stream"] {
                XCTAssertEqual(DirectDownload.fileExtension(contentType: contentType, leadingBytes: bytes), ext, ext)
            }
        }
    }

    func testUnrecognisedFileHasNoExtensionOfItsOwn() {
        XCTAssertNil(DirectDownload.fileExtension(contentType: nil, leadingBytes: Data()))
        XCTAssertNil(DirectDownload.fileExtension(contentType: "text/html", leadingBytes: Data("<!DOCTYPE html>".utf8)))
        // A RIFF file that isn't WebP (e.g. WAV) must not be called one.
        XCTAssertNil(
            DirectDownload.fileExtension(
                contentType: nil, leadingBytes: Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVEfmt ".utf8)))
    }

    // MARK: - Re-download check

    func testExistingFileIsFoundWhateverItsExtension() throws {
        XCTAssertNil(DirectDownload.existingFile(baseName: "Invented Author - hello [AbCdEfGhIjK]", in: downloads))
        let saved = downloads.appendingPathComponent("Invented Author - hello [AbCdEfGhIjK].webp")
        try Data([1]).write(to: saved)
        XCTAssertEqual(
            DirectDownload.existingFile(baseName: "Invented Author - hello [AbCdEfGhIjK]", in: downloads)?.lastPathComponent,
            saved.lastPathComponent)
        // The numbered files of a multi-file post are separate names.
        XCTAssertNil(DirectDownload.existingFile(baseName: "Invented Author - hello [AbCdEfGhIjK] #1", in: downloads))
    }

    // MARK: - Session and request

    func testDefaultSessionKeepsAndSendsNoCookies() {
        let configuration = DirectDownload.sessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(DirectDownload.session.configuration.httpCookieStorage)
        XCTAssertFalse(DirectDownload.session.configuration.httpShouldSetCookies)
    }

    func testRequestHasATimeoutAndCarriesOnlyTheGivenHeaders() throws {
        let url = try XCTUnwrap(URL(string: "https://scontent.example.invalid/v/file.jpg?oh=abc&oe=1"))
        let request = DirectDownload.request(for: url, headers: ["User-Agent": "Test"])
        XCTAssertEqual(request.timeoutInterval, DirectDownload.requestTimeout)
        XCTAssertGreaterThan(DirectDownload.requestTimeout, 0)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.allHTTPHeaderFields, ["User-Agent": "Test"])
        // The address is signed: it must go out exactly as resolved.
        XCTAssertEqual(request.url, url)
    }

    // MARK: - Transfers (URLProtocol stub, no network)

    func testOKResponseSavesTheFileAndReportsProgress() async throws {
        let body = Data("RIFF".utf8) + Data([0x24, 0x00, 0x00, 0x00]) + Data("WEBPVP8 ".utf8) + Data(repeating: 7, count: 200_000)
        let url = stubURL("ok.jpg")
        StubProtocol.set(.init(status: 200, headers: ["Content-Type": "image/webp"], body: body), for: url)
        let item = DownloadItem(url: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK")
        item.status = .downloading

        let outcome = await DirectDownload.download(
            url, to: downloads, baseName: "Invented Author - hello [AbCdEfGhIjK] #1", fallbackExtension: "jpg",
            item: item, fileIndex: 0, fileCount: 2, session: stubSession(), temporaryDirectory: scratch)

        guard case .saved(let saved) = outcome else { return XCTFail("expected .saved, got \(outcome)") }
        // Named after what arrived, not after the ".jpg" in the address.
        XCTAssertEqual(saved.lastPathComponent, "Invented Author - hello [AbCdEfGhIjK] #1.webp")
        XCTAssertEqual(try Data(contentsOf: saved), body)
        XCTAssertEqual(try contents(of: downloads), [saved.lastPathComponent])
        XCTAssertEqual(try contents(of: scratch), [])
        XCTAssertEqual(item.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(item.totalSize, DirectDownload.sizeText(Int64(body.count)))
        XCTAssertEqual(Double(item.totalBytes ?? -1), Double(body.count), accuracy: Double(body.count) * 0.005)
        XCTAssertNil(item.speed)
        XCTAssertNil(item.eta)
        XCTAssertEqual(item.status, .downloading)
    }

    func testProgressIsReportedWhileTheFileIsStillArriving() async throws {
        let url = stubURL("slow.mp4")
        // Four pieces, further apart than the update interval, so at least
        // one update lands before the end.
        let body = Data(repeating: 1, count: 400_000)
        StubProtocol.set(
            .init(
                status: 200, headers: ["Content-Type": "video/mp4", "Content-Length": "\(body.count)"], body: body,
                pieces: 4, pause: DirectDownload.progressInterval * 1.5),
            for: url)
        let item = DownloadItem(url: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK")
        item.status = .downloading
        let session = stubSession()
        let downloads: URL = downloads
        let scratch: URL = scratch

        let task = Task { @MainActor in
            await DirectDownload.download(
                url, to: downloads, baseName: "Invented Author - hello [AbCdEfGhIjK] #2", fallbackExtension: "mp4",
                item: item, fileIndex: 1, fileCount: 2, session: session, temporaryDirectory: scratch)
        }

        var midway: (progress: Double, size: String?, speed: String?)?
        for _ in 0..<500 where midway == nil {
            if item.speed != nil { midway = (item.progress, item.totalSize, item.speed) }
            if midway == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let outcome = await task.value

        let seen = try XCTUnwrap(midway, "no update arrived during the transfer")
        // Second file of two: the bar is past half and short of full.
        XCTAssertGreaterThan(seen.progress, 0.5)
        XCTAssertLessThan(seen.progress, 1.0)
        XCTAssertEqual(seen.size, DirectDownload.sizeText(Int64(body.count)))
        XCTAssertNotNil(seen.speed.flatMap(MenuBarState.parseSpeed))
        guard case .saved(let saved) = outcome else { return XCTFail("expected .saved, got \(outcome)") }
        XCTAssertEqual(try Data(contentsOf: saved), body)
        XCTAssertEqual(item.progress, 1.0, accuracy: 0.0001)
        XCTAssertNil(item.speed)
    }

    func testUnknownContentFallsBackToTheCallersExtension() async throws {
        let url = stubURL("opaque")
        StubProtocol.set(.init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: Data([1, 2, 3])), for: url)
        let item = DownloadItem(url: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK")
        item.status = .downloading

        let outcome = await DirectDownload.download(
            url, to: downloads, baseName: "Invented Author - hello [AbCdEfGhIjK]", fallbackExtension: "mp4",
            item: item, fileIndex: 0, fileCount: 1, session: stubSession(), temporaryDirectory: scratch)

        guard case .saved(let saved) = outcome else { return XCTFail("expected .saved, got \(outcome)") }
        XCTAssertEqual(saved.pathExtension, "mp4")
        XCTAssertEqual(item.progress, 1.0, accuracy: 0.0001)
    }

    func testProgressIsNotWrittenUnlessTheItemIsDownloading() async throws {
        let url = stubURL("idle.jpg")
        StubProtocol.set(.init(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF])), for: url)
        let item = DownloadItem(url: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK")
        item.status = .fetching

        let outcome = await DirectDownload.download(
            url, to: downloads, baseName: "Invented Author - hello [AbCdEfGhIjK]", fallbackExtension: "jpg",
            item: item, fileIndex: 0, fileCount: 1, session: stubSession(), temporaryDirectory: scratch)

        guard case .saved = outcome else { return XCTFail("expected .saved, got \(outcome)") }
        XCTAssertEqual(item.progress, 0)
        XCTAssertNil(item.totalSize)
        XCTAssertNil(item.speed)
        XCTAssertNil(item.eta)
        XCTAssertEqual(item.status, .fetching)
    }

    func testForbiddenResponseSavesNothingAndRecordsTheStatus() async throws {
        let url = stubURL("expired.jpg")
        StubProtocol.set(.init(status: 403, headers: ["Content-Type": "text/plain"], body: Data("URL signature expired".utf8)), for: url)
        let item = DownloadItem(url: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK")
        item.status = .downloading

        let outcome = await DirectDownload.download(
            url, to: downloads, baseName: "Invented Author - hello [AbCdEfGhIjK]", fallbackExtension: "jpg",
            item: item, fileIndex: 0, fileCount: 1, session: stubSession(), temporaryDirectory: scratch)

        guard case .failed(.httpStatus(let code)) = outcome else { return XCTFail("expected .httpStatus, got \(outcome)") }
        XCTAssertEqual(code, 403)
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertEqual(try contents(of: scratch), [])
        XCTAssertEqual(item.progress, 0)
        XCTAssertEqual(
            DirectDownload.partialFailureMessage(saved: 1, attempted: 2, lastFailure: .httpStatus(code)),
            "Saved 1 of 2 files — the server returned HTTP 403. Retry fetches the rest.")
    }

    func testTransportFailureRemovesTheTemporaryFile() async throws {
        let url = stubURL("dropped.mp4")
        StubProtocol.set(
            .init(
                status: 200, headers: ["Content-Type": "video/mp4"], body: Data(repeating: 1, count: 200_000),
                ending: .error(URLError(.networkConnectionLost))),
            for: url)
        let item = DownloadItem(url: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK")
        item.status = .downloading

        let outcome = await DirectDownload.download(
            url, to: downloads, baseName: "Invented Author - hello [AbCdEfGhIjK]", fallbackExtension: "mp4",
            item: item, fileIndex: 0, fileCount: 1, session: stubSession(), temporaryDirectory: scratch)

        guard case .failed(.transport(let error)) = outcome else { return XCTFail("expected .transport, got \(outcome)") }
        XCTAssertEqual(DirectDownload.shortReason(for: .transport(error)), "the connection was lost mid-transfer")
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertEqual(try contents(of: scratch), [])
    }

    func testCancelLeavesNothingAtTheDestination() async throws {
        let url = stubURL("stalled.mp4")
        // The body starts arriving and then never ends, like a transfer in
        // flight when the row is stopped.
        StubProtocol.set(
            .init(status: 200, headers: ["Content-Type": "video/mp4"], body: Data(repeating: 1, count: 200_000), ending: .never),
            for: url)
        let item = DownloadItem(url: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK")
        item.status = .downloading
        let session = stubSession()
        let downloads: URL = downloads
        let scratch: URL = scratch

        let task = Task { @MainActor in
            await DirectDownload.download(
                url, to: downloads, baseName: "Invented Author - hello [AbCdEfGhIjK]", fallbackExtension: "mp4",
                item: item, fileIndex: 0, fileCount: 1, session: session, temporaryDirectory: scratch)
        }

        // Cancel only once the transfer has a temporary file to clean up.
        var inFlight = false
        for _ in 0..<500 where !inFlight {
            inFlight = try !contents(of: scratch).isEmpty
            if !inFlight { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(inFlight, "the transfer never started")
        let cancelledAt = Date()
        task.cancel()
        let outcome = await task.value

        guard case .cancelled = outcome else { return XCTFail("expected .cancelled, got \(outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5, "cancel must not wait for the request timeout")
        XCTAssertEqual(try contents(of: downloads), [])
        XCTAssertEqual(try contents(of: scratch), [])
    }

    // MARK: - Helpers

    private func stubURL(_ name: String) -> URL {
        URL(string: "https://scontent.example.invalid/\(UUID().uuidString)/\(name)?oh=abc&oe=1")!
    }

    private func stubSession() -> URLSession {
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}

/// Answers requests from a table instead of the network. Registered on the
/// injected session only, so no other test's traffic can reach it.
private final class StubProtocol: URLProtocol {

    struct Stub {
        enum Ending {
            case finished
            case error(Error)
            /// The response and body are delivered, the end never comes.
            case never
        }

        var status: Int
        var headers: [String: String]
        var body: Data
        var ending: Ending = .finished
        /// The body arrives in this many pieces, `pause` seconds apart.
        var pieces = 1
        var pause: TimeInterval = 0
    }

    private let stopped = NSLock()
    private var isStopped = false

    private static let lock = NSLock()
    private static var stubs: [URL: Stub] = [:]

    static func set(_ stub: Stub, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        stubs[url] = stub
    }

    static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll()
    }

    private static func stub(for url: URL?) -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        return url.flatMap { stubs[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stub(for: url),
            let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else {
            // An address nobody stubbed must fail, never reach the network.
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard stub.pieces > 1 else {
            client?.urlProtocol(self, didLoad: stub.body)
            finish(stub.ending)
            return
        }
        let size = (stub.body.count + stub.pieces - 1) / stub.pieces
        Thread.detachNewThread { [self] in
            var offset = 0
            while offset < stub.body.count {
                if offset > 0 { Thread.sleep(forTimeInterval: stub.pause) }
                guard !stoppedLoading else { return }
                let end = min(offset + size, stub.body.count)
                client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
                offset = end
            }
            finish(stub.ending)
        }
    }

    override func stopLoading() {
        stopped.lock()
        defer { stopped.unlock() }
        isStopped = true
    }

    private var stoppedLoading: Bool {
        stopped.lock()
        defer { stopped.unlock() }
        return isStopped
    }

    private func finish(_ ending: Stub.Ending) {
        switch ending {
        case .finished: client?.urlProtocolDidFinishLoading(self)
        case .error(let error): client?.urlProtocol(self, didFailWithError: error)
        case .never: break
        }
    }
}
