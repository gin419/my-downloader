import XCTest

@testable import XDownloader

final class LikesSyncHandleTests: XCTestCase {
    func testNormalizesPlainAtAndProfileURLInputs() throws {
        XCTAssertEqual(try LikesSyncHandle("Alice_123").value, "alice_123")
        XCTAssertEqual(try LikesSyncHandle("@Alice_123").value, "alice_123")
        XCTAssertEqual(try LikesSyncHandle("https://x.com/Alice_123/likes").value, "alice_123")
        XCTAssertEqual(try LikesSyncHandle("https://twitter.com/Alice_123").displayName, "@alice_123")
    }

    func testRejectsInvalidHandles() {
        XCTAssertThrowsError(try LikesSyncHandle(""))
        XCTAssertThrowsError(try LikesSyncHandle("not-a-handle"))
        XCTAssertThrowsError(try LikesSyncHandle("thishandleiswaytoolong"))
        XCTAssertThrowsError(try LikesSyncHandle("https://example.com/Alice"))
        XCTAssertThrowsError(try LikesSyncHandle("https://x.com/home"))
        XCTAssertThrowsError(try LikesSyncHandle("https://twitter.com/gin/status/123"))
        XCTAssertThrowsError(try LikesSyncHandle("https://x.com/login"))
    }
}
