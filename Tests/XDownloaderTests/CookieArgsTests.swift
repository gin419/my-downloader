import XCTest

@testable import XDownloader

/// `CookieArgs.make` is the single source of cookie flags for both yt-dlp and
/// gallery-dl. The key contract: an explicit cookies.txt file always wins over
/// the cookie-browser setting (the workaround for X sensitive/NSFW media).
@MainActor
final class CookieArgsTests: XCTestCase {

    func testFilePathOverridesBrowser() {
        XCTAssertEqual(CookieArgs.make(browser: .safari, file: "/c.txt"), ["--cookies", "/c.txt"])
    }

    func testNilFileUsesBrowser() {
        XCTAssertEqual(CookieArgs.make(browser: .safari, file: nil), ["--cookies-from-browser", "safari"])
        XCTAssertEqual(CookieArgs.make(browser: .chrome, file: nil), ["--cookies-from-browser", "chrome"])
    }

    func testBrowserProfileIsIncludedInCookieSource() {
        XCTAssertEqual(
            CookieArgs.make(browser: .chrome, profile: "Profile 8", file: nil),
            ["--cookies-from-browser", "chrome:Profile 8"])
    }

    func testCookieFileStillOverridesBrowserProfile() {
        XCTAssertEqual(
            CookieArgs.make(browser: .chrome, profile: "Profile 8", file: "/c.txt"),
            ["--cookies", "/c.txt"])
    }

    func testEmptyFilePathFallsBackToBrowser() {
        XCTAssertEqual(CookieArgs.make(browser: .safari, file: ""), ["--cookies-from-browser", "safari"])
    }

    func testFileWithBrowserNone() {
        XCTAssertEqual(CookieArgs.make(browser: .none, file: "/c.txt"), ["--cookies", "/c.txt"])
    }

    func testNothingConfiguredYieldsNoFlags() {
        XCTAssertEqual(CookieArgs.make(browser: .none, file: nil), [])
    }
}
