import XCTest

@testable import XDownloader

/// `MediaExtensions` is the single source of truth for media file extensions.
/// These tests pin the two divergences that this refactor fixed (and that had
/// been latent bugs): yt-dlp's image check missing `gif`/`avif`, and gallery-dl's
/// `knownMedia` missing `mkv`/`m4v`.
@MainActor
final class MediaExtensionsTests: XCTestCase {

    func testImageSetIncludesGifAndAvif() {
        XCTAssertTrue(MediaExtensions.image.contains("gif"))
        XCTAssertTrue(MediaExtensions.image.contains("avif"))
    }

    func testVideoSetIncludesMkvAndM4v() {
        XCTAssertTrue(MediaExtensions.video.contains("mkv"))
        XCTAssertTrue(MediaExtensions.video.contains("m4v"))
    }

    func testAllIsTheUnionAndCoversEveryVideoExt() {
        XCTAssertTrue(MediaExtensions.all.isSuperset(of: MediaExtensions.video))
        XCTAssertEqual(
            MediaExtensions.all,
            MediaExtensions.image.union(MediaExtensions.video).union(MediaExtensions.audio))
    }

    func testCategoriesAreDisjoint() {
        XCTAssertTrue(MediaExtensions.image.isDisjoint(with: MediaExtensions.video))
        XCTAssertTrue(MediaExtensions.video.isDisjoint(with: MediaExtensions.audio))
    }

    // MARK: - DownloadItem.recomputeMediaCategory

    func testRecomputeImageOnly() {
        let i = DownloadItem(url: "x")
        i.imageCount = 2
        i.recomputeMediaCategory()
        XCTAssertEqual(i.mediaCategory, .image)
    }

    func testRecomputeVideoOnly() {
        let i = DownloadItem(url: "x")
        i.videoCount = 1
        i.recomputeMediaCategory()
        XCTAssertEqual(i.mediaCategory, .video)
    }

    func testRecomputeMixed() {
        let i = DownloadItem(url: "x")
        i.imageCount = 1
        i.videoCount = 1
        i.recomputeMediaCategory()
        XCTAssertEqual(i.mediaCategory, .mixed)
    }

    func testRecomputeNeitherLeavesUnknown() {
        let i = DownloadItem(url: "x")
        i.recomputeMediaCategory()
        XCTAssertEqual(i.mediaCategory, .unknown)
    }
}
