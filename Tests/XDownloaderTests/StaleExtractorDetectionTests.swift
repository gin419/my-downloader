import XCTest

@testable import XDownloader

/// `YtDlpService.parseLine` stale-extractor detection: when yt-dlp's
/// "Requested format is not available" error fires on a YouTube URL after
/// WARNING lines that identify a broken tool (stale yt-dlp build, missing
/// JavaScript runtime), the failure message must name the real cause and its
/// fix instead of claiming a transient hiccup and suggesting Retry.
@MainActor
final class StaleExtractorDetectionTests: XCTestCase {

    private let staleToolMessage = YtDlpService.staleToolMessage
    private let missingJSRuntimeMessage = YtDlpService.missingJSRuntimeMessage
    private let transientFormatMessage = YtDlpService.transientFormatMessage

    private let formatErrorLine = "ERROR: [youtube] pzBazEzxqaI: Requested format is not available."
    private let denoTell =
        "WARNING: [youtube] No supported JavaScript runtime could be found. Only deno is enabled by default; "
        + "to use another runtime add  --js-runtimes RUNTIME[:PATH]  to your command/config."
    private let signatureTell =
        "WARNING: [youtube] pzBazEzxqaI: Signature extraction failed: Some formats may be missing"

    private func parse(_ line: String, into item: DownloadItem) {
        YtDlpService.parseLine(line, item: item) {
            XCTFail("terminate() must not fire for stale-extractor lines")
        }
    }

    private func failureMessage(_ item: DownloadItem) -> String? {
        guard case .failed(let message) = item.status else { return nil }
        return message
    }

    // MARK: - Stale-tool tells

    func testLiveReproTranscriptReportsStaleTool() {
        // Verbatim transcript from the live repro (yt-dlp 2024.11.04 against
        // 2026 YouTube), interleaved with a progress line as in real output.
        let item = DownloadItem(url: "https://youtube.com/shorts/pzBazEzxqaI")
        parse("WARNING: [youtube] YouTube said: ERROR - Precondition check failed.", into: item)
        parse(signatureTell, into: item)
        parse("[download]  45.3% of  15.42MiB at  2.34MiB/s ETA 00:05", into: item)
        parse("WARNING: Only images are available for download. use --list-formats to see them", into: item)
        parse(formatErrorLine, into: item)

        XCTAssertEqual(failureMessage(item), staleToolMessage)
    }

    func testEachStaleTellAloneReportsStaleTool() {
        // Each tell on its own must be sufficient; the third varies letter
        // case to pin case-insensitive matching.
        let tells = [
            "WARNING: [youtube] pzBazEzxqaI: Signature extraction failed: Some formats may be missing",
            "WARNING: [youtube] pzBazEzxqaI: nsig extraction failed: Install PhantomJS to workaround the issue",
            "WARNING: Only Images Are Available for download. use --list-formats to see them",
        ]
        for tell in tells {
            let item = DownloadItem(url: "https://youtube.com/shorts/pzBazEzxqaI")
            parse(tell, into: item)
            parse(formatErrorLine, into: item)

            XCTAssertEqual(failureMessage(item), staleToolMessage, "tell: \(tell)")
        }
    }

    // MARK: - Missing JS runtime tell

    func testMissingJSRuntimeTellReportsMissingRuntime() {
        let item = DownloadItem(url: "https://youtube.com/shorts/pzBazEzxqaI")
        parse(denoTell, into: item)
        parse(formatErrorLine, into: item)

        XCTAssertEqual(failureMessage(item), missingJSRuntimeMessage)
    }

    func testMissingJSRuntimeWinsOverStaleTells() {
        // A missing runtime also breaks signature extraction, so both tells
        // fire together — the actionable root cause (install deno) must win,
        // regardless of which tell appears first.
        let denoFirst = DownloadItem(url: "https://youtube.com/shorts/pzBazEzxqaI")
        parse(denoTell, into: denoFirst)
        parse(signatureTell, into: denoFirst)
        parse(formatErrorLine, into: denoFirst)
        XCTAssertEqual(failureMessage(denoFirst), missingJSRuntimeMessage)

        let staleFirst = DownloadItem(url: "https://youtube.com/shorts/pzBazEzxqaI")
        parse(signatureTell, into: staleFirst)
        parse(denoTell, into: staleFirst)
        parse(formatErrorLine, into: staleFirst)
        XCTAssertEqual(failureMessage(staleFirst), missingJSRuntimeMessage)
    }

    // MARK: - No tell / wrong site: keep the transient explanation

    func testFormatErrorWithoutTellKeepsTransientMessage() {
        let item = DownloadItem(url: "https://youtube.com/shorts/pzBazEzxqaI")
        parse(formatErrorLine, into: item)

        XCTAssertEqual(failureMessage(item), transientFormatMessage)
    }

    func testNonYouTubeProfileIgnoresSpoofedTell() {
        // The tells are YouTube-extractor specific; on other sites the
        // format error keeps its transient explanation.
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse(signatureTell, into: item)
        parse(formatErrorLine, into: item)

        XCTAssertEqual(failureMessage(item), transientFormatMessage)
    }

    // MARK: - Detection must not disturb normal parsing

    func testDestinationLineWithTellTextDoesNotTriggerDetection() {
        // A video title can contain tell text; only WARNING-prefixed lines
        // may record breakage.
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] Destination: /tmp/out/nihil - Signature extraction failed.mp4", into: item)

        XCTAssertEqual(item.extractorBreakage, .none)
        XCTAssertEqual(item.outputPath, "/tmp/out/nihil - Signature extraction failed.mp4")
        XCTAssertEqual(item.title, "nihil - Signature extraction failed")
    }

    func testParsingContinuesNormallyAfterTellRecorded() {
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse(signatureTell, into: item)
        parse("[download] Destination: /tmp/out/nihil - some title.mp4", into: item)
        parse("[download]  45.3% of  15.42MiB at  2.34MiB/s ETA 00:05", into: item)

        XCTAssertEqual(item.extractorBreakage, .staleTool)
        XCTAssertEqual(item.videoPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.status, .downloading)
        XCTAssertEqual(item.progress, 0.453, accuracy: 0.0001)
    }

    // MARK: - Tells must only rewrite the format error, nothing else

    func testUnrelatedErrorAfterTellKeepsRawErrorLine() {
        // A recorded tell must not hijack unrelated failures — only the
        // "Requested format is not available" error gets the diagnosis.
        // (The 403 line used here before Phase 2 now has its own mapping.)
        let item = DownloadItem(url: "https://youtube.com/shorts/pzBazEzxqaI")
        parse(signatureTell, into: item)
        let unrelated = "ERROR: [youtube] pzBazEzxqaI: Video unavailable"
        parse(unrelated, into: item)

        XCTAssertEqual(failureMessage(item), unrelated)
    }

    func testFirstErrorWinsOverLaterFormatError() {
        // Existing first-failure-wins semantics: an earlier unrelated ERROR
        // keeps its raw line even when the format error follows a tell.
        let item = DownloadItem(url: "https://youtube.com/shorts/pzBazEzxqaI")
        parse(signatureTell, into: item)
        let unrelated = "ERROR: [youtube] pzBazEzxqaI: Video unavailable"
        parse(unrelated, into: item)
        parse(formatErrorLine, into: item)

        XCTAssertEqual(failureMessage(item), unrelated)
    }

    // MARK: - Messages must not trip the empty-success auto-retry

    func testMessagesDoNotTriggerEmptySuccessAutoRetry() {
        // DownloadManager's empty-success auto-retry re-runs an item whose
        // failure message matches its predicate (a substring check before
        // Phase 2). A broken tool would silently re-run and fail identically,
        // so the diagnostic messages must never match.
        let messages = [
            YtDlpService.staleToolMessage,
            YtDlpService.missingJSRuntimeMessage,
            YtDlpService.transientFormatMessage,
        ]
        for message in messages {
            XCTAssertFalse(DownloadManager.isEmptySuccessMessage(message), "\"\(message)\" must not auto-retry")
        }
    }
}
