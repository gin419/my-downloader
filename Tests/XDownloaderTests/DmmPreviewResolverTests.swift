import XCTest

@testable import XDownloader

/// `DmmPreviewResolver` from the answer of the data request to a preview
/// clip: which field is picked, which addresses are turned down, what the
/// request carries, how an answer that is no data is classified, file names
/// and message copy. The answers are SYNTHETIC (invented ids, titles, makers
/// and addresses); the request is answered by a URLProtocol stub on an
/// injected session, so nothing here touches the network.
@MainActor
final class DmmPreviewResolverTests: XCTestCase {

    private typealias Resolver = DmmPreviewResolver

    private let link = "https://video.dmm.co.jp/cinema/content/?id=test00123"

    override func tearDown() {
        StubProtocol.removeAll()
    }

    // MARK: - Fixtures

    func testStandardPreview() throws {
        XCTAssertEqual(
            Resolver.classify(response: try fixture("dmm_preview_2d.json"), contentID: "test00123"),
            .success(
                Resolver.Preview(
                    address: try XCTUnwrap(
                        URL(string: "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/test00123hhb.mp4")),
                    title: "Synthetic Sample Title", maker: "Synthetic Maker", contentID: "test00123", kind: .standard)))
    }

    func testStandardPreviewWithTheOlderFileNaming() throws {
        let preview = try Resolver.classify(response: try fixture("dmm_preview_2d_legacy_suffix.json"), contentID: "test00123").get()
        // Byte for byte: the address is never rebuilt from its parts.
        XCTAssertEqual(
            preview.address.absoluteString,
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/test00123_mhb_w.mp4")
        XCTAssertEqual(preview.kind, .standard)
    }

    func testVRPreview() throws {
        let preview = try Resolver.classify(response: try fixture("dmm_preview_vr.json"), contentID: "testvr00045").get()
        XCTAssertEqual(
            preview.address.absoluteString,
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/testvr00045vruhq.mp4")
        XCTAssertEqual(preview.kind, .vr)
        XCTAssertEqual(preview.contentID, "testvr00045")
        XCTAssertEqual(preview.maker, "Synthetic Maker")
    }

    func testWorkWithoutPreview() throws {
        XCTAssertEqual(Resolver.classify(response: try fixture("dmm_no_preview.json"), contentID: "test00123"), .failure(.noPreview))
    }

    func testUnknownWork() throws {
        XCTAssertEqual(Resolver.classify(response: try fixture("dmm_not_found.json"), contentID: "test00123"), .failure(.notFound))
    }

    func testDeniedRegionOutranksAPreviewInTheAnswer() throws {
        let answer = try fixture("dmm_region_denied.json")
        XCTAssertTrue(String(decoding: answer, as: UTF8.self).contains("test00123hhb.mp4"))
        XCTAssertEqual(Resolver.classify(response: answer, contentID: "test00123"), .failure(.regionBlocked))
    }

    func testRefusedQueryIsAChangedFormat() throws {
        XCTAssertEqual(Resolver.classify(response: try fixture("dmm_changed_format.json"), contentID: "test00123"), .failure(.changedFormat))
    }

    func testEveryFixtureHasATest() throws {
        // A fixture added without a test would sit in the repo proving nothing.
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let answers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("dmm_") }
        XCTAssertEqual(
            Set(answers),
            [
                "dmm_preview_2d.json", "dmm_preview_2d_legacy_suffix.json", "dmm_preview_vr.json", "dmm_no_preview.json",
                "dmm_not_found.json", "dmm_region_denied.json", "dmm_changed_format.json",
            ])
    }

    // MARK: - Preference order

    func testStandardFileWinsOverVRAndStream() throws {
        let answer = try self.answer(
            standard: ["highestMovieUrl": "https://cc3001.dmm.co.jp/pv/SYNa/test00123hhb.mp4", "hlsMovieUrl": streamAddress],
            vr: ["highestMovieUrl": "https://cc3001.dmm.co.jp/pv/SYNb/test00123vruhq.mp4"])
        let preview = try Resolver.classify(response: answer, contentID: "test00123").get()
        XCTAssertEqual(preview.kind, .standard)
        XCTAssertEqual(preview.address.absoluteString, "https://cc3001.dmm.co.jp/pv/SYNa/test00123hhb.mp4")
    }

    func testVRFileWinsOverTheStream() throws {
        let answer = try self.answer(
            standard: ["highestMovieUrl": NSNull(), "hlsMovieUrl": streamAddress],
            vr: ["highestMovieUrl": "https://cc3001.dmm.co.jp/pv/SYNb/test00123vruhq.mp4"])
        let preview = try Resolver.classify(response: answer, contentID: "test00123").get()
        XCTAssertEqual(preview.kind, .vr)
        XCTAssertEqual(preview.address.absoluteString, "https://cc3001.dmm.co.jp/pv/SYNb/test00123vruhq.mp4")
    }

    func testStreamIsTheLastResort() throws {
        let answer = try self.answer(standard: ["highestMovieUrl": "", "hlsMovieUrl": streamAddress], vr: NSNull())
        let preview = try Resolver.classify(response: answer, contentID: "test00123").get()
        XCTAssertEqual(preview.kind, .stream)
        XCTAssertEqual(preview.address.absoluteString, streamAddress)
    }

    func testEmptySamplesAreNoPreview() throws {
        let empty = try answer(standard: ["highestMovieUrl": NSNull(), "hlsMovieUrl": NSNull()], vr: ["highestMovieUrl": ""])
        XCTAssertEqual(Resolver.classify(response: empty, contentID: "test00123"), .failure(.noPreview))
    }

    /// "No preview" is said of samples that are plainly empty. A sample or
    /// an address of another type is the site having reshaped its answer —
    /// read as "no preview", every work would seem to have none.
    func testSamplesOfAnotherTypeAreAChangedFormatNotAMissingPreview() throws {
        let emptyStandard: [String: Any] = ["highestMovieUrl": NSNull(), "hlsMovieUrl": NSNull()]
        let file = "https://cc3001.dmm.co.jp/pv/SYNa/test00123hhb.mp4"
        let reshaped: [(name: String, standard: Any, vr: Any)] = [
            ("a list of samples", [["highestMovieUrl": file, "hlsMovieUrl": NSNull()]], NSNull()),
            ("a sample given as text", file, NSNull()),
            ("a sample given as a number", 1, NSNull()),
            ("an address given as an object", ["highestMovieUrl": ["url": file], "hlsMovieUrl": NSNull()], NSNull()),
            ("an address given as a number", ["highestMovieUrl": 1, "hlsMovieUrl": NSNull()], NSNull()),
            ("an address under another name", ["bestMovieUrl": file], NSNull()),
            ("a list of VR samples", NSNull(), [["highestMovieUrl": file]]),
            ("a VR address given as an object", emptyStandard, ["highestMovieUrl": ["url": file]]),
        ]
        for c in reshaped {
            let answer = try self.answer(standard: c.standard, vr: c.vr)
            XCTAssertEqual(Resolver.classify(response: answer, contentID: "test00123"), .failure(.changedFormat), c.name)
        }
        // Plainly empty, in every spelling of empty.
        let empty: [(standard: Any, vr: Any)] = [
            (NSNull(), NSNull()),
            (emptyStandard, NSNull()),
            (["highestMovieUrl": "", "hlsMovieUrl": "  "], ["highestMovieUrl": NSNull()]),
        ]
        for c in empty {
            let answer = try self.answer(standard: c.standard, vr: c.vr)
            XCTAssertEqual(Resolver.classify(response: answer, contentID: "test00123"), .failure(.noPreview))
        }
        // A preview that is there is still found beside a sample that
        // cannot be read.
        let mixed = try self.answer(standard: ["highestMovieUrl": file, "hlsMovieUrl": 1], vr: [1])
        XCTAssertEqual(try Resolver.classify(response: mixed, contentID: "test00123").get().address.absoluteString, file)
    }

    func testARefusedAddressIsNeverReplacedByTheNextOne() throws {
        // The first address present is the answer; one that fails the check
        // means the format changed, not "try the VR preview instead".
        let answer = try self.answer(
            standard: ["highestMovieUrl": "https://example.com/test00123hhb.mp4", "hlsMovieUrl": streamAddress],
            vr: ["highestMovieUrl": "https://cc3001.dmm.co.jp/pv/SYNb/test00123vruhq.mp4"])
        XCTAssertEqual(Resolver.classify(response: answer, contentID: "test00123"), .failure(.changedFormat))
    }

    func testOnlyTheFreeSampleFieldsAreRead() throws {
        // Addresses anywhere else in the answer are not the preview, and a
        // work without a free sample stays a work without a preview.
        var work = self.work(standard: NSNull(), vr: NSNull())
        work["products"] = [["id": "synthetic-product", "movieUrl": "https://cc3001.dmm.co.jp/pv/SYNz/other.mp4"]]
        work["movieUrl"] = "https://cc3001.dmm.co.jp/pv/SYNz/other.mp4"
        let answer = try JSONSerialization.data(withJSONObject: ["data": ["ipInfo": ["accessStatus": "ALLOW"], "ppvContent": work]])
        XCTAssertEqual(Resolver.classify(response: answer, contentID: "test00123"), .failure(.noPreview))
        XCTAssertFalse(Resolver.query.contains("products"))
        XCTAssertFalse(String(decoding: try XCTUnwrap(Resolver.request(contentID: "test00123").httpBody), as: UTF8.self).contains("products"))
    }

    // MARK: - Names in the answer

    func testMissingNamesFallBack() throws {
        var work = self.work(standard: ["highestMovieUrl": "https://cc3001.dmm.co.jp/pv/SYNa/test00123hhb.mp4"], vr: NSNull())
        work["maker"] = NSNull()
        work["title"] = NSNull()
        work["id"] = NSNull()
        let answer = try JSONSerialization.data(withJSONObject: ["data": ["ppvContent": work]])
        let preview = try Resolver.classify(response: answer, contentID: "test00123").get()
        XCTAssertEqual(preview.maker, "dmm")
        XCTAssertEqual(preview.title, "")
        XCTAssertEqual(preview.contentID, "test00123")
    }

    func testAnUnusableIdInTheAnswerNeverReachesTheFileName() throws {
        var work = self.work(standard: ["highestMovieUrl": "https://cc3001.dmm.co.jp/pv/SYNa/test00123hhb.mp4"], vr: NSNull())
        work["id"] = "../../example"
        let answer = try JSONSerialization.data(withJSONObject: ["data": ["ppvContent": work]])
        XCTAssertEqual(try Resolver.classify(response: answer, contentID: "test00123").get().contentID, "test00123")
    }

    // MARK: - Region

    func testRegionRules() throws {
        let sample = ["highestMovieUrl": "https://cc3001.dmm.co.jp/pv/SYNa/test00123hhb.mp4"]
        func classified(status: Any, offeredAbroad: Any) throws -> Result<Resolver.Preview, Resolver.Failure> {
            var work = self.work(standard: sample, vr: NSNull())
            work["isAllowForeign"] = offeredAbroad
            let answer = try JSONSerialization.data(withJSONObject: ["data": ["ipInfo": ["accessStatus": status], "ppvContent": work]])
            return Resolver.classify(response: answer, contentID: "test00123")
        }
        XCTAssertEqual(try classified(status: "DENY", offeredAbroad: true), .failure(.regionBlocked))
        // A visitor from abroad with reduced service: only works not
        // offered abroad are withheld.
        XCTAssertEqual(try classified(status: "RESTRICT_FUNCTION", offeredAbroad: false), .failure(.regionBlocked))
        XCTAssertEqual(try classified(status: "RESTRICT_FUNCTION", offeredAbroad: true).get().kind, .standard)
        XCTAssertEqual(try classified(status: "ALLOW", offeredAbroad: false).get().kind, .standard)
        XCTAssertEqual(try classified(status: NSNull(), offeredAbroad: false).get().kind, .standard)
    }

    // MARK: - Changed format

    func testAnswersInAnotherShapeAreAChangedFormat() throws {
        let answers: [String] = [
            "",
            "not json",
            "<html>welcome</html>",
            "[]",
            "null",
            "{}",
            #"{"data": null}"#,
            #"{"data": []}"#,
            #"{"data": {}}"#,
            #"{"data": {"ipInfo": {"accessStatus": "ALLOW"}}}"#,
            #"{"data": {"ppvContent": "test00123"}}"#,
            #"{"data": {"ppvContent": {}}}"#,
            #"{"data": {"ppvContent": {"id": "test00123", "sample2DMovie": null}}}"#,
            #"{"data": {"ppvContent": {"id": "test00123", "sampleVRMovie": null}}}"#,
            // The sample field of an older format.
            #"{"data": {"ppvContent": {"id": "test00123", "sampleMovie": {"has2D": true}}}}"#,
            #"{"errors": [{"message": "synthetic"}], "data": {"ppvContent": null}}"#,
        ]
        for answer in answers {
            XCTAssertEqual(Resolver.classify(response: Data(answer.utf8), contentID: "test00123"), .failure(.changedFormat), answer)
        }
    }

    // MARK: - Address validation

    func testOnlyHTTPSFilesAndStreamsOnTheSitesHostsArePreviews() {
        let accepted = [
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123_mhb_w.mp4",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenBBBB/playlist.m3u8",
            "https://other-host.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.MP4",
            "HTTPS://CC3001.DMM.CO.JP/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4?x=1",
        ]
        for address in accepted {
            XCTAssertEqual(Resolver.previewAddress(address)?.absoluteString, address, address)
        }
        let refused = [
            "http://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "ftp://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "file:///tmp/example/test00123hhb.mp4",
            "//cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            // Other hosts, and hosts made to look like the site's.
            "https://example.com/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://cc3001.dmm.com/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://notdmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://cc3001.dmm.co.jp.example.com/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://cc3001.dmm.co.jp@example.com/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://user@cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://example.com/cc3001.dmm.co.jp/test00123hhb.mp4",
            "https://example.com/?u=https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            // Not a file or a stream.
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.html",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mpd",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/player?file=test00123hhb.mp4",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/player#test00123hhb.mp4",
            "--exec=example.mp4",
            "",
        ]
        for address in refused {
            XCTAssertNil(Resolver.previewAddress(address), address)
        }
    }

    // MARK: - The request

    func testRequestIsOnePostCarryingTheIdAndNoCookie() throws {
        let request = Resolver.request(contentID: "test00123")
        XCTAssertEqual(request.url?.absoluteString, "https://api.video.dmm.co.jp/graphql")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, DirectDownload.requestTimeout)
        XCTAssertEqual(request.httpShouldHandleCookies, false)

        let headers = try XCTUnwrap(request.allHTTPHeaderFields)
        XCTAssertEqual(Set(headers.keys), ["Content-Type", "Accept", "User-Agent", "Referer"])
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(headers["Accept"], "application/json")
        XCTAssertEqual(headers["Referer"], "https://video.dmm.co.jp/")
        XCTAssertEqual(headers["User-Agent"]?.contains("Chrome/"), true)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["operationName", "query", "variables"])
        XCTAssertEqual(body["variables"] as? [String: String], ["id": "test00123"])
        XCTAssertEqual(body["operationName"] as? String, Resolver.operationName)
        XCTAssertEqual(body["query"] as? String, Resolver.query)
    }

    func testQueryAsksForTheFreeSampleFieldsAndNothingPurchasable() {
        for field in ["sample2DMovie", "sampleVRMovie", "highestMovieUrl", "hlsMovieUrl", "accessStatus", "isAllowForeign"] {
            XCTAssertTrue(Resolver.query.contains(field), field)
        }
        for field in ["products", "price", "license", "deliveryUnit", "QualityGroup", "purchase"] {
            XCTAssertFalse(Resolver.query.lowercased().contains(field.lowercased()), field)
        }
    }

    // MARK: - Transport (URLProtocol stub, no network)

    func testResolveMakesOneRequestWithoutCookies() async throws {
        StubProtocol.set(json(try fixture("dmm_preview_2d.json")), for: Resolver.endpoint)

        let outcome = await Resolver.resolve(link: "http://VIDEO.DMM.CO.JP/cinema/content?id=TEST00123&utm_source=x", session: stubSession())

        guard case .resolved(let preview) = outcome else { return XCTFail("expected a preview, got \(outcome)") }
        XCTAssertEqual(preview.kind, .standard)
        XCTAssertEqual(preview.contentID, "test00123")
        let requests = StubProtocol.requests(to: Resolver.endpoint)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        // The body's length is the session's own addition, and the only one.
        var sent = try XCTUnwrap(requests.first?.allHTTPHeaderFields)
        sent["Content-Length"] = nil
        XCTAssertEqual(sent, Resolver.requestHeaders)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(requests.first?.httpShouldHandleCookies, false)
    }

    func testDefaultSessionKeepsAndSendsNoCookies() {
        let configuration = DirectDownload.session.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }

    func testALinkThatNamesNoWorkMakesNoRequest() async {
        let links = [
            "https://video.dmm.co.jp/cinema/list/?sort=date",
            "https://video.dmm.co.jp/cinema/content/",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://example.com/?next=https://video.dmm.co.jp/cinema/content/?id=test00123",
        ]
        for link in links {
            let outcome = await Resolver.resolve(link: link, session: stubSession())
            XCTAssertEqual(outcome, .failed(.notAWorkPage), link)
        }
        XCTAssertTrue(StubProtocol.requests(to: Resolver.endpoint).isEmpty)
    }

    func testFixtureAnswersThroughTheSession() async throws {
        let cases: [(fixture: String, expected: Resolver.Failure)] = [
            ("dmm_no_preview.json", .noPreview),
            ("dmm_not_found.json", .notFound),
            ("dmm_region_denied.json", .regionBlocked),
            ("dmm_changed_format.json", .changedFormat),
        ]
        for c in cases {
            StubProtocol.set(json(try fixture(c.fixture)), for: Resolver.endpoint)
            let outcome = await Resolver.resolve(link: link, session: stubSession())
            XCTAssertEqual(outcome, .failed(c.expected), c.fixture)
        }
    }

    func testRedirectIsRefused() throws {
        let otherPage = try XCTUnwrap(URL(string: "https://www.dmm.co.jp/welcome/?rurl=https%3A%2F%2Fapi.video.dmm.co.jp%2Fgraphql"))
        let response = try XCTUnwrap(
            HTTPURLResponse(url: Resolver.endpoint, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": otherPage.absoluteString]))
        let session = stubSession()
        var answers: [URLRequest?] = []

        Resolver.RedirectRefusal().urlSession(
            session, task: session.dataTask(with: Resolver.request(contentID: "test00123")), willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: otherPage)
        ) { answers.append($0) }

        XCTAssertEqual(answers, [nil])
        XCTAssertTrue(StubProtocol.requests(to: otherPage).isEmpty)
    }

    func testRedirectAnswerToAnotherPageIsAChangedFormat() async throws {
        // The redirect as the session hands it over once it was refused.
        let otherPage = try XCTUnwrap(URL(string: "https://www.dmm.co.jp/welcome/?rurl=https%3A%2F%2Fapi.video.dmm.co.jp%2Fgraphql"))
        StubProtocol.set(.init(status: 302, headers: ["Location": otherPage.absoluteString], body: Data()), for: Resolver.endpoint)
        StubProtocol.set(json(try fixture("dmm_preview_2d.json")), for: otherPage)

        let outcome = await Resolver.resolve(link: link, session: stubSession())

        XCTAssertEqual(outcome, .failed(.changedFormat))
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 1)
        XCTAssertTrue(StubProtocol.requests(to: otherPage).isEmpty, "the redirect was followed")
    }

    func testRedirectAnswerToTheRegionNoticeIsARegionBlock() async throws {
        let notice = try XCTUnwrap(URL(string: "https://special.dmm.co.jp/not-available-in-your-region/allservice/"))
        StubProtocol.set(.init(status: 302, headers: ["Location": notice.absoluteString], body: Data()), for: Resolver.endpoint)

        let outcome = await Resolver.resolve(link: link, session: stubSession())

        XCTAssertEqual(outcome, .failed(.regionBlocked))
        XCTAssertTrue(StubProtocol.requests(to: notice).isEmpty, "the redirect was followed")
    }

    func testStatusAndContentTypeThroughTheSession() async throws {
        let preview = try fixture("dmm_preview_2d.json")
        let cases: [(stub: StubProtocol.Stub, expected: Resolver.Failure)] = [
            (.init(status: 403, headers: ["Content-Type": "application/json"], body: preview), .regionBlocked),
            (.init(status: 451, headers: ["Content-Type": "text/html"], body: Data()), .regionBlocked),
            (.init(status: 500, headers: ["Content-Type": "application/json"], body: preview), .network),
            (.init(status: 503, headers: ["Content-Type": "text/html"], body: Data()), .network),
            (.init(status: 429, headers: ["Content-Type": "text/html"], body: Data()), .network),
            (.init(status: 404, headers: ["Content-Type": "application/json"], body: preview), .changedFormat),
            (.init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: preview), .changedFormat),
            (.init(status: 200, headers: [:], body: preview), .changedFormat),
            (.init(status: 200, headers: ["Content-Type": "application/json"], body: Data("<html></html>".utf8)), .changedFormat),
            (.init(status: 200, headers: ["Content-Type": "application/json"], body: Data()), .changedFormat),
            (.init(status: 200, headers: ["Content-Type": "application/json"], body: Data(), ending: .error(URLError(.timedOut))), .network),
            (
                .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(), ending: .error(URLError(.notConnectedToInternet))),
                .network
            ),
            (.init(status: 200, headers: ["Content-Type": "application/json"], body: preview, isHTTP: false), .changedFormat),
        ]
        for (index, c) in cases.enumerated() {
            StubProtocol.set(c.stub, for: Resolver.endpoint)
            let outcome = await Resolver.resolve(link: link, session: stubSession())
            XCTAssertEqual(outcome, .failed(c.expected), "case \(index)")
        }
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, cases.count, "one request per attempt, no retry")
    }

    func testClassifyTransportTable() {
        let json = "application/json; charset=utf-8"
        let cases: [(status: Int, target: String?, type: String?, body: String, expected: Resolver.Failure?)] = [
            (200, nil, json, "{}", nil),
            (200, nil, "APPLICATION/JSON", "{}", nil),
            (204, nil, json, "", nil),
            (302, "https://www.dmm.co.jp/welcome/?rurl=x", "text/html", "", .changedFormat),
            (302, "https://special.dmm.co.jp/not-available-in-your-region/allservice/", "text/html", "", .regionBlocked),
            (301, "https://example.com/", json, "{}", .changedFormat),
            (307, nil, json, "{}", .changedFormat),
            (403, nil, json, "{}", .regionBlocked),
            (451, nil, json, "{}", .regionBlocked),
            (408, nil, json, "{}", .network),
            (429, nil, json, "{}", .network),
            (500, nil, json, "{}", .network),
            (502, nil, "text/html", "", .network),
            (400, nil, json, "{}", .changedFormat),
            (404, nil, json, "{}", .changedFormat),
            (200, nil, "text/html", "<html>welcome</html>", .changedFormat),
            (200, nil, "text/html", "<html>not-available-in-your-region</html>", .regionBlocked),
            (200, nil, nil, "{}", .changedFormat),
        ]
        for c in cases {
            XCTAssertEqual(
                Resolver.classifyTransport(status: c.status, redirectTarget: c.target, contentType: c.type, body: Data(c.body.utf8)),
                c.expected, "\(c.status) \(c.target ?? "-") \(c.type ?? "-")")
        }
    }

    func testCancelIsNotAFailure() async throws {
        var stub = json(try fixture("dmm_preview_2d.json"))
        stub.ending = .never
        StubProtocol.set(stub, for: Resolver.endpoint)
        let session = stubSession()
        let link = self.link

        let task = Task { await Resolver.resolve(link: link, session: session) }
        for _ in 0..<200 where StubProtocol.requests(to: Resolver.endpoint).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(StubProtocol.requests(to: Resolver.endpoint).count, 1)
    }

    // MARK: - File names

    func testFileStemMatchesTheShapeOfXDownloads() {
        XCTAssertEqual(
            Resolver.fileStem(maker: "Synthetic Maker", title: "Synthetic Sample Title", contentID: "test00123"),
            "Synthetic Maker - Synthetic Sample Title [test00123]")
        // Same sanitizing as X: separators and line breaks can't reach the file system.
        XCTAssertEqual(
            Resolver.fileStem(maker: "A/B", title: "line one\nline two", contentID: "test00123"), "A_B - line one line two [test00123]")
        XCTAssertEqual(Resolver.fileStem(maker: "Synthetic Maker", title: "", contentID: "test00123"), "Synthetic Maker -  [test00123]")
        // The same stem as a Threads post of the same parts would get.
        XCTAssertEqual(
            Resolver.fileStem(maker: "Synthetic Maker", title: "one\ttwo\u{202E}three", contentID: "test00123"),
            ThreadsService.fileStem(author: "Synthetic Maker", text: "one\ttwo\u{202E}three", code: "test00123"))
    }

    func testFileStemNeverMakesAHiddenFileAndNamesAnUnknownMaker() {
        XCTAssertEqual(Resolver.fileStem(maker: ".studio", title: "hello", contentID: "test00123"), "studio - hello [test00123]")
        XCTAssertEqual(Resolver.fileStem(maker: "...", title: "hello", contentID: "test00123"), "dmm - hello [test00123]")
        XCTAssertEqual(Resolver.fileStem(maker: "", title: "hello", contentID: "test00123"), "dmm - hello [test00123]")
    }

    func testFileStemCutsTheTitleAt100Characters() {
        // Characters, not bytes: "é" is one character and two bytes.
        let title = String(repeating: "é", count: 99) + "ab"
        XCTAssertEqual(
            Resolver.fileStem(maker: "Synthetic Maker", title: title, contentID: "test00123"),
            "Synthetic Maker - " + String(repeating: "é", count: 99) + "a [test00123]")
    }

    func testFileStemFitsAFileNameWhateverTheScript() {
        // 100 Japanese characters are 300 bytes, more than a file name holds.
        let stem = Resolver.fileStem(maker: "Synthetic Maker", title: String(repeating: "字", count: 150), contentID: "test00123")
        XCTAssertLessThanOrEqual(stem.utf8.count, ThreadsService.maxStemBytes)
        XCTAssertTrue(stem.hasPrefix("Synthetic Maker - 字字字"))
        XCTAssertTrue(stem.hasSuffix("字 [test00123]"), "the id must survive the cut")
        XCTAssertGreaterThan(stem.utf8.count, ThreadsService.maxStemBytes - 3)
    }

    func testDisplayTitleIsTheStemWithoutItsId() {
        XCTAssertEqual(Resolver.displayTitle(maker: "Synthetic Maker", title: "line one\nline two"), "Synthetic Maker - line one line two")
        XCTAssertEqual(Resolver.displayTitle(maker: "Synthetic Maker", title: ""), "Synthetic Maker")
        XCTAssertEqual(Resolver.displayTitle(maker: "", title: "Synthetic Sample Title"), "dmm - Synthetic Sample Title")
        // The convention of the Threads rows.
        XCTAssertEqual(
            Resolver.displayTitle(maker: "Synthetic Maker", title: "Synthetic Sample Title"),
            ThreadsService.displayTitle(author: "Synthetic Maker", text: "Synthetic Sample Title"))
    }

    // MARK: - Messages

    func testMessageConstantsAreTheLiteralCopy() {
        XCTAssertEqual(
            Resolver.notAWorkPageMessage, "This link isn't a work page — open the work's own page and paste its link instead.")
        XCTAssertEqual(
            Resolver.notFoundMessage,
            "Work not found — it may have been removed, or the link may be incomplete; check the link, then Retry.")
        XCTAssertEqual(
            Resolver.noPreviewMessage,
            "This work has no free preview clip, so there is nothing to download. "
                + "Purchased, rental and subscription videos are not supported.")
        XCTAssertEqual(
            Resolver.regionBlockedMessage,
            "Not available in your region — the site doesn't offer this preview clip where your connection is located.")
        XCTAssertEqual(
            Resolver.changedFormatMessage,
            "The site changed its data format, so the preview clip couldn't be found — update XDownloader, then Retry.")
        XCTAssertEqual(
            Resolver.networkMessage, "Couldn't reach the site to find the preview clip — check the connection, then Retry.")
        XCTAssertEqual(Resolver.paidVideosNotSupportedMessage, "Purchased, rental and subscription videos are not supported.")
    }

    func testEveryFailureHasItsOwnMessage() {
        let messages = Resolver.Failure.allCases.map(Resolver.message(for:))
        XCTAssertEqual(Resolver.Failure.allCases.count, 6)
        XCTAssertEqual(Set(messages).count, Resolver.Failure.allCases.count)
        XCTAssertEqual(Resolver.message(for: .notAWorkPage), Resolver.notAWorkPageMessage)
        XCTAssertEqual(Resolver.message(for: .notFound), Resolver.notFoundMessage)
        XCTAssertEqual(Resolver.message(for: .noPreview), Resolver.noPreviewMessage)
        XCTAssertEqual(Resolver.message(for: .regionBlocked), Resolver.regionBlockedMessage)
        XCTAssertEqual(Resolver.message(for: .changedFormat), Resolver.changedFormatMessage)
        XCTAssertEqual(Resolver.message(for: .network), Resolver.networkMessage)
        XCTAssertNotEqual(Resolver.noPreviewMessage, Resolver.changedFormatMessage)
    }

    func testMessagesNeverSuggestCookiesOrSignIn() {
        // The site is only ever asked logged out: no message may send the
        // owner looking for a login to fix it with.
        for message in Resolver.Failure.allCases.map(Resolver.message(for:)) {
            for word in ["cookie", "sign in", "sign-in", "log in", "login"] {
                XCTAssertFalse(message.lowercased().contains(word), "\(word): \(message)")
            }
        }
        // Where a Retry cannot change the outcome, none is promised.
        for message in [Resolver.notAWorkPageMessage, Resolver.noPreviewMessage, Resolver.regionBlockedMessage] {
            XCTAssertFalse(message.contains("Retry"), message)
        }
        for message in [Resolver.notFoundMessage, Resolver.changedFormatMessage, Resolver.networkMessage] {
            XCTAssertTrue(message.hasSuffix("then Retry."), message)
        }
        XCTAssertTrue(Resolver.noPreviewMessage.hasSuffix(Resolver.paidVideosNotSupportedMessage))
    }

    // MARK: - Helpers

    private let streamAddress = "https://cc3001.dmm.co.jp/pv/SYNs/playlist.m3u8"

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func work(standard: Any, vr: Any) -> [String: Any] {
        [
            "id": "test00123", "title": "Synthetic Sample Title", "isAllowForeign": true, "maker": ["name": "Synthetic Maker"],
            "sample2DMovie": standard, "sampleVRMovie": vr,
        ]
    }

    private func answer(standard: Any, vr: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["data": ["ipInfo": ["accessStatus": "ALLOW"], "ppvContent": work(standard: standard, vr: vr)]])
    }

    private func json(_ body: Data) -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "application/json; charset=utf-8"], body: body)
    }

    private func stubSession() -> URLSession {
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}
