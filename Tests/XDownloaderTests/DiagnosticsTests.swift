import XCTest

@testable import XDownloader

/// The diagnostic record a failed run leaves: nothing of the user's login
/// in it, tool arguments and output masked, the request kept with its
/// answer, and the records folder kept small.
@MainActor
final class DiagnosticsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - No login in a record

    func testRecordFromRequestWithLoginHeadersHoldsNeitherValue() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/page?id=1&access_token=QUERYSECRET"))
        var request = URLRequest(url: url)
        request.setValue("auth_token=COOKIESECRET; ct0=CSRFSECRET", forHTTPHeaderField: "Cookie")
        request.setValue("Bearer AUTHSECRET", forHTTPHeaderField: "Authorization")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Set-Cookie": "sessionid=SETCOOKIESECRET", "Content-Type": "text/html"]))
        let trail = DiagnosticTrail()
        trail.record(
            DiagnosticTrail.exchange(
                label: "page", request: request, response: response, data: Data("<html>ok</html>".utf8), error: nil,
                started: Date(), keepBody: true))
        trail.step("fallback: youtubePost")

        let made = DiagnosticsStore.makeRecord(
            url: url.absoluteString, siteID: "youtube", message: "failed", tools: [:], trail: trail)
        let folder = try XCTUnwrap(DiagnosticsStore(directory: directory).write(made.record, bodies: made.bodies, id: "abc"))

        let everything = try allText(in: folder)
        for secret in ["COOKIESECRET", "CSRFSECRET", "AUTHSECRET", "SETCOOKIESECRET", "QUERYSECRET"] {
            XCTAssertFalse(everything.contains(secret), secret)
        }
        XCTAssertTrue(everything.contains("Mozilla/5.0"))
        XCTAssertTrue(everything.contains("<html>ok</html>"))
        XCTAssertEqual(made.record.failedStep, "fallback: youtubePost")
        XCTAssertEqual(made.record.exchanges.first?.requestHeaders["Cookie"], DiagnosticRedaction.redacted)
        XCTAssertEqual(made.record.exchanges.first?.requestHeaders["Authorization"], DiagnosticRedaction.redacted)
        XCTAssertEqual(made.record.exchanges.first?.responseHeaders["Set-Cookie"], DiagnosticRedaction.redacted)
    }

    func testBodyFetchedWithLoginIsNotKept() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/signed-in"))
        let exchange = DiagnosticTrail.exchange(
            label: "page", request: URLRequest(url: url), response: nil, data: Data("private".utf8), error: nil,
            started: Date(), keepBody: false)
        XCTAssertNil(exchange.body)
        XCTAssertEqual(exchange.bodyBytes, 7)
    }

    func testToolArgumentsAndOutputAreMasked() {
        let trail = DiagnosticTrail()
        let index = trail.beginToolRun(
            executable: "/opt/homebrew/bin/yt-dlp",
            arguments: [
                "--cookies", "/tmp/cookies.txt", "--add-header", "Cookie: auth_token=ARGSECRET",
                "--add-header=Authorization: Bearer ARGBEARER", "--password", "ARGPASSWORD", "--username=ARGUSER",
                "--add-header", "Referer: https://www.pixiv.net/", "https://x.com/a/status/1",
            ])
        trail.appendOutput("[debug] Request headers: {'Cookie': 'ct0=OUTSECRET; auth_token=OUTTOKEN'}", toRun: index)
        trail.appendOutput("ERROR: something failed", toRun: index)
        trail.endToolRun(index, exitCode: 1, wasSignal: false)

        let run = trail.toolRuns[0]
        let joined = run.arguments.joined(separator: " ") + run.outputTail
        for secret in ["ARGSECRET", "ARGBEARER", "ARGPASSWORD", "ARGUSER", "OUTSECRET", "OUTTOKEN"] {
            XCTAssertFalse(joined.contains(secret), secret)
        }
        XCTAssertEqual(run.tool, "yt-dlp")
        XCTAssertTrue(run.arguments.contains("/tmp/cookies.txt"))
        XCTAssertTrue(run.arguments.contains("Referer: https://www.pixiv.net/"))
        XCTAssertTrue(run.arguments.contains("https://x.com/a/status/1"))
        XCTAssertTrue(run.outputTail.contains("ERROR: something failed"))
        XCTAssertEqual(run.exitCode, 1)
    }

    func testToolOutputKeepsOnlyItsTail() {
        let trail = DiagnosticTrail()
        let index = trail.beginToolRun(executable: "gallery-dl", arguments: [])
        let line = String(repeating: "a", count: 1000)
        for _ in 0..<1200 { trail.appendOutput(line, toRun: index) }
        trail.appendOutput("LAST LINE", toRun: index)
        let run = trail.toolRuns[0]
        XCTAssertLessThanOrEqual(run.outputTail.utf8.count, DiagnosticTrail.outputCap)
        XCTAssertTrue(run.outputTruncated)
        XCTAssertTrue(run.outputTail.hasSuffix("LAST LINE\n"))
    }

    // MARK: - Requests through the trail

    func testRequestInsideARunIsRecordedWithItsAnswer() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/item/1"))
        StubProtocol.set(
            .init(status: 403, headers: ["Content-Type": "application/json"], body: Data(#"{"error":true}"#.utf8)), for: url)
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let trail = DiagnosticTrail()

        _ = try await DiagnosticTrail.$current.withValue(trail) {
            try await DiagnosticTrail.data(for: URLRequest(url: url), session: session, label: "api")
        }

        let exchange = try XCTUnwrap(trail.exchanges.first)
        XCTAssertEqual(exchange.status, 403)
        XCTAssertEqual(exchange.label, "api")
        XCTAssertEqual(exchange.body, Data(#"{"error":true}"#.utf8))
        let made = DiagnosticsStore.makeRecord(url: url.absoluteString, siteID: "other", message: "m", tools: [:], trail: trail)
        XCTAssertEqual(made.record.exchanges.first?.bodyFile, "body-01-api.json")
    }

    func testRequestOutsideARunIsNotRecordedAnywhere() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/item/2"))
        StubProtocol.set(.init(status: 200, headers: [:], body: Data("x".utf8)), for: url)
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        XCTAssertNil(DiagnosticTrail.current)
        _ = try await DiagnosticTrail.data(for: URLRequest(url: url), session: URLSession(configuration: configuration), label: "api")
    }

    func testTrailIsWrittenOnlyOnce() {
        let trail = DiagnosticTrail()
        XCTAssertTrue(trail.claimWrite())
        XCTAssertFalse(trail.claimWrite())
    }

    // MARK: - Keeping the folder small

    func testPruneKeepsTheNewestRecordsAndDropsOldOnes() throws {
        let fm = FileManager.default
        for index in 0..<(DiagnosticsStore.maxRecords + 5) {
            try fm.createDirectory(
                at: directory.appendingPathComponent(String(format: "20261024-%06d-site-x", index)), withIntermediateDirectories: true)
        }
        let old = directory.appendingPathComponent("20260101-000000-site-old")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.setAttributes([.creationDate: Date().addingTimeInterval(-40 * 24 * 60 * 60)], ofItemAtPath: old.path)

        DiagnosticsStore(directory: directory).prune()

        let left = try fm.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left.count, DiagnosticsStore.maxRecords)
        XCTAssertFalse(left.contains(old.lastPathComponent))
        XCTAssertFalse(left.contains("20261024-000000-site-x"))
        XCTAssertTrue(left.contains(String(format: "20261024-%06d-site-x", DiagnosticsStore.maxRecords + 4)))
    }

    func testDisabledStoreWritesNothing() {
        let made = DiagnosticsStore.makeRecord(url: "https://x.com", siteID: "x", message: "m", tools: [:], trail: DiagnosticTrail())
        XCTAssertNil(DiagnosticsStore(directory: nil).write(made.record, bodies: made.bodies, id: "id"))
    }

    func testLiveStoreIsOffUnderTests() {
        XCTAssertNil(DiagnosticsStore.live.directory)
    }

    // MARK: - Helpers

    private func allText(in folder: URL) throws -> String {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
            .joined(separator: "\n")
    }
}
