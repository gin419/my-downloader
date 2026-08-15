import XCTest

@testable import XDownloader

/// The ffmpeg merge guard: with ffmpeg missing, yt-dlp on a merge-requiring
/// format selector warns, downloads the streams separately (video-only +
/// audio-only files), and still exits 0 — so the success branch would mark
/// the row "Done" while the user's "video" plays silent. parseLine must
/// record the warning on the item so DownloadManager can fail truthfully.
@MainActor
final class FfmpegMergeGuardTests: XCTestCase {

    /// Verbatim yt-dlp output (2026.07.04, YoutubeDL.py) when the selector
    /// needs a merge and ffmpeg is absent.
    private static let mergeWarning =
        "WARNING: You have requested merging of multiple formats but ffmpeg is not installed. The formats won't be merged"

    private func parse(_ line: String, into item: DownloadItem) {
        YtDlpService.parseLine(line, item: item) {
            XCTFail("terminate() must not fire for merge-guard lines")
        }
    }

    // MARK: - Flag detection (parseLine)

    func testMergeWarningSetsFlagAndIsCapturedAsLastWarning() {
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse(Self.mergeWarning, into: item)

        XCTAssertTrue(item.ffmpegMissingForMerge)
        // The generic WARNING capture must still see it: exit-code failures
        // cite lastToolWarning, and this warning is the best clue there too.
        XCTAssertEqual(
            item.lastToolWarning,
            "You have requested merging of multiple formats but ffmpeg is not installed. The formats won't be merged")
        XCTAssertEqual(item.status, .queued, "the warning alone must not change status")
    }

    func testMergeWarningIsSiteUngated() {
        // Twitter HLS video+audio needs the same merge — the detection must
        // not be gated to YouTube like the stale-extractor tells above it.
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse(Self.mergeWarning, into: item)

        XCTAssertTrue(item.ffmpegMissingForMerge)
    }

    // MARK: - Flag lifecycle and false-positive gates

    func testResetForReattemptClearsFlag() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        item.ffmpegMissingForMerge = true
        item.resetForReattempt()

        XCTAssertFalse(item.ffmpegMissingForMerge)
    }

    func testDestinationFilenameContainingWarningTextDoesNotSetFlag() {
        // The WARNING prefix gate is load-bearing: a filename echoing the
        // warning text must never trip the detection.
        let path = "/tmp/out/user - requested merging of multiple formats but ffmpeg is gone.mp4"
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse("[download] Destination: \(path)", into: item)

        XCTAssertFalse(item.ffmpegMissingForMerge)
        XCTAssertEqual(item.outputPath, path)
    }
}
