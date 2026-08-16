import XCTest

@testable import XDownloader

@MainActor
private final class FakeLikesSyncProcessRunner: LikesSyncProcessRunning {
    struct Run {
        var lines: [String]
        var exitCode: Int32
        var waitsForCancellation = false
        /// Runs after the lines are emitted, before the process "exits" —
        /// simulates user actions (Ignore/Restore) landing mid-run.
        var afterLines: (@MainActor () -> Void)?
    }

    private(set) var invocations: [[String]] = []
    var runs: [Run]

    init(runs: [Run]) {
        self.runs = runs
    }

    func run(
        executablePath _: String,
        arguments: [String],
        register _: @escaping (Process) -> Void,
        unregister _: @escaping () -> Void,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Int32 {
        invocations.append(arguments)
        let run = runs.removeFirst()
        if run.waitsForCancellation {
            while !Task.isCancelled { await Task.yield() }
            return 15
        }
        for line in run.lines {
            onLine(line)
            await Task.yield()
        }
        run.afterLines?()
        return run.exitCode
    }
}

@MainActor
final class DownloadManagerLikesSyncTests: XCTestCase {
    private func makeManager(
        runs: [FakeLikesSyncProcessRunner.Run]
    ) -> (DownloadManager, FakeLikesSyncProcessRunner, LikesSyncStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("likes-manager-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "likes-manager-\(UUID().uuidString)")!
        let runner = FakeLikesSyncProcessRunner(runs: runs)
        let store = LikesSyncStore(directory: directory)
        let manager = DownloadManager(
            history: HistoryStore(directory: directory),
            queueStore: QueueStore(directory: directory),
            settingsStore: SettingsStore(defaults: defaults),
            likesSyncStore: store,
            likesProcessRunner: runner,
            galleryDlPathProvider: { "/fake/gallery-dl" })
        manager.outputDirectory = directory.appendingPathComponent("downloads")
        manager.twitterHandle = "@gin"
        return (manager, runner, store, directory)
    }

    private func waitForLikesRun(_ manager: DownloadManager) async {
        for _ in 0..<10_000 {
            if manager.likesSyncSnapshot.status != .idle,
                !manager.likesSyncSnapshot.status.isActive
            {
                return
            }
            await Task.yield()
        }
        XCTFail("Likes sync did not finish")
    }

    private func waitForVerification(_ manager: DownloadManager) async {
        for _ in 0..<10_000 {
            if manager.likesAccessVerification != .verifying { return }
            await Task.yield()
        }
        XCTFail("Likes verification did not finish")
    }

    private func event(_ name: String, _ json: String) -> String {
        "\(name):likes-sync\t\(json)"
    }

    func testFirstRunDownloadsAndSecondRunArchiveSkipsWithoutDuplicates() async throws {
        let post = event(
            "post", #"{"tweet_id":"123","url":"https://x.com/gin/status/123","author":{"nick":"gin"}}"#)
        let after = event(
            "after", #"{"tweet_id":"123","media_id":"m1","_path":"/tmp/a.jpg","extension":"jpg"}"#)
        let postAfter = event("post-after", #"{"tweet_id":"123"}"#)
        let skip = event(
            "skip", #"{"tweet_id":"123","media_id":"m1","_path":"/tmp/a.jpg","extension":"jpg"}"#)
        let (manager, runner, store, _) = makeManager(runs: [
            .init(lines: [post, after, postAfter], exitCode: 0),
            .init(lines: [post, skip, postAfter], exitCode: 0),
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.downloaded, 1)
        XCTAssertEqual(store.count("likes_tweets"), 1)
        XCTAssertEqual(store.count("likes_media"), 1)

        manager.startLikesSync()
        await waitForLikesRun(manager)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.downloaded, 0)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.skipped, 1)
        XCTAssertEqual(store.count("likes_media"), 1)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertTrue(runner.invocations[0].contains("extractor.twitter.cards=false"))
        XCTAssertEqual(runner.invocations[0].last, "https://x.com/gin/likes")
    }

    func testCookieExtractionInfoDoesNotFailSuccessfulVerification() async throws {
        let (manager, runner, _, _) = makeManager(runs: [
            .init(
                lines: ["[cookies][info] Extracted 863 cookies from Chrome", "likes-verify\t123"],
                exitCode: 0)
        ])

        manager.verifyLikesAccess()
        await waitForVerification(manager)

        XCTAssertEqual(manager.likesAccessVerification, .verified(try LikesSyncHandle("@gin")))
        XCTAssertEqual(runner.invocations.count, 1)
    }

    /// Exit 0 with ZERO likes-verify output is what the wrong account's
    /// session (likes are private) or an empty account looks like — a distinct
    /// third state, neither "Verified" nor a diagnostic failure. Info-level
    /// lines don't change that.
    func testVerificationWithZeroLikesVisibleIsThirdStateNotVerified() async throws {
        let handle = try LikesSyncHandle("@gin")
        let (manager, _, _, _) = makeManager(runs: [
            .init(lines: ["[cookies][info] Extracted 863 cookies from Chrome"], exitCode: 0)
        ])

        manager.verifyLikesAccess()
        await waitForVerification(manager)

        XCTAssertEqual(manager.likesAccessVerification, .noLikesVisible(handle))
        XCTAssertTrue(
            LikesAccessVerification.noLikesVisibleMessage(for: handle)
                .hasPrefix("Could not see any likes for @gin."))
    }

    func testVerificationFailureStillNamesTheDiagnostic() async throws {
        let (manager, _, _, _) = makeManager(runs: [
            .init(lines: ["[twitter][error] Login required"], exitCode: 1)
        ])

        manager.verifyLikesAccess()
        await waitForVerification(manager)

        guard case .failed(let message) = manager.likesAccessVerification else {
            return XCTFail("expected .failed, got \(manager.likesAccessVerification)")
        }
        XCTAssertTrue(message.contains("X login could not be verified"))
    }

    func testCookieExtractionInfoDoesNotCreateSuccessfulSyncFailure() async {
        let (manager, _, _, _) = makeManager(runs: [
            .init(lines: ["[cookies][info] Extracted 863 cookies from Chrome"], exitCode: 0)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertTrue(manager.likesSyncSnapshot.failures.isEmpty)
    }

    func testCancelBeforeRunnerStartsFinishesCancelledWithoutFailure() async throws {
        let (manager, _, store, _) = makeManager(runs: [
            .init(lines: [], exitCode: 15, waitsForCancellation: true)
        ])

        manager.startLikesSync()
        manager.cancelLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .cancelled)
        XCTAssertTrue(manager.likesSyncSnapshot.failures.isEmpty)
        let accountID = try XCTUnwrap(store.account(for: LikesSyncHandle("gin"))?.id)
        XCTAssertEqual(store.latestRun(accountID: accountID)?.status, .cancelled)
    }

    func testFailedItemCanRetryItsURLAndResolveTheFailure() async throws {
        let url = "https://x.com/gin/status/999"
        let error = event(
            "error", #"{"tweet_id":"999","url":"https://x.com/gin/status/999","message":"connection timeout"}"#)
        let skip = event(
            "skip", #"{"tweet_id":"999","media_id":"m999","_path":"/tmp/retry.jpg"}"#)
        let (manager, runner, _, _) = makeManager(runs: [
            .init(lines: [error], exitCode: 1),
            .init(lines: [skip], exitCode: 0),
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .failed)
        XCTAssertEqual(failure.category, .network)

        manager.retryLikesFailure(failure)
        await waitForLikesRun(manager)
        XCTAssertEqual(runner.invocations.last?.last, url)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertTrue(manager.likesSyncSnapshot.failures.isEmpty)
    }

    func testIgnoringLastFailureClearsAttentionButKeepsIgnoredCount() async throws {
        let error = event("error", #"{"tweet_id":"999","message":"item unavailable"}"#)
        let (manager, _, store, _) = makeManager(runs: [
            .init(lines: [error], exitCode: 1)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        manager.ignoreLikesFailure(failure)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.failed, 0)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.ignored, 1)
        let accountID = try XCTUnwrap(store.account(for: LikesSyncHandle("gin"))?.id)
        XCTAssertEqual(store.latestRun(accountID: accountID)?.status, .completed)
    }

    // MARK: - Run-level failures stop being sticky (fix 1)

    /// A run-level failure (here: sign-in) must not flag every later flawless
    /// sync forever — a clean full scan resolves it and the card returns to
    /// "Likes sync completed."
    func testFlawlessFullScanAfterRunLevelFailureClearsTheCard() async throws {
        let post = event("post", #"{"tweet_id":"123","url":"https://x.com/gin/status/123"}"#)
        let after = event("after", #"{"tweet_id":"123","media_id":"m1","_path":"/tmp/a.jpg"}"#)
        let postAfter = event("post-after", #"{"tweet_id":"123"}"#)
        let (manager, _, store, _) = makeManager(runs: [
            .init(lines: ["[twitter][error] Login required"], exitCode: 1),
            .init(lines: [post, after, postAfter], exitCode: 0),
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .failed)
        XCTAssertTrue(failure.isRunLevel)
        XCTAssertEqual(failure.category, .authentication)

        manager.startLikesSync()
        await waitForLikesRun(manager)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertTrue(manager.likesSyncSnapshot.failures.isEmpty)
        XCTAssertEqual(manager.likesSyncSnapshot.message, "Likes sync completed.")
        let accountID = try XCTUnwrap(store.account(for: LikesSyncHandle("gin"))?.id)
        XCTAssertTrue(store.pendingFailures(accountID: accountID).isEmpty)
    }

    /// Retrying a run-level failure re-runs the full scan; when that re-run
    /// succeeds, the failure is resolved instead of lingering.
    func testRetryingRunLevelFailureRunsFullScanAndResolvesItOnSuccess() async throws {
        let post = event("post", #"{"tweet_id":"123","url":"https://x.com/gin/status/123"}"#)
        let after = event("after", #"{"tweet_id":"123","media_id":"m1","_path":"/tmp/a.jpg"}"#)
        let postAfter = event("post-after", #"{"tweet_id":"123"}"#)
        let (manager, runner, _, _) = makeManager(runs: [
            .init(lines: ["[twitter][error] Login required"], exitCode: 1),
            .init(lines: [post, after, postAfter], exitCode: 0),
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        XCTAssertTrue(failure.isRunLevel)

        manager.retryLikesFailure(failure)
        await waitForLikesRun(manager)
        XCTAssertEqual(runner.invocations.last?.last, "https://x.com/gin/likes")
        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertTrue(manager.likesSyncSnapshot.failures.isEmpty)
    }

    /// A run-level failure recorded by the CURRENT run blocks the resolution —
    /// exit 0 alone is not proof when the run itself just failed at zero items.
    func testRunLevelFailureRecordedThisRunIsNotResolvedByItsOwnExitZero() async throws {
        let (manager, _, _, _) = makeManager(runs: [
            .init(lines: ["[twitter][warning] 429 Too Many Requests"], exitCode: 0)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .failed)
        XCTAssertEqual(manager.likesSyncSnapshot.failures.count, 1)
        XCTAssertEqual(
            manager.likesSyncSnapshot.message, "X rate-limited this sync. Wait a while, then retry.")
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        XCTAssertEqual(failure.category, .rateLimited)
        XCTAssertEqual(failure.displayTitle, "Whole sync failed — rate limit")
        XCTAssertEqual(failure.retryActionTitle, "Retry Sync")
    }

    // MARK: - Rate-limit waits are not failures (fix 2)

    /// gallery-dl's info-level wait notice as the LAST line of a flawless run
    /// must not turn the run into "needs attention".
    func testInfoWaitLineOnFlawlessRunDoesNotRecordFailure() async throws {
        let post = event("post", #"{"tweet_id":"123","url":"https://x.com/gin/status/123"}"#)
        let after = event("after", #"{"tweet_id":"123","media_id":"m1","_path":"/tmp/a.jpg"}"#)
        let postAfter = event("post-after", #"{"tweet_id":"123"}"#)
        let wait = "[twitter][info] Waiting until 09:20:00 (rate limit)"
        let (manager, _, _, _) = makeManager(runs: [
            .init(lines: [post, after, postAfter, wait], exitCode: 0)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertTrue(manager.likesSyncSnapshot.failures.isEmpty)
        XCTAssertEqual(manager.likesSyncSnapshot.message, "Likes sync completed.")
    }

    /// A warning-level rate-limit line at exit 0 escalates only when the run
    /// made no progress; with items downloaded it was just a survived pause.
    func testWarningRateLimitAtExitZeroWithProgressCompletes() async throws {
        let post = event("post", #"{"tweet_id":"123","url":"https://x.com/gin/status/123"}"#)
        let after = event("after", #"{"tweet_id":"123","media_id":"m1","_path":"/tmp/a.jpg"}"#)
        let postAfter = event("post-after", #"{"tweet_id":"123"}"#)
        let warn = "[twitter][warning] 429 Too Many Requests"
        let (manager, _, _, _) = makeManager(runs: [
            .init(lines: [post, after, postAfter, warn], exitCode: 0)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertTrue(manager.likesSyncSnapshot.failures.isEmpty)
    }

    // MARK: - Zero visible tweets is not "up to date" (fix 4)

    func testCompletedRunWithZeroTweetsSaysNoLikesVisible() async throws {
        let (manager, _, _, _) = makeManager(runs: [
            .init(lines: [], exitCode: 0)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        let message = try XCTUnwrap(manager.likesSyncSnapshot.message)
        XCTAssertTrue(message.hasPrefix("No likes were visible for @gin."), message)
    }

    func testCompletedRunWithOnlySkipsStillSaysUpToDate() async throws {
        let post = event("post", #"{"tweet_id":"123","url":"https://x.com/gin/status/123"}"#)
        let skip = event("skip", #"{"tweet_id":"123","media_id":"m1","_path":"/tmp/a.jpg"}"#)
        let postAfter = event("post-after", #"{"tweet_id":"123"}"#)
        let (manager, _, _, _) = makeManager(runs: [
            .init(lines: [post, skip, postAfter], exitCode: 0)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertEqual(manager.likesSyncSnapshot.message, "Up to date — no new media.")
    }

    // MARK: - Stale gallery-dl stops masquerading as other failures (4e)

    /// A gallery-dl too old for this app's CLI options exits 2 printing
    /// argparse lines. The card must blame the outdated binary — the
    /// constant copy, category .tool, the outdated-tool title — never the
    /// user's login, and never headline the raw argparse line.
    func testArgparseExitTwoIsReportedAsOutdatedToolNotLogin() async throws {
        let (manager, _, _, _) = makeManager(runs: [
            .init(
                lines: [
                    "usage: gallery-dl [OPTION]... URL...",
                    "gallery-dl: error: unrecognized arguments: --Print post:likes-sync",
                ],
                exitCode: 2)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .failed)
        XCTAssertEqual(manager.likesSyncSnapshot.message, DownloadManager.likesStaleToolExitTwoMessage)
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        XCTAssertEqual(failure.category, .tool)
        XCTAssertEqual(failure.displayTitle, "Whole sync failed — outdated tool")
        XCTAssertFalse(failure.message.contains("Verify the selected X login"))
    }

    /// The Settings Verify flow hits the same argparse wall — its status row
    /// must give the same update-gallery-dl guidance, not a login hint.
    func testVerificationExitTwoNamesTheOutdatedTool() async throws {
        let (manager, _, _, _) = makeManager(runs: [
            .init(
                lines: ["gallery-dl: error: unrecognized arguments: --Print post:likes-sync"],
                exitCode: 2)
        ])

        manager.verifyLikesAccess()
        await waitForVerification(manager)

        guard case .failed(let message) = manager.likesAccessVerification else {
            return XCTFail("expected .failed, got \(manager.likesAccessVerification)")
        }
        XCTAssertEqual(message, DownloadManager.likesStaleToolExitTwoMessage)
    }

    /// A whole-run 404 on X's GraphQL API is a retired endpoint — the
    /// historically documented stale-tool failure — not deleted content.
    func testEndpointNotFoundRunHeadlinesRetiredAPINotDeletedContent() async throws {
        let endpoint404 =
            "[twitter][error] '404 Not Found' for 'https://x.com/i/api/graphql/AbCdEf/Likes'"
        let (manager, _, _, _) = makeManager(runs: [.init(lines: [endpoint404], exitCode: 4)])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .failed)
        XCTAssertEqual(manager.likesSyncSnapshot.message, DownloadManager.likesRetiredEndpointMessage)
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        XCTAssertEqual(failure.category, .tool)
        XCTAssertEqual(failure.displayTitle, "Whole sync failed — outdated tool")
    }

    /// A stale-extractor crash (Python traceback tail) headlines the
    /// polished update-gallery-dl copy; the raw diagnostic stays visible in
    /// the same row message as secondary detail — never AS the headline.
    func testStaleCrashHeadlinesPolishedCopyAndKeepsRawAsDetail() async throws {
        let (manager, _, _, _) = makeManager(runs: [
            .init(
                lines: ["Traceback (most recent call last):", "KeyError: 'legacy'"],
                exitCode: 1)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .failed)
        let message = try XCTUnwrap(manager.likesSyncSnapshot.message)
        XCTAssertTrue(message.hasPrefix("This gallery-dl version cannot sync X Likes."), message)
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        XCTAssertEqual(failure.category, .tool)
        XCTAssertTrue(failure.message.contains("KeyError: 'legacy'"), "raw diagnostic must stay as detail")
    }

    /// X's primary real-world auth wording now reaches the auth bucket, so
    /// the card shows the app's sign-in guidance instead of the raw line.
    func testCouldNotAuthenticateHeadlinesTheAuthGuidance() async throws {
        let (manager, _, _, _) = makeManager(runs: [
            .init(lines: ["[twitter][error] 'Could not authenticate you'"], exitCode: 1)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .failed)
        let message = try XCTUnwrap(manager.likesSyncSnapshot.message)
        XCTAssertTrue(message.hasPrefix("X login could not be verified."), message)
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        XCTAssertEqual(failure.category, .authentication)
        XCTAssertEqual(failure.displayTitle, "Whole sync failed — sign-in")
    }

    // MARK: - Failed-run headline names the newest cause (fix 6)

    /// Restoring an ignored stale failure mid-run bumps its updated_at past
    /// the new failure's — the headline must still cite the current run's
    /// cause, not the resurrected old row.
    func testMidRunRestoreOfStaleFailureCannotMaskNewCause() async throws {
        let oldError = event("error", #"{"tweet_id":"111","message":"login required"}"#)
        let newError = event("error", #"{"tweet_id":"222","message":"no space left on device"}"#)
        var second = FakeLikesSyncProcessRunner.Run(lines: [newError], exitCode: 1)
        let (manager, runner, _, _) = makeManager(runs: [
            .init(lines: [oldError], exitCode: 1)
        ])
        second.afterLines = { [weak manager] in manager?.restoreIgnoredLikesFailures() }

        manager.startLikesSync()
        await waitForLikesRun(manager)
        let stale = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        manager.ignoreLikesFailure(stale)

        runner.runs.append(second)
        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .failed)
        XCTAssertEqual(manager.likesSyncSnapshot.failures.count, 2)
        XCTAssertEqual(manager.likesSyncSnapshot.message, "no space left on device")
    }
}
