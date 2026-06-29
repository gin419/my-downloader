import XCTest

@testable import XDownloader

/// `CookieAccessManager` owns the cookies.txt bookmark + per-download scope.
/// The real security-scoped grant needs the sandboxed app, so these cover the
/// CI-testable surface: the no-bookmark / invalid-bookmark resolution, bookmark
/// persistence roundtrip, and the scope forwarding.
@MainActor
final class CookieAccessManagerTests: XCTestCase {

    func testNoBookmarkResolvesToNone() {
        let m = CookieAccessManager()
        guard case .none = m.resolveForDownload() else { return XCTFail("expected .none") }
        XCTAssertNil(m.bookmarkForSaving)
    }

    func testLoadBookmarkRoundtrips() {
        let m = CookieAccessManager()
        let data = Data([1, 2, 3])
        m.loadBookmark(data)
        XCTAssertEqual(m.bookmarkForSaving, data)
    }

    /// A saved bookmark that no longer resolves (file moved/deleted) must report
    /// .bookmarkFailed so DownloadManager falls back to the cookie browser rather
    /// than handing yt-dlp an ungranted --cookies path.
    func testInvalidBookmarkResolvesToBookmarkFailed() {
        let m = CookieAccessManager()
        m.loadBookmark(Data([1, 2, 3]))  // not a real security-scoped bookmark
        guard case .bookmarkFailed = m.resolveForDownload() else { return XCTFail("expected .bookmarkFailed") }
    }

    func testClearRemovesBookmark() {
        let m = CookieAccessManager()
        m.loadBookmark(Data([1, 2, 3]))
        m.clear()
        XCTAssertNil(m.bookmarkForSaving)
    }

    func testWithScopeForwardsAndReturnsBodyValue() async {
        let m = CookieAccessManager()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ca-\(UUID().uuidString).txt")
        try? "x".write(to: tmp, atomically: true, encoding: .utf8)
        let value = await m.withScope(for: UUID(), file: tmp.path, grantedURL: nil) { 7 }
        XCTAssertEqual(value, 7)
    }
}
