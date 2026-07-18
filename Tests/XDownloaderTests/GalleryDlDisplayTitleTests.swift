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

    func testKeepsShortcodeLengthBracketInTweetText() {
        // Twitter filenames end in "[tweet_id] #N"; once those are stripped the
        // stem ends with the tweet's own text. An 11-char bracketed token there
        // ("OFFICIAL_MV" is exactly 11 chars of the shortcode class) is real
        // content, not a second uniqueness suffix — only one may be stripped.
        XCTAssertEqual(
            GalleryDlService.displayTitle(
                forPath: "/out/Nick - new video [OFFICIAL_MV] [1955555555555555555] #1.mp4"),
            "Nick - new video [OFFICIAL_MV]")
    }

    func testStripsAtMostOneUniquenessSuffix() {
        // Same guarantee for Instagram: a caption ending in an 11-char token
        // keeps it once the real shortcode is stripped.
        XCTAssertEqual(
            GalleryDlService.displayTitle(
                forPath: "/out/user - watch [OFFICIAL_MV] [Daoe_4TTVY0] #2.jpg"),
            "user - watch [OFFICIAL_MV]")
    }
}
