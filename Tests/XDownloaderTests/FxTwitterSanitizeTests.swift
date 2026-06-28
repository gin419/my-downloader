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

    func testCombinedReplacements() {
        XCTAssertEqual(FxTwitterService.sanitize("x/y\nz"), "x_y z")
    }
}
