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
}
