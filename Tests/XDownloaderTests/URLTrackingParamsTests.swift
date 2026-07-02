import XCTest

@testable import XDownloader

/// `DownloadManager.stripTrackingParams` removes `utm_*` and a fixed set of
/// share/referral params before a URL is downloaded, while preserving the rest.
@MainActor
final class URLTrackingParamsTests: XCTestCase {

    func testStripsTrackingButKeepsRealParams() {
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://x.com/a/b?utm_source=ig&si=abc&v=1"),
            "https://x.com/a/b?v=1")
    }

    func testDropsQueryEntirelyWhenAllStripped() {
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://x.com/a?utm_medium=x&fbclid=y"),
            "https://x.com/a")
    }

    func testStripsShareParam() {
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://youtu.be/abc?si=track"),
            "https://youtu.be/abc")
    }

    func testStripsXShareLinkParams() {
        // x.com share links carry ?s=46&t=… — both must go or the same post
        // never dedups against its bare URL.
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://x.com/a/status/1?s=46&t=AbC_dEf"),
            "https://x.com/a/status/1")
    }

    func testLeavesNonTrackingParamsUntouched() {
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://example.com/p?keep=1"),
            "https://example.com/p?keep=1")
    }

    func testParamMatchIsCaseInsensitive() {
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://x.com/a?UTM_Source=x&id=9"),
            "https://x.com/a?id=9")
    }
}
