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

    /// Run-level is defined by tweet_id ALONE: a row with a URL but no tweet
    /// id is unreachable by per-item resolution (it matches the event's
    /// tweet id, never NULL), so it must behave as run-level — full-scan
    /// retry — while keeping the URL as its informative title.
    func testUrlOnlyRowIsRunLevelWithFullScanRetry() {
        let row = failure(tweetID: nil, url: "https://x.com/gin/status/999", category: .network)
        XCTAssertTrue(row.isRunLevel)
        XCTAssertEqual(row.displayTitle, "https://x.com/gin/status/999")
        XCTAssertEqual(row.retryActionTitle, "Retry Sync")
    }

    /// With the real stale-tool signatures now routed into .tool, its
    /// run-level row title must name the outdated tool — "gallery-dl" alone
    /// named the messenger, not the cause.
    func testToolRunLevelRowTitleNamesOutdatedTool() {
        let tool = failure(tweetID: nil, url: nil, category: .tool)
        XCTAssertTrue(tool.isRunLevel)
        XCTAssertEqual(tool.displayTitle, "Whole sync failed — outdated tool")
        XCTAssertEqual(tool.retryActionTitle, "Retry Sync")
    }

    // MARK: - classify() keyword truth (4e: stale-tool and auth blind spots)

    /// X's primary real-world auth failure wordings must land in the
    /// authentication bucket — in .unknown, the RAW line becomes the card
    /// headline while the app's good sign-in guidance sits unused.
    func testClassifyRoutesRealAuthWordingsToAuthentication() {
        XCTAssertEqual(
            LikesSyncFailureCategory.classify("[twitter][error] 'Could not authenticate you'"),
            .authentication)
        XCTAssertEqual(
            LikesSyncFailureCategory.classify("[twitter][error] Missing authorization header"),
            .authentication)
        XCTAssertEqual(
            LikesSyncFailureCategory.classify("auth_token missing or expired"),
            .authentication)
        XCTAssertEqual(
            LikesSyncFailureCategory.classify("[twitter][error] Your account is temporarily locked"),
            .authentication)
        XCTAssertEqual(
            LikesSyncFailureCategory.classify("[twitter][error] X blocked your account after unusual activity"),
            .authentication)
    }

    func testClassifyRoutesProtectedTweetsToUnavailable() {
        XCTAssertEqual(
            LikesSyncFailureCategory.classify("[twitter][error] This account's tweets are protected"),
            .unavailable)
    }

    /// The signatures a genuinely stale gallery-dl actually prints must
    /// reach .tool — the only bucket whose copy says "update gallery-dl".
    /// None of the bucket's previous keywords occur in real staleness output.
    func testClassifyRoutesStaleToolSignaturesToTool() {
        XCTAssertEqual(
            LikesSyncFailureCategory.classify(
                "gallery-dl: error: unrecognized arguments: --Print post:likes-sync"),
            .tool)
        XCTAssertEqual(
            LikesSyncFailureCategory.classify("usage: gallery-dl [OPTION]... URL..."), .tool)
        XCTAssertEqual(
            LikesSyncFailureCategory.classify(
                "[twitter][error] An unexpected error occurred: KeyError - 'data'"),
            .tool)
        XCTAssertEqual(LikesSyncFailureCategory.classify("KeyError: 'legacy'"), .tool)
        XCTAssertEqual(
            LikesSyncFailureCategory.classify("TypeError: 'NoneType' object is not subscriptable"),
            .tool)
        XCTAssertEqual(
            LikesSyncFailureCategory.classify(
                "[twitter][error] Unable to retrieve Tweets from this timeline"),
            .tool)
    }

    /// The bare "process" keyword misrouted unrelated lines into .tool
    /// (whose copy tells users to update gallery-dl); only the exact
    /// bracketed "[process][error]" level qualifies.
    func testClassifyProcessKeywordRequiresExactBracketedForm() {
        XCTAssertEqual(
            LikesSyncFailureCategory.classify("[process][error] An error occurred in postprocessing"),
            .tool)
        XCTAssertEqual(
            LikesSyncFailureCategory.classify("gallery-dl could not process this item."),
            .unknown)
    }

    // MARK: - Endpoint 404 vs item 404 (4e fix 4)

    /// When X retires a GraphQL endpoint EVERY call 404s — that is the
    /// installed tool speaking a retired dialect, not deleted content. A
    /// single tweet or media file 404ing is genuinely gone and keeps the
    /// unavailable copy.
    func testEndpoint404IsToolWhilePerItem404StaysUnavailable() {
        let graphql = "[twitter][error] '404 Not Found' for 'https://x.com/i/api/graphql/AbCdEf/Likes'"
        let legacyAPI =
            "[twitter][error] '404 Not Found' for 'https://api.twitter.com/graphql/AbCdEf/UserByScreenName'"
        XCTAssertTrue(LikesSyncFailureCategory.isEndpointNotFound(graphql))
        XCTAssertEqual(LikesSyncFailureCategory.classify(graphql), .tool)
        XCTAssertTrue(LikesSyncFailureCategory.isEndpointNotFound(legacyAPI))
        XCTAssertEqual(LikesSyncFailureCategory.classify(legacyAPI), .tool)

        let media = "[downloader.http][warning] '404 Not Found' for 'https://pbs.twimg.com/media/AbC.jpg'"
        let status = "[twitter][error] '404 Not Found' for 'https://x.com/gin/status/123'"
        XCTAssertFalse(LikesSyncFailureCategory.isEndpointNotFound(media))
        XCTAssertEqual(LikesSyncFailureCategory.classify(media), .unavailable)
        XCTAssertFalse(LikesSyncFailureCategory.isEndpointNotFound(status))
        XCTAssertEqual(LikesSyncFailureCategory.classify(status), .unavailable)
        XCTAssertFalse(
            LikesSyncFailureCategory.isEndpointNotFound(
                "requesting https://x.com/i/api/graphql/AbCdEf/Likes"),
            "an API URL in a line without a 404 is not an endpoint failure")
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
