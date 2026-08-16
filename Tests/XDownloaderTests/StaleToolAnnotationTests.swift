import XCTest

@testable import XDownloader

/// The Honest Toolbox downstream feed: when the probe knows yt-dlp is
/// outdated and the failure IS the stale-tool diagnosis, the finalized
/// message names the installed version — and nothing else changes.
@MainActor
final class StaleToolAnnotationTests: XCTestCase {

    private let outdatedStatus = ToolStatus.outdated(installed: "2024.11.04", detail: "21 months old")

    func testStaleMessageGainsInstalledVersion() {
        XCTAssertEqual(
            DownloadManager.annotatedWithInstalledVersion(
                YtDlpService.staleToolMessage, ytDlpStatus: outdatedStatus),
            YtDlpService.staleToolMessage + " (installed: 2024.11.04)")
    }

    func testOtherMessagesAreLeftAlone() {
        XCTAssertEqual(
            DownloadManager.annotatedWithInstalledVersion(
                YtDlpService.transientFormatMessage, ytDlpStatus: outdatedStatus),
            YtDlpService.transientFormatMessage)
    }

    func testHealthyProbeAddsNothing() {
        XCTAssertEqual(
            DownloadManager.annotatedWithInstalledVersion(
                YtDlpService.staleToolMessage, ytDlpStatus: .ok(version: "2026.08.01")),
            YtDlpService.staleToolMessage)
    }

    func testUnknownProbeAddsNothing() {
        XCTAssertEqual(
            DownloadManager.annotatedWithInstalledVersion(YtDlpService.staleToolMessage, ytDlpStatus: nil),
            YtDlpService.staleToolMessage)
    }

    func testAnnotationIsIdempotentAcrossRetries() {
        // A retried item re-finalizes: the annotated message no longer equals
        // staleToolMessage, so it must not grow a second suffix.
        let once = DownloadManager.annotatedWithInstalledVersion(
            YtDlpService.staleToolMessage, ytDlpStatus: outdatedStatus)
        let twice = DownloadManager.annotatedWithInstalledVersion(once, ytDlpStatus: outdatedStatus)
        XCTAssertEqual(once, twice)
    }

    func testAnnotatedMessageStaysOutsideTheAutoRetryFamily() {
        let annotated = DownloadManager.annotatedWithInstalledVersion(
            YtDlpService.staleToolMessage, ytDlpStatus: outdatedStatus)
        XCTAssertFalse(DownloadManager.isEmptySuccessMessage(annotated))
    }
}
