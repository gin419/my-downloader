import XCTest

@testable import XDownloader

final class LikesSyncEventParserTests: XCTestCase {
    func testFailureClassificationCoversActionableCategories() {
        XCTAssertEqual(LikesSyncFailureCategory.classify("login required"), .authentication)
        XCTAssertEqual(LikesSyncFailureCategory.classify("HTTP 429"), .rateLimited)
        XCTAssertEqual(LikesSyncFailureCategory.classify("connection reset"), .network)
        XCTAssertEqual(LikesSyncFailureCategory.classify("post deleted"), .unavailable)
        XCTAssertEqual(LikesSyncFailureCategory.classify("no space left on device"), .disk)
        XCTAssertEqual(LikesSyncFailureCategory.classify("unsupported URL"), .tool)
        XCTAssertEqual(LikesSyncFailureCategory.classify("JSON decode failed"), .parse)
    }

    func testParsesGalleryDlEventLine() {
        let line = """
            post:likes-sync\t{"tweet_id":"123","tweet_url":"https://x.com/a/status/123","content":"hello","author":"@Alice","media_id":"m1","media_url":"https://cdn/img.jpg","type":"image"}
            """
        let event = LikesSyncEventParser.parse(line)

        XCTAssertEqual(event?.name, .post)
        XCTAssertEqual(event?.tweetID, "123")
        XCTAssertEqual(event?.tweetURL, "https://x.com/a/status/123")
        XCTAssertEqual(event?.text, "hello")
        XCTAssertEqual(event?.authorHandle, "Alice")
        XCTAssertEqual(event?.mediaID, "m1")
        XCTAssertEqual(event?.mediaKind, "image")
    }

    /// gallery-dl's PrintAction partitions "--Print <event>:<format>" at the
    /// first ":" and CONSUMES the selector — real runs emit the STRIPPED
    /// "likes-sync\t<event>:{json}" form, never the prefixed one. Both must
    /// parse identically: the stripped form because production depends on
    /// it, the prefixed form as belt-and-braces.
    func testBothWireFormsParseIdentically() {
        let json = #"{"tweet_id":"123","tweet_url":"https://x.com/a/status/123","media_id":"m1"}"#
        let stripped = LikesSyncEventParser.parse("likes-sync\tpost-after:\(json)")
        let prefixed = LikesSyncEventParser.parse("post-after:likes-sync\t\(json)")

        XCTAssertNotNil(stripped)
        XCTAssertEqual(stripped, prefixed)
        XCTAssertEqual(stripped?.name, .postAfter)
        XCTAssertEqual(stripped?.tweetID, "123")
        XCTAssertEqual(stripped?.mediaID, "m1")
    }

    /// A stripped line whose embedded selector is not a known event is not an
    /// event — and (see the diagnostics section) never a diagnostic either.
    func testStrippedLineWithUnknownEventDoesNotParse() {
        XCTAssertNil(LikesSyncEventParser.parse("likes-sync\tnope:{\"tweet_id\":\"1\"}"))
        XCTAssertNil(LikesSyncEventParser.parse("likes-sync\t{\"tweet_id\":\"1\"}"))
    }

    func testAccumulatorCountsUniqueTweetsMediaAndCategorizedFailures() {
        // The real (stripped) wire form throughout — see
        // testBothWireFormsParseIdentically.
        let lines = [
            "likes-sync\tprepare:{\"tweet_id\":\"123\",\"media_id\":\"m1\"}",
            "likes-sync\tpost:{\"tweet_id\":\"123\",\"media_id\":\"m1\"}",
            "likes-sync\tpost-after:{\"tweet_id\":\"123\",\"media_id\":\"m2\"}",
            "likes-sync\tskip:{\"tweet_id\":\"124\",\"media_id\":\"m3\",\"message\":\"No results for tweet\"}",
            "likes-sync\terror:{\"message\":\"429 Too Many Requests\"}",
        ]

        var summary = LikesSyncRunAccumulator()
        for line in lines {
            guard let event = LikesSyncEventParser.parse(line) else {
                return XCTFail("expected event for \(line)")
            }
            summary.apply(event)
        }

        XCTAssertEqual(summary.tweetCount, 2)
        XCTAssertEqual(summary.mediaCount, 3)
        XCTAssertEqual(summary.downloadedCount, 0)
        XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertEqual(summary.failureCount, 1)
        XCTAssertNil(summary.failures[.unavailable])
        XCTAssertEqual(summary.failures[.rateLimited], 1)
    }

    func testCountsDownloadedSkippedAndNoMediaSeparately() {
        let lines = [
            "likes-sync\tafter:{\"tweet_id\":\"1\",\"num\":1}",
            "likes-sync\tskip:{\"tweet_id\":\"1\",\"num\":2}",
            "likes-sync\tpost-after:{\"tweet_id\":\"1\"}",
            "likes-sync\tpost:{\"tweet_id\":\"2\"}",
            "likes-sync\tpost-after:{\"tweet_id\":\"2\"}",
        ]
        var summary = LikesSyncRunAccumulator()
        for line in lines { summary.apply(try! XCTUnwrap(LikesSyncEventParser.parse(line))) }
        XCTAssertEqual(summary.downloadedCount, 1)
        XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertEqual(summary.noMediaCount, 1)
        XCTAssertEqual(summary.failureCount, 0)
    }

    func testMalformedEventPayloadBecomesParseFailure() {
        for line in ["error:likes-sync\t{nope", "likes-sync\terror:{nope"] {
            let event = LikesSyncEventParser.parse(line)
            XCTAssertEqual(event?.name, .error, line)
            XCTAssertEqual(event?.failureCategory, .parse, line)
            XCTAssertEqual(event?.message, "Could not parse gallery-dl event JSON", line)
        }
    }

    // MARK: - Diagnostics capture (isUsefulDiagnostic)

    /// gallery-dl announces rate-limit pauses at info level and then WAITS —
    /// the run survives them. They must never enter the diagnostics buffer,
    /// where a flawless exit-0 run would turn them into a recorded failure.
    func testInfoLevelRateLimitWaitLinesAreNotDiagnostics() {
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic(
                "[twitter][info] Waiting for 60 seconds (rate limit)"))
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic(
                "[twitter][info] Waiting until 09:20:00 (429 Too Many Requests)"))
    }

    /// Some wait notices arrive without a bracketed level; the leading
    /// "Waiting" still marks them as progress, not failure.
    func testBareWaitingLinesAreNotDiagnostics() {
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic("Waiting until 09:20:00 (rate limit)"))
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic("  waiting for rate limit reset"))
    }

    /// Info/debug level lines are routine progress whatever they mention.
    func testInfoAndDebugLevelLinesAreNotDiagnostics() {
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic("[twitter][info] Login with cookies"))
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic(
                "[urllib3][debug] Starting new HTTPS connection"))
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic(
                "[cookies][info] Extracted 863 cookies from Chrome"))
    }

    /// A gallery-dl too old for this app's CLI options exits 2 printing
    /// argparse lines with no bracketed level. The filter must keep them —
    /// dropped, the failure card falls back to a bare exit code and blames
    /// the user's login for an outdated binary. Indented usage-continuation
    /// lines are noise and stay excluded.
    func testArgparseRejectionLinesAreCapturedAsDiagnostics() {
        XCTAssertTrue(
            LikesSyncEventParser.isUsefulDiagnostic("usage: gallery-dl [OPTION]... URL..."))
        XCTAssertTrue(
            LikesSyncEventParser.isUsefulDiagnostic(
                "gallery-dl: error: unrecognized arguments: --Print post:likes-sync"))
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic("                  [--filter EXPR] [--range RANGE]"))
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic("/tmp/likes/gin/img 123.jpg"),
            "plain output paths are progress, not diagnostics")
    }

    /// Python traceback tails ("KeyError: 'data'") are the stale-extractor
    /// crash signature; they carry no bracketed level either. Only the tail
    /// names the cause — the "Traceback" head and frame lines stay excluded.
    func testTracebackTailsAreCapturedButFrameLinesExcluded() {
        XCTAssertTrue(LikesSyncEventParser.isUsefulDiagnostic("KeyError: 'data'"))
        XCTAssertTrue(
            LikesSyncEventParser.isUsefulDiagnostic("ValueError: not enough values to unpack"))
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic("Traceback (most recent call last):"))
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic(
                "  File \"extractor/twitter.py\", line 1428, in _pagination_legacy"))
    }

    /// Keyword matching only applies to lines SHAPED like diagnostics. A
    /// downloaded-file path line embeds the tweet's own text in the filename
    /// — which can contain any keyword — and must never classify a flawless
    /// run as an auth/disk failure.
    func testPathLinesNeverPassHoweverIncriminatingTheFilename() {
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic(
                "/tmp/likes/@gin/gin - login auth_token no space left [123] #1.jpg"))
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic(
                "# /tmp/likes/@gin/gin - cookie unauthorized 429 [124] #1.jpg"),
            "dedupe-skip form of the path line")
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic(
                "~/likes/@gin/gin - connection timeout [125] #1.jpg"))
    }

    /// likes-sync event lines are data, not diagnostics — even when they do
    /// not parse (unknown selector, malformed JSON), their payload text must
    /// not leak into failure classification.
    func testLikesSyncEventLinesNeverPassTheDiagnosticFilter() {
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic(
                "likes-sync\tpost:{\"content\":\"login required auth_token\"}"))
        XCTAssertFalse(
            LikesSyncEventParser.isUsefulDiagnostic("likes-sync\t{\"content\":\"unauthorized\"}"))
    }

    /// Unbracketed free text with scary keywords is not a diagnostic either —
    /// only logger-shaped lines ("[module][level] …") reach keyword logic.
    func testUnbracketedKeywordLinesAreNotDiagnostics() {
        XCTAssertFalse(LikesSyncEventParser.isUsefulDiagnostic("login to continue reading"))
        XCTAssertFalse(LikesSyncEventParser.isUsefulDiagnostic("429 likes fetched so far"))
    }

    /// Real warning/error-level rate-limit and auth lines must stay captured —
    /// they are the message source when the run genuinely fails.
    func testWarningAndErrorLevelDiagnosticsAreRetained() {
        XCTAssertTrue(
            LikesSyncEventParser.isUsefulDiagnostic("[twitter][error] 429 Too Many Requests"))
        XCTAssertTrue(
            LikesSyncEventParser.isUsefulDiagnostic("[twitter][warning] rate limit exceeded"))
        XCTAssertTrue(
            LikesSyncEventParser.isUsefulDiagnostic("[twitter][error] Login required"))
        XCTAssertTrue(
            LikesSyncEventParser.isUsefulDiagnostic("[downloader.http][warning] cookies not found"))
    }
}
