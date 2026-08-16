import XCTest

@testable import XDownloader

/// The one-shot empty-success auto-retry and the external-redirect message
/// replacement must classify by the structural `emptySuccessFailure` flag —
/// set at the points that COMPOSE an empty-success failure — never by
/// comparing user-facing message strings, so reworded copy can neither
/// silently gain nor silently lose auto-retry behavior.
@MainActor
final class EmptySuccessFlagTests: XCTestCase {

    private func item(failedWith message: String) -> DownloadItem {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        item.status = .failed(message)
        return item
    }

    // MARK: - Flag lifecycle

    func testFlagDefaultsToFalse() {
        XCTAssertFalse(DownloadItem(url: "https://x.com/a/status/1").emptySuccessFailure)
    }

    func testResetForReattemptClearsFlag() {
        // Per-attempt state: the gallery-dl fallback and the auto-retry itself
        // reset the item within one run — a stale flag from a previous tool
        // must not re-arm the retry for a different failure.
        let item = DownloadItem(url: "https://x.com/a/status/1")
        item.emptySuccessFailure = true
        item.resetForReattempt()

        XCTAssertFalse(item.emptySuccessFailure)
    }

    // MARK: - Auto-retry gate honors the flag, not the string

    func testAutoRetryFiresOnFlagRegardlessOfMessageWording() {
        // Brand-new empty-success copy must keep the retry without anyone
        // remembering to update a string predicate.
        let item = item(failedWith: "The post has no media this tool can reach.")
        item.emptySuccessFailure = true

        XCTAssertTrue(DownloadManager.shouldAutoRetryEmptySuccess(item))
    }

    func testAutoRetryDoesNotFireOnEmptySuccessLookingMessageWithoutFlag() {
        // Same-looking copy set anywhere else (or a hand-crafted string) must
        // NOT re-queue the item — only the real empty-success set-points do.
        let item = item(failedWith: GalleryDlService.noMediaTwitterMessage)

        XCTAssertFalse(DownloadManager.shouldAutoRetryEmptySuccess(item))
    }

    func testAutoRetryFiresAtMostOnce() {
        let item = item(failedWith: "The post has no media this tool can reach.")
        item.emptySuccessFailure = true
        item.autoRetryAttempted = true

        XCTAssertFalse(DownloadManager.shouldAutoRetryEmptySuccess(item))
    }

    func testAutoRetryRequiresAFailedStatus() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        item.emptySuccessFailure = true
        item.status = .completed

        XCTAssertFalse(DownloadManager.shouldAutoRetryEmptySuccess(item))
    }

    // MARK: - External-redirect replacement honors the flag, not the string

    func testReplacementAlwaysConvertsTheSentinel() {
        let item = item(failedWith: DownloadStatus.externalRedirectSentinel)

        XCTAssertTrue(DownloadManager.shouldReplaceWithExternalRedirectMessage(item))
    }

    func testReplacementHonorsFlagRegardlessOfMessageWording() {
        let item = item(failedWith: "The post has no media this tool can reach.")
        item.externalRedirectURL = "https://example.com/article"
        item.emptySuccessFailure = true

        XCTAssertTrue(DownloadManager.shouldReplaceWithExternalRedirectMessage(item))
    }

    func testReplacementIgnoresEmptySuccessLookingMessageWithoutFlag() {
        // A real (non-empty-success) failure must never be eaten by the
        // external-link explanation just because its wording looks similar.
        let item = item(failedWith: GalleryDlService.noMediaTwitterMessage)
        item.externalRedirectURL = "https://example.com/article"

        XCTAssertFalse(DownloadManager.shouldReplaceWithExternalRedirectMessage(item))
    }

    func testReplacementRequiresADetectedURLWhenNotTheSentinel() {
        let item = item(failedWith: "The post has no media this tool can reach.")
        item.emptySuccessFailure = true

        XCTAssertFalse(DownloadManager.shouldReplaceWithExternalRedirectMessage(item))
    }

    func testReplacementRequiresAFailedStatus() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        item.externalRedirectURL = "https://example.com/article"
        item.emptySuccessFailure = true
        item.status = .completed

        XCTAssertFalse(DownloadManager.shouldReplaceWithExternalRedirectMessage(item))
    }

    // MARK: - Applying the replacement disarms the retry

    func testApplyingReplacementDisarmsTheAutoRetry() {
        // Before Phase 4d the replacement copy simply never matched the
        // string predicate; with the structural flag, disarming must be an
        // explicit part of the replacement or the gate right after it would
        // burn the one-shot retry re-running a link-only tweet.
        let item = item(failedWith: "The post has no media this tool can reach.")
        item.externalRedirectURL = "https://example.com/article"
        item.emptySuccessFailure = true

        DownloadManager.applyExternalRedirectReplacementIfNeeded(item)

        XCTAssertEqual(
            item.status,
            .failed(DownloadStatus.externalRedirectMessage(detectedURL: "https://example.com/article")))
        XCTAssertFalse(item.emptySuccessFailure)
        XCTAssertFalse(DownloadManager.shouldAutoRetryEmptySuccess(item))
    }

    func testApplyingReplacementLeavesRealFailuresUntouched() {
        let item = item(failedWith: GalleryDlService.nsfwTweetMessage)
        item.externalRedirectURL = "https://example.com/article"

        DownloadManager.applyExternalRedirectReplacementIfNeeded(item)

        XCTAssertEqual(item.status, .failed(GalleryDlService.nsfwTweetMessage))
    }
}
