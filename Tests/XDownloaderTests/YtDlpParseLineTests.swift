import XCTest

@testable import XDownloader

/// `YtDlpService.parseLine` media-path capture. The "has already been
/// downloaded" skip notice is the only output yt-dlp prints when the file
/// already exists on disk (exit 0, no Destination:/[Merger] lines), so it
/// must record the path or DownloadManager reads the run as an empty success.
@MainActor
final class YtDlpParseLineTests: XCTestCase {

    private func parse(_ line: String, into item: DownloadItem) {
        YtDlpService.parseLine(line, item: item) {
            XCTFail("terminate() must not fire for media-path lines")
        }
    }

    // MARK: - "has already been downloaded" skip notice

    func testAlreadyDownloadedVideoIsRecordedAsOutput() {
        let item = DownloadItem(url: "https://youtube.com/shorts/abc")
        parse("[download] /tmp/out/nihil - some title.mp4 has already been downloaded", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.title, "nihil - some title")
        XCTAssertEqual(item.mediaCategory, .video)
    }

    func testAlreadyDownloadedAndMergedSuffixIsIgnored() {
        // Older yt-dlp versions append " and merged" to the same notice.
        let item = DownloadItem(url: "https://youtube.com/shorts/abc")
        parse("[download] /tmp/out/nihil - some title.mp4 has already been downloaded and merged", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.title, "nihil - some title")
    }

    func testAlreadyDownloadedImageCountsAsImage() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse("[download] /tmp/out/user - pic.jpg has already been downloaded", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/user - pic.jpg")
        XCTAssertEqual(item.imageCount, 1)
        XCTAssertNil(item.videoCount)
        XCTAssertEqual(item.mediaCategory, .image)
    }

    func testAlreadyDownloadedPreMergeStreamStripsFormatCodeFromTitle() {
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] /tmp/out/nihil - clip.f299.mp4 has already been downloaded", into: item)

        XCTAssertEqual(item.videoPath, "/tmp/out/nihil - clip.f299.mp4")
        XCTAssertEqual(item.title, "nihil - clip")
    }

    // MARK: - Destination line (regression: must behave exactly as before)

    func testDestinationLineRecordsVideo() {
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] Destination: /tmp/out/nihil - some title.mp4", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.title, "nihil - some title")
        XCTAssertEqual(item.mediaCategory, .video)
    }

    func testDestinationLineImageDoesNotOverwriteVideoOutputPath() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse("[download] Destination: /tmp/out/user - clip.mp4", into: item)
        parse("[download] Destination: /tmp/out/user - pic_2.jpg", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/user - clip.mp4")
        XCTAssertEqual(item.imageCount, 1)
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.mediaCategory, .mixed)
    }
}
