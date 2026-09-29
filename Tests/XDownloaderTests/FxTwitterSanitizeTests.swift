import XCTest

@testable import XDownloader

/// `FxTwitterService.sanitize` keeps fxtwitter filenames in step with what
/// gallery-dl produces: path separators become "_", newlines collapse to spaces,
/// surrounding whitespace is trimmed.
@MainActor
final class FxTwitterSanitizeTests: XCTestCase {

    func testSlashBecomesUnderscore() {
        XCTAssertEqual(FxTwitterService.sanitize("a/b"), "a_b")
    }

    func testNewlineBecomesSpace() {
        XCTAssertEqual(FxTwitterService.sanitize("l1\nl2"), "l1 l2")
    }

    func testCarriageReturnBecomesSpace() {
        XCTAssertEqual(FxTwitterService.sanitize("a\rb"), "a b")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(FxTwitterService.sanitize("  trim  "), "trim")
    }

    /// gallery-dl drops every other control character from the names it
    /// makes, so a tab in the tweet text never reaches a folder name that
    /// gallery-dl would write elsewhere.
    func testOtherControlCharactersAreDropped() {
        XCTAssertEqual(FxTwitterService.sanitize("a\tb\u{7F}c\u{01}d"), "abcd")
        XCTAssertEqual(FxTwitterService.sanitize("\tlead [1]"), "lead [1]")
        XCTAssertTrue(RowFolder.isReusable(URL(fileURLWithPath: "/downloads/" + FxTwitterService.sanitize("nick - a\tb [1]"))))
    }

    func testCombinedReplacements() {
        XCTAssertEqual(FxTwitterService.sanitize("x/y\nz"), "x_y z")
    }
}
