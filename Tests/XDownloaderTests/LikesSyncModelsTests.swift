import XCTest

@testable import XDownloader

/// Pure decisions behind the Likes Sync surfaces: the Settings "Verify"
/// outcome must not report success when gallery-dl saw zero likes, and
/// run-level failure rows must present themselves as whole-sync failures
/// instead of masquerading as items.
final class LikesSyncModelsTests: XCTestCase {

    // MARK: - Verify outcome (third state)

    func testVerifyExitZeroWithLikesObservedIsVerified() {
        XCTAssertEqual(
            LikesAccessVerification.outcome(exitCode: 0, sawLikes: true, hasDiagnostics: false),
            .verified)
        XCTAssertEqual(
            LikesAccessVerification.outcome(exitCode: 0, sawLikes: true, hasDiagnostics: true),
            .verified)
    }

    /// Exit 0 with ZERO likes observed is what the wrong account's session
    /// (likes are private) or an empty account looks like — it must be its own
    /// state, never "Verified".
    func testVerifyExitZeroWithoutLikesObservedIsNoLikesVisible() {
        XCTAssertEqual(
            LikesAccessVerification.outcome(exitCode: 0, sawLikes: false, hasDiagnostics: false),
            .noLikesVisible)
    }

    func testVerifyNonZeroExitIsFailed() {
        XCTAssertEqual(
            LikesAccessVerification.outcome(exitCode: 1, sawLikes: false, hasDiagnostics: true),
            .failed)
        XCTAssertEqual(
            LikesAccessVerification.outcome(exitCode: 64, sawLikes: true, hasDiagnostics: false),
            .failed)
    }

    /// Exit 0 with a captured diagnostic and no likes keeps reporting the
    /// diagnostic as a failure — the message names the precise cause.
    func testVerifyExitZeroWithDiagnosticsAndNoLikesIsFailed() {
        XCTAssertEqual(
            LikesAccessVerification.outcome(exitCode: 0, sawLikes: false, hasDiagnostics: true),
            .failed)
    }

    // MARK: - Failure row titling

    private func failure(
        tweetID: String?, url: String?, category: LikesSyncFailureCategory
    ) -> LikesSyncFailure {
        LikesSyncFailure(
            id: "1:\(tweetID ?? url ?? category.rawValue)",
            accountID: 1,
            runID: "run-1",
            tweetID: tweetID,
            url: url,
            category: category,
            message: "message",
            ignoredAt: nil,
            resolvedAt: nil,
            retryCount: 0)
    }

    func testPerItemRowsKeepURLOrTweetIDTitleAndRetryLabel() {
        let byURL = failure(tweetID: "123", url: "https://x.com/a/status/123", category: .network)
        XCTAssertFalse(byURL.isRunLevel)
        XCTAssertEqual(byURL.displayTitle, "https://x.com/a/status/123")
        XCTAssertEqual(byURL.retryActionTitle, "Retry")

        let byID = failure(tweetID: "123", url: nil, category: .network)
        XCTAssertEqual(byID.displayTitle, "Tweet 123")
        XCTAssertEqual(byID.retryActionTitle, "Retry")
    }

    /// A run-level row (no tweet, no URL) describes the whole sync — its title
    /// names the category and its button admits it re-runs the full scan.
    func testRunLevelRowsAreTitledByCategoryWithRetrySyncLabel() {
        let auth = failure(tweetID: nil, url: nil, category: .authentication)
        XCTAssertTrue(auth.isRunLevel)
        XCTAssertEqual(auth.displayTitle, "Whole sync failed — sign-in")
        XCTAssertEqual(auth.retryActionTitle, "Retry Sync")

        let rate = failure(tweetID: nil, url: nil, category: .rateLimited)
        XCTAssertEqual(rate.displayTitle, "Whole sync failed — rate limit")
        XCTAssertEqual(rate.retryActionTitle, "Retry Sync")

        let disk = failure(tweetID: nil, url: nil, category: .disk)
        XCTAssertEqual(disk.displayTitle, "Whole sync failed — disk")

        let unknown = failure(tweetID: nil, url: nil, category: .unknown)
        XCTAssertEqual(unknown.displayTitle, "Whole sync failed")
    }

    // MARK: - Failed-run headline (fix 6)

    private func failure(id: String, runID: String?, message: String) -> LikesSyncFailure {
        LikesSyncFailure(
            id: id, accountID: 1, runID: runID, tweetID: id, url: nil,
            category: .network, message: message,
            ignoredAt: nil, resolvedAt: nil, retryCount: 0)
    }

    /// A stale row can outrank the new failure in the pending list (Ignore /
    /// Restore bump its updated_at) — the headline must still cite the current
    /// run's cause.
    func testHeadlinePrefersCurrentRunFailureOverStaleFirstRow() {
        let stale = failure(id: "111", runID: "run-1", message: "login required")
        let fresh = failure(id: "222", runID: "run-2", message: "no space left on device")

        let headline = LikesSyncFailure.headline(from: [stale, fresh], currentRunID: "run-2")
        XCTAssertEqual(headline?.message, "no space left on device")
    }

    /// Without a current-run match (or a run id at all) the list's own order —
    /// most recently updated first — decides.
    func testHeadlineFallsBackToFirstRowWhenCurrentRunHasNoFailure() {
        let a = failure(id: "111", runID: "run-1", message: "first")
        let b = failure(id: "222", runID: "run-2", message: "second")

        XCTAssertEqual(
            LikesSyncFailure.headline(from: [a, b], currentRunID: "run-9")?.message, "first")
        XCTAssertEqual(LikesSyncFailure.headline(from: [a, b], currentRunID: nil)?.message, "first")
        XCTAssertNil(LikesSyncFailure.headline(from: [], currentRunID: "run-1"))
    }
}
