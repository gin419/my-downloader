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

    func testAccumulatorCountsUniqueTweetsMediaAndCategorizedFailures() {
        let lines = [
            "prepare:likes-sync\t{\"tweet_id\":\"123\",\"media_id\":\"m1\"}",
            "post:likes-sync\t{\"tweet_id\":\"123\",\"media_id\":\"m1\"}",
            "post-after:likes-sync\t{\"tweet_id\":\"123\",\"media_id\":\"m2\"}",
            "skip:likes-sync\t{\"tweet_id\":\"124\",\"media_id\":\"m3\",\"message\":\"No results for tweet\"}",
            "error:likes-sync\t{\"message\":\"429 Too Many Requests\"}",
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
            "after:likes-sync\t{\"tweet_id\":\"1\",\"num\":1}",
            "skip:likes-sync\t{\"tweet_id\":\"1\",\"num\":2}",
            "post-after:likes-sync\t{\"tweet_id\":\"1\"}",
            "post:likes-sync\t{\"tweet_id\":\"2\"}",
            "post-after:likes-sync\t{\"tweet_id\":\"2\"}",
        ]
        var summary = LikesSyncRunAccumulator()
        for line in lines { summary.apply(try! XCTUnwrap(LikesSyncEventParser.parse(line))) }
        XCTAssertEqual(summary.downloadedCount, 1)
        XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertEqual(summary.noMediaCount, 1)
        XCTAssertEqual(summary.failureCount, 0)
    }

    func testMalformedEventPayloadBecomesParseFailure() {
        let event = LikesSyncEventParser.parse("error:likes-sync\t{nope")
        XCTAssertEqual(event?.name, .error)
        XCTAssertEqual(event?.failureCategory, .parse)
        XCTAssertEqual(event?.message, "Could not parse gallery-dl event JSON")
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
