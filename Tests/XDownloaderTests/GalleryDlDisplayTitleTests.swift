import XCTest

@testable import XDownloader

/// `GalleryDlService.displayTitle` turns a gallery-dl filename back into a
/// display title by stripping the " #N" file index, the uniqueness suffix
/// (numeric tweet id or 11-char Instagram shortcode), and the legacy "_N" index.
@MainActor
final class GalleryDlDisplayTitleTests: XCTestCase {

    func testStripsTweetIdAndFileIndex() {
        XCTAssertEqual(
            GalleryDlService.displayTitle(forPath: "/out/Nick - text [2063695500809826393] #1.jpg"),
            "Nick - text")
    }

    func testStripsInstagramShortcodeAndFileIndex() {
        XCTAssertEqual(
            GalleryDlService.displayTitle(forPath: "/out/user - caption [Daoe_4TTVY0] #3.jpg"),
            "user - caption")
    }

    func testKeepsBracketSuffixThatIsNotAShortcode() {
        // Bracketed text of the wrong length is part of the real title.
        XCTAssertEqual(
            GalleryDlService.displayTitle(forPath: "/out/band - song [Official].mp4"),
            "band - song [Official]")
    }
}
