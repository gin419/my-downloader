import XCTest

@testable import XDownloader

/// `YtDlpService.cleanTitleStem` strips the suffixes yt-dlp leaves on saved
/// filenames so the displayed title matches the final file.
@MainActor
final class TitleStemTests: XCTestCase {

    func testNoSuffixIsUnchanged() {
        XCTAssertEqual(YtDlpService.cleanTitleStem("Uploader - Title", isImage: false), "Uploader - Title")
    }

    func testImageIndexStrippedOnlyForImages() {
        XCTAssertEqual(YtDlpService.cleanTitleStem("Uploader - Title_2", isImage: true), "Uploader - Title")
        // not an image → the "_2" is part of the real name, kept
        XCTAssertEqual(YtDlpService.cleanTitleStem("Uploader - Title_2", isImage: false), "Uploader - Title_2")
    }

    func testPlaylistIndexStripped() {
        XCTAssertEqual(YtDlpService.cleanTitleStem("Uploader - Title [01]", isImage: false), "Uploader - Title")
    }

    func testIntermediateFormatCodeStripped() {
        XCTAssertEqual(YtDlpService.cleanTitleStem("Uploader - Title.f136", isImage: false), "Uploader - Title")
        XCTAssertEqual(YtDlpService.cleanTitleStem("Name.f251", isImage: false), "Name")
    }

    func testStripsAreAnchoredToTheEnd() {
        // Each suffix is stripped once, only when it's at the end: removing ".f140"
        // leaves " [02]" no longer terminal, so it stays.
        XCTAssertEqual(
            YtDlpService.cleanTitleStem("Uploader - Title [02].f140", isImage: false),
            "Uploader - Title [02]")
    }
}
