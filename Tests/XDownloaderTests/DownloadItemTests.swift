import XCTest

@testable import XDownloader

@MainActor
final class DownloadItemTests: XCTestCase {

    func testResetForReattemptClearsMediaState() {
        let item = DownloadItem(url: "https://x.com/a")
        item.imageCount = 3
        item.videoCount = 2
        item.title = "Uploader - Title"
        item.outputPath = "/tmp/x.mp4"
        item.totalSize = "5.0MiB"
        item.speed = "1MiB/s"
        item.mediaCategory = .mixed
        item.progress = 0.5

        item.resetForReattempt()

        XCTAssertNil(item.imageCount)
        XCTAssertNil(item.videoCount)
        XCTAssertNil(item.title)
        XCTAssertNil(item.outputPath)
        XCTAssertNil(item.totalSize)
        XCTAssertNil(item.speed)
        XCTAssertEqual(item.mediaCategory, .unknown)
        XCTAssertEqual(item.progress, 0)
    }

    func testTotalBytesParsesUnits() {
        let item = DownloadItem(url: "x")
        item.totalSize = "5 MB"
        XCTAssertEqual(item.totalBytes, 5_000_000)
        item.totalSize = "1.5MiB"
        XCTAssertEqual(item.totalBytes, Int64(1.5 * 1_048_576))
    }

    func testTotalBytesRejectsGarbageWithoutCrashing() {
        let item = DownloadItem(url: "x")
        item.totalSize = "not a size"
        XCTAssertNil(item.totalBytes)
        item.totalSize = nil
        XCTAssertNil(item.totalBytes)
    }
}
