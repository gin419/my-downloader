import XCTest

@testable import XDownloader

final class URLExtractionTests: XCTestCase {
    func testExtractsMultipleURLsInOrderAndSkipsNoise() {
        let text = """
            https://x.com/a/status/1 check this out
            https://youtu.be/b
            not-a-url ftp://example.com/file
            http://example.com/c?d=e
            """
        XCTAssertEqual(
            DownloadManager.extractURLs(from: text),
            ["https://x.com/a/status/1", "https://youtu.be/b", "http://example.com/c?d=e"]
        )
    }

    func testNonURLTextYieldsNothing() {
        XCTAssertEqual(DownloadManager.extractURLs(from: "hello world"), [])
        XCTAssertEqual(DownloadManager.extractURLs(from: ""), [])
    }

    func testSchemeWithoutHostIsRejected() {
        XCTAssertEqual(
            DownloadManager.extractURLs(from: "https:// http:// https://x.com"),
            ["https://x.com"]
        )
    }

    func testTabAndSpaceSeparatorsWork() {
        XCTAssertEqual(
            DownloadManager.extractURLs(from: "https://a.com/1\thttps://b.com/2 https://c.com/3"),
            ["https://a.com/1", "https://b.com/2", "https://c.com/3"]
        )
    }

    func testTrailingPunctuationIsStripped() {
        XCTAssertEqual(
            DownloadManager.extractURLs(from: "see https://x.com/a/status/1, then https://x.com/b/status/2。"),
            ["https://x.com/a/status/1", "https://x.com/b/status/2"]
        )
    }

    func testWrappingBracketsAndQuotesAreStripped() {
        XCTAssertEqual(
            DownloadManager.extractURLs(from: "(https://x.com/a) 「https://x.com/b」 \"https://x.com/c\""),
            ["https://x.com/a", "https://x.com/b", "https://x.com/c"]
        )
    }

    func testBalancedParenInURLIsKept() {
        XCTAssertEqual(
            DownloadManager.extractURLs(from: "https://en.wikipedia.org/wiki/Alien_(film)"),
            ["https://en.wikipedia.org/wiki/Alien_(film)"]
        )
    }

    func testSingleBareTokenGetsHTTPSAssumed() {
        XCTAssertEqual(
            DownloadManager.extractURLs(from: "x.com/a/status/1"),
            ["https://x.com/a/status/1"]
        )
        // …but only when it's the entire input — prose never sprouts URLs.
        XCTAssertEqual(DownloadManager.extractURLs(from: "see x.com/a/status/1 today"), [])
    }

    func testEmailAndPlainWordsAreNotBareURLs() {
        XCTAssertEqual(DownloadManager.extractURLs(from: "user@example.com"), [])
        XCTAssertEqual(DownloadManager.extractURLs(from: "hello"), [])
        XCTAssertEqual(DownloadManager.extractURLs(from: "1.2"), [])
        // Filename-shaped tokens must not become downloads — a bare host
        // only counts with a path.
        XCTAssertEqual(DownloadManager.extractURLs(from: "node.js"), [])
        XCTAssertEqual(DownloadManager.extractURLs(from: "notes.txt"), [])
    }
}
