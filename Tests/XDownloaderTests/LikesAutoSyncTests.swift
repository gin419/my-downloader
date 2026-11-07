import XCTest

@testable import XDownloader

final class LikesAutoSyncTests: XCTestCase {
    // MARK: - Delays and backoff

    func testFirstCheckComesSoonThenTheRegularInterval() {
        var schedule = LikesAutoSyncSchedule()
        XCTAssertEqual(schedule.nextDelay(interval: 1800), 60)
        schedule.markChecked()
        XCTAssertEqual(schedule.nextDelay(interval: 1800), 1800)
    }

    func testRateLimitsDoubleTheIntervalUpToTheCap() {
        var schedule = LikesAutoSyncSchedule()
        schedule.record(.rateLimited)
        XCTAssertEqual(schedule.nextDelay(interval: 1800), 3600)
        schedule.record(.transientFailure)
        XCTAssertEqual(schedule.nextDelay(interval: 1800), 7200)
        for _ in 0..<10 { schedule.record(.rateLimited) }
        XCTAssertEqual(schedule.backoffLevel, LikesAutoSyncSchedule.maxBackoffLevel)
        // 30 min × 16 = 8 h, under the 12 h cap.
        XCTAssertEqual(schedule.nextDelay(interval: 1800), 8 * 3600)
        // 6 h × 16 would be 4 days; capped at 12 h.
        XCTAssertEqual(schedule.nextDelay(interval: 6 * 3600), 12 * 3600)
    }

    func testSuccessResetsBackoff() {
        var schedule = LikesAutoSyncSchedule()
        schedule.record(.rateLimited)
        schedule.record(.rateLimited)
        schedule.record(.succeeded)
        XCTAssertEqual(schedule.backoffLevel, 0)
        XCTAssertEqual(schedule.nextDelay(interval: 900), 900)
    }

    func testCancelledRunChangesNothing() {
        var schedule = LikesAutoSyncSchedule()
        schedule.record(.rateLimited)
        schedule.record(.cancelled)
        XCTAssertEqual(schedule.backoffLevel, 1)
        XCTAssertFalse(schedule.isPaused)
    }

    func testFailuresOnlyTheUserCanFixPauseUntilResume() {
        var schedule = LikesAutoSyncSchedule()
        schedule.record(.needsUser(.authentication))
        XCTAssertEqual(schedule.pauseReason, .authentication)
        XCTAssertEqual(
            LikesAutoSyncSchedule.decide(
                enabled: true, paused: schedule.isPaused, syncActive: false, verifying: false,
                hasValidHandle: true, hasGalleryDl: true),
            .skip(.paused))
        schedule.resume()
        XCTAssertNil(schedule.pauseReason)
        XCTAssertEqual(schedule.backoffLevel, 0)
        XCTAssertEqual(schedule.nextDelay(interval: 1800), 60)
    }

    // MARK: - Should a due check run?

    func testDecideRunsOnlyWhenEverythingIsReady() {
        func decide(
            enabled: Bool = true, paused: Bool = false, syncActive: Bool = false,
            verifying: Bool = false, handle: Bool = true, tool: Bool = true
        ) -> LikesAutoSyncDecision {
            LikesAutoSyncSchedule.decide(
                enabled: enabled, paused: paused, syncActive: syncActive, verifying: verifying,
                hasValidHandle: handle, hasGalleryDl: tool)
        }
        XCTAssertEqual(decide(), .run)
        XCTAssertEqual(decide(enabled: false), .skip(.disabled))
        XCTAssertEqual(decide(paused: true), .skip(.paused))
        XCTAssertEqual(decide(syncActive: true), .skip(.busy))
        XCTAssertEqual(decide(verifying: true), .skip(.busy))
        XCTAssertEqual(decide(handle: false), .skip(.invalidHandle))
        XCTAssertEqual(decide(tool: false), .skip(.galleryDlMissing))
    }

    // MARK: - Run outcomes

    /// `-A N` makes gallery-dl raise StopExtraction, which its job catches
    /// without touching the exit status: an aborted incremental scan is a
    /// plain exit 0 and must read as success.
    func testAbortedIncrementalScanIsSuccess() {
        XCTAssertEqual(
            LikesAutoSyncRunOutcome.classify(
                exitCode: 0, cancelled: false, runLevelCategory: nil, rateLimitTruncated: false),
            .succeeded)
    }

    func testOutcomeClassification() {
        func classify(
            _ category: LikesSyncFailureCategory?, exit: Int32 = 1, cancelled: Bool = false,
            truncated: Bool = false
        ) -> LikesAutoSyncRunOutcome {
            LikesAutoSyncRunOutcome.classify(
                exitCode: exit, cancelled: cancelled, runLevelCategory: category,
                rateLimitTruncated: truncated)
        }
        XCTAssertEqual(classify(.authentication), .needsUser(.authentication))
        XCTAssertEqual(classify(.tool), .needsUser(.tool))
        XCTAssertEqual(classify(.disk), .needsUser(.disk))
        XCTAssertEqual(classify(.rateLimited), .rateLimited)
        XCTAssertEqual(classify(.network), .transientFailure)
        XCTAssertEqual(classify(.unknown), .transientFailure)
        XCTAssertEqual(classify(nil, exit: 0, truncated: true), .rateLimited)
        XCTAssertEqual(classify(.authentication, cancelled: true), .cancelled)
        // Per-item failures only (exit 4, no run-level row): not a reason to
        // slow down, or one deleted tweet near the top would back off forever.
        XCTAssertEqual(classify(nil, exit: 4), .succeeded)
    }

    // MARK: - Notifications

    func testOnlyNewsOrAttentionIsAnnounced() {
        XCTAssertFalse(
            LikesAutoSyncSchedule.shouldNotify(outcome: .succeeded, downloadedCount: 0, newFailureCount: 0))
        XCTAssertTrue(
            LikesAutoSyncSchedule.shouldNotify(outcome: .succeeded, downloadedCount: 3, newFailureCount: 0))
        XCTAssertTrue(
            LikesAutoSyncSchedule.shouldNotify(outcome: .succeeded, downloadedCount: 0, newFailureCount: 1))
        XCTAssertFalse(
            LikesAutoSyncSchedule.shouldNotify(outcome: .rateLimited, downloadedCount: 0, newFailureCount: 0))
        XCTAssertFalse(
            LikesAutoSyncSchedule.shouldNotify(outcome: .transientFailure, downloadedCount: 0, newFailureCount: 0))
        XCTAssertTrue(
            LikesAutoSyncSchedule.shouldNotify(
                outcome: .needsUser(.authentication), downloadedCount: 0, newFailureCount: 0))
        XCTAssertFalse(
            LikesAutoSyncSchedule.shouldNotify(outcome: .cancelled, downloadedCount: 2, newFailureCount: 0))
    }

    func testNoticeCopy() {
        let saved = DownloadManager.likesAutoSyncNotice(
            outcome: .succeeded, downloadedCount: 2, newFailureCount: 0, handle: "@gin")
        XCTAssertEqual(saved.title, "New Likes downloaded")
        XCTAssertEqual(saved.body, "Saved 2 new files from @gin's Likes.")

        let mixed = DownloadManager.likesAutoSyncNotice(
            outcome: .succeeded, downloadedCount: 1, newFailureCount: 1, handle: "@gin")
        XCTAssertEqual(mixed.body, "Saved 1 new file from @gin's Likes. 1 item could not be downloaded.")

        let paused = DownloadManager.likesAutoSyncNotice(
            outcome: .needsUser(.authentication), downloadedCount: 0, newFailureCount: 0, handle: "@gin")
        XCTAssertEqual(paused.title, "Automatic Likes sync paused")
        XCTAssertEqual(paused.body, LikesAutoSyncPauseReason.authentication.message)
    }

    // MARK: - Settings

    func testIntervalOptionsNeverGoBelowFifteenMinutes() {
        XCTAssertEqual(LikesAutoSyncInterval.allCases.map(\.seconds).min(), 900)
        XCTAssertEqual(LikesAutoSyncInterval.default, .thirtyMinutes)
        XCTAssertEqual(LikesAutoSyncInterval.nearest(toSeconds: 60), .fifteenMinutes)
        XCTAssertEqual(LikesAutoSyncInterval.nearest(toSeconds: 3500), .oneHour)
        XCTAssertEqual(LikesAutoSyncInterval.nearest(toSeconds: 999_999), .sixHours)
    }

    func testSettingsDefaultOffAndRoundTrip() {
        let defaults = UserDefaults(suiteName: "likes-auto-sync-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.loadLikesAutoSync(), LikesAutoSyncSettings(isEnabled: false, interval: .thirtyMinutes))

        store.saveLikesAutoSync(LikesAutoSyncSettings(isEnabled: true, interval: .threeHours))
        XCTAssertEqual(store.loadLikesAutoSync(), LikesAutoSyncSettings(isEnabled: true, interval: .threeHours))

        defaults.set(5, forKey: "likesAutoSyncIntervalSeconds")
        XCTAssertEqual(store.loadLikesAutoSync().interval, .fifteenMinutes)
    }
}
