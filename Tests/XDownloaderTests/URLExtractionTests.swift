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
}
