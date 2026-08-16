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

    // MARK: - Success-branch guard (unmergedStreamsFailure)

    func testFlagPlusIntermediateOutputPathFailsTruthfully() {
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        item.ffmpegMissingForMerge = true
        item.outputPath = "/tmp/out/user - clip.f137.mp4"

        XCTAssertEqual(DownloadManager.unmergedStreamsFailure(for: item), DownloadManager.unmergedStreamsMessage)
    }

    func testFlagWithMergedFinalPathIsNotAFailure() {
        // A real [Merger] line lands a final path without `.f{format_id}` —
        // the merge DID happen, whatever warned earlier.
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        item.ffmpegMissingForMerge = true
        item.outputPath = "/tmp/out/user - clip.mp4"

        XCTAssertNil(DownloadManager.unmergedStreamsFailure(for: item))
    }

    func testIntermediateOutputPathWithoutFlagIsNotAFailure() {
        // Single-format downloads can keep `.f…` in the on-disk name with no
        // merge ever requested — only the warning makes it a broken delivery.
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        item.outputPath = "/tmp/out/user - clip.f137.mp4"

        XCTAssertNil(DownloadManager.unmergedStreamsFailure(for: item))
    }

    func testFlagWithImageOutputPathIsNotAFailure() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        item.ffmpegMissingForMerge = true
        item.outputPath = "/tmp/out/user - pic_2.jpg"
        item.imageCount = 1
        item.mediaCategory = .image

        XCTAssertNil(DownloadManager.unmergedStreamsFailure(for: item))
    }

    func testFlagWithAudioOnlyRunIsNotAFailure() {
        // Audio-only runs extract to a final `.m4a`/`.mp3` — no merge, no
        // intermediate left as the deliverable.
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        item.ffmpegMissingForMerge = true
        item.audioPath = "/tmp/out/user - song.m4a"
        item.outputPath = "/tmp/out/user - song.m4a"
        item.mediaCategory = .audio

        XCTAssertNil(DownloadManager.unmergedStreamsFailure(for: item))
    }

    func testUnmergedMessageDoesNotTriggerEmptySuccessAutoRetry() {
        // Streams DID land on disk, so the one-shot empty-success auto-retry
        // must not burn itself re-running into the same missing tool. The
        // gate is structural since Phase 4d, and the unmerged-streams branch
        // never arms `item.emptySuccessFailure`.
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        item.status = .failed(DownloadManager.unmergedStreamsMessage)
        XCTAssertFalse(DownloadManager.shouldAutoRetryEmptySuccess(item))
    }

    // MARK: - End-to-end at parse level

    func testFullParseSequenceOfUnmergedRunProducesFailureMessage() {
        // The live-verified shape: merge WARNING, then the two streams land
        // separately and yt-dlp exits 0 with outputPath on the LAST
        // Destination — the audio intermediate.
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse(Self.mergeWarning, into: item)
        parse("[download] Destination: /tmp/out/user - clip.f137.mp4", into: item)
        parse("[download] Destination: /tmp/out/user - clip.f140.m4a", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/user - clip.f140.m4a")
        XCTAssertEqual(DownloadManager.unmergedStreamsFailure(for: item), DownloadManager.unmergedStreamsMessage)

        // Same run WITH ffmpeg present: the [Merger] line flips outputPath to
        // the final deliverable and the guard stands down.
        parse(#"[Merger] Merging formats into "/tmp/out/user - clip.mp4""#, into: item)
        XCTAssertNil(DownloadManager.unmergedStreamsFailure(for: item))
    }
}
