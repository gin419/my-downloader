import XCTest

@testable import XDownloader

/// Pure failure-message composition: gallery-dl's exit bitmask decode, the
/// site-branched empty-success copy, the external-redirect replacement, the
/// signal-aware yt-dlp exit line, and the persisted-status decode fallback.
@MainActor
final class FailureMessageCompositionTests: XCTestCase {

    // MARK: - gallery-dl exit bitmask decode

    func testExitBitmaskDecodesSingleCauses() {
        // Bit meanings verified against gallery-dl 1.32.9's exception.py:
        // 8 is ChallengeError (a bot check), NOT a network problem, and 32
        // is the InputError family.
        let cases: [(code: Int32, cause: String)] = [
            (4, "a network/HTTP error"),
            (8, "a bot-check challenge — open the site in your browser and complete it, or refresh cookies"),
            (16, "an authorization problem — check Settings → Cookies"),
            (32, "an input or format problem"),
            (64, "URL not recognized"),
            (128, "a disk or file error"),
        ]
        for c in cases {
            XCTAssertEqual(
                GalleryDlService.exitFailureMessage(code: c.code, lastWarning: nil),
                "gallery-dl failed: \(c.cause) (code \(c.code))")
        }
    }

    func testExitBitmaskJoinsCombinedCauses() {
        XCTAssertEqual(
            GalleryDlService.exitFailureMessage(code: 20, lastWarning: nil),
            "gallery-dl failed: a network/HTTP error + an authorization problem — check Settings → Cookies (code 20)")
    }

    func testExitBitmaskBareOneAndUnknownCodesAreUnspecified() {
        XCTAssertEqual(
            GalleryDlService.exitFailureMessage(code: 1, lastWarning: nil),
            "gallery-dl failed: an unspecified error (code 1)")
        XCTAssertEqual(
            GalleryDlService.exitFailureMessage(code: 2, lastWarning: nil),
            "gallery-dl failed: an unspecified error (code 2)")
    }

    func testExitBitmaskCitesLastWarning() {
        XCTAssertEqual(
            GalleryDlService.exitFailureMessage(code: 4, lastWarning: "API errors (10/10)"),
            "gallery-dl failed: a network/HTTP error (code 4) — last warning: API errors (10/10)")
    }

    // MARK: - Empty-success copy branches per site

    func testEmptySuccessMessageBranchesOnProfile() {
        XCTAssertEqual(
            GalleryDlService.emptySuccessMessage(forProfileID: "twitter"),
            GalleryDlService.noMediaTwitterMessage)
        XCTAssertEqual(
            GalleryDlService.emptySuccessMessage(forProfileID: "instagram"),
            GalleryDlService.noMediaInstagramMessage)
        XCTAssertEqual(
            GalleryDlService.emptySuccessMessage(forProfileID: "reddit"),
            GalleryDlService.noMediaRedditMessage)
        XCTAssertEqual(
            GalleryDlService.emptySuccessMessage(forProfileID: "other"),
            GalleryDlService.noMediaGenericMessage)
    }

    func testRedditEmptySuccessNoLongerTalksAboutTweets() {
        // The pre-Phase-2 else-branch told Reddit users about deleted tweets
        // and cookies.txt.
        XCTAssertEqual(
            GalleryDlService.noMediaRedditMessage,
            "No media found — the post may be deleted, or the subreddit may be private.")
    }

    // MARK: - external_redirect replacement copy

    func testExternalRedirectMessageNamesHost() {
        XCTAssertEqual(
            DownloadStatus.externalRedirectMessage(detectedURL: "https://example.com/article?x=1"),
            "This tweet links to external content (example.com) — paste that link directly to download it.")
    }

    func testExternalRedirectMessageWithoutURLDropsParenthetical() {
        let expected = "This tweet links to external content — paste that link directly to download it."
        XCTAssertEqual(DownloadStatus.externalRedirectMessage(detectedURL: nil), expected)
        // Host-less strings (a relative path) fall back the same way.
        XCTAssertEqual(DownloadStatus.externalRedirectMessage(detectedURL: "/relative/path"), expected)
    }

    // MARK: - gallery-dl-missing hint annotation

    func testGalleryDlMissingHintIsAppendedToRealFailures() {
        // The hint applies whenever gallery-dl was skipped for being missing
        // and the item ends failed — a ran fxtwitter fallback must not
        // suppress it, so composition is a pure function of the message.
        XCTAssertEqual(
            DownloadManager.annotatedWithGalleryDlMissingHint(YtDlpService.privateVideoMessage),
            YtDlpService.privateVideoMessage + DownloadManager.galleryDlMissingHint)
        XCTAssertEqual(
            DownloadManager.annotatedWithGalleryDlMissingHint(DownloadManager.ytDlpEmptySuccessMessage),
            DownloadManager.ytDlpEmptySuccessMessage + DownloadManager.galleryDlMissingHint)
    }

    func testGalleryDlMissingHintNeverAnnotatesTheSentinel() {
        // Annotating the sentinel would break the wholesale replacement
        // comparison right before finalize.
        XCTAssertEqual(
            DownloadManager.annotatedWithGalleryDlMissingHint(DownloadStatus.externalRedirectSentinel),
            DownloadStatus.externalRedirectSentinel)
    }

    // MARK: - Signal-aware yt-dlp exit line

    func testYtDlpExitMessageKeepsExitCodeWording() {
        XCTAssertEqual(
            DownloadManager.ytDlpFailureMessage(code: 2, wasSignal: false, lastWarning: nil),
            "yt-dlp exited with code 2")
    }

    func testYtDlpSignalDeathIsNotPresentedAsAnExitCode() {
        XCTAssertEqual(
            DownloadManager.ytDlpFailureMessage(code: 9, wasSignal: true, lastWarning: nil),
            "yt-dlp was terminated (signal 9)")
    }

    func testYtDlpExitMessageCitesLastWarning() {
        XCTAssertEqual(
            DownloadManager.ytDlpFailureMessage(code: 1, wasSignal: false, lastWarning: "unable to write cache"),
            "yt-dlp exited with code 1 — last warning: unable to write cache")
    }

    // MARK: - Persisted failed status without a message

    func testDecodingFailedStatusWithMissingMessageSubstitutesFallback() throws {
        for json in [#"{"kind":"failed"}"#, #"{"kind":"failed","message":""}"#] {
            let status = try JSONDecoder().decode(DownloadStatus.self, from: Data(json.utf8))
            XCTAssertEqual(status, .failed(DownloadStatus.decodedFailureFallbackMessage), "json: \(json)")
        }
    }

    func testQueueRoundtripOfEmptyFailureMessageIsNotBlank() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fm-\(UUID().uuidString)")
        let store = QueueStore(directory: dir)
        let blank = DownloadItem(url: "https://x.com/a/status/1")
        blank.status = .failed("")
        let real = DownloadItem(url: "https://x.com/a/status/2")
        real.status = .failed("boom")
        store.save([blank.toPersisted(), real.toPersisted()])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.status, .failed(DownloadStatus.decodedFailureFallbackMessage))
        XCTAssertEqual(loaded.last?.status, .failed("boom"))
    }

    func testQueueRoundtripOfPersistedSentinelIsNotBlank() {
        // A quit mid-fallback can persist the internal sentinel; after
        // relaunch it must read as the external-content explanation (no host
        // available at decode time), never as a blank red row.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fm-\(UUID().uuidString)")
        let store = QueueStore(directory: dir)
        let item = DownloadItem(url: "https://x.com/a/status/1")
        item.status = .failed(DownloadStatus.externalRedirectSentinel)
        store.save([item.toPersisted()])

        XCTAssertEqual(
            store.load().first?.status,
            .failed(DownloadStatus.externalRedirectMessage(detectedURL: nil)))
    }

    // MARK: - retryItem cross-attempt resets

    private func makeManager() -> DownloadManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fm-mgr-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "fm-mgr-\(UUID().uuidString)")!
        return DownloadManager(
            history: HistoryStore(directory: dir),
            queueStore: QueueStore(directory: dir),
            settingsStore: SettingsStore(defaults: defaults),
            likesSyncStore: LikesSyncStore(directory: dir),
            galleryDlPathProvider: { nil })
    }

    func testRetryItemClearsExternalRedirectURL() {
        // The detected URL survives resetForReattempt (fallback/auto-retry
        // resets within one run) but a user Retry is a genuinely new attempt.
        // The item is deliberately NOT in manager.items, so the queued
        // runDownload no-ops via its stillInList guard — no process spawns.
        let manager = makeManager()
        let item = DownloadItem(url: "https://x.com/a/status/1")
        item.externalRedirectURL = "https://example.com/article"
        item.status = .failed(DownloadStatus.externalRedirectSentinel)

        manager.retryItem(item)

        XCTAssertNil(item.externalRedirectURL)
        XCTAssertEqual(item.status, .queued)
    }
}

// The former EmptySuccessMatcherTests pinned the string predicate
// (`isEmptySuccessMessage`) in both directions. Phase 4d replaced the
// predicate with the structural `DownloadItem.emptySuccessFailure` flag —
// set only where an empty-success failure is composed — so message wording
// can no longer gain or lose auto-retry behavior. The flag and both of its
// consumers are pinned in EmptySuccessFlagTests.

/// Diagnostic capture in the line parsers: generic yt-dlp WARNING lines and
/// gallery-dl's rate-limit info line land in `lastToolWarning` (and the wait
/// in the row's existing ETA field) without failing the item, and the
/// external-redirect URL is remembered for the final message and cleared with
/// the other per-attempt state.
@MainActor
final class ToolWarningCaptureTests: XCTestCase {

    private func parse(_ line: String, into item: DownloadItem) {
        YtDlpService.parseLine(line, item: item) {
            XCTFail("terminate() must not fire for warning lines")
        }
    }

    func testYtDlpWarningIsCapturedWithoutPrefixOnAnySite() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse("WARNING: [twitter] 123: Some media may be missing", into: item)

        XCTAssertEqual(item.lastToolWarning, "[twitter] 123: Some media may be missing")
        XCTAssertEqual(item.status, .queued, "a warning alone must not change status")
    }

    func testYtDlpNonTellYouTubeWarningIsCapturedToo() {
        let item = DownloadItem(url: "https://youtube.com/shorts/pzBazEzxqaI")
        parse("WARNING: [youtube] YouTube said: ERROR - Precondition check failed.", into: item)

        XCTAssertEqual(item.lastToolWarning, "[youtube] YouTube said: ERROR - Precondition check failed.")
        XCTAssertEqual(item.extractorBreakage, .none)
    }

    func testStaleExtractorTellsStayOutOfLastToolWarning() {
        // Tells are consumed by the breakage diagnosis, not the warning store.
        let item = DownloadItem(url: "https://youtube.com/shorts/pzBazEzxqaI")
        parse("WARNING: [youtube] pzBazEzxqaI: Signature extraction failed: Some formats may be missing", into: item)

        XCTAssertEqual(item.extractorBreakage, .staleTool)
        XCTAssertNil(item.lastToolWarning)
    }

    func testGalleryDlBackoffWaitSurfacesAsEtaOnly() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        GalleryDlService.parseLine("[twitter][info] Waiting for 14 minutes until 12:34:56 (rate limit)", item: item)

        XCTAssertEqual(item.eta, "14 minutes (rate limited)")
        XCTAssertNil(item.lastToolWarning, "a routine wait is not a diagnostic")
        XCTAssertEqual(item.status, .queued, "the wait is not a failure")
    }

    func testGalleryDlWaitMatcherCoversNonRateLimitReasons() {
        // 429 backoffs and CloudFront blocks use the same wait() line with a
        // different reason — the matcher must not require "(rate limit)".
        let item = DownloadItem(url: "https://x.com/a/status/1")
        GalleryDlService.parseLine("[twitter][info] Waiting for 60 seconds until 12:01:00 (429 Too Many Requests)", item: item)

        XCTAssertEqual(item.eta, "60 seconds (rate limited)")
    }

    func testGalleryDlWaitDoesNotClobberACapturedWarning() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        GalleryDlService.parseLine("[twitter][warning] this tweet is age-restricted", item: item)
        GalleryDlService.parseLine("[twitter][info] Waiting for 14 minutes until 12:34:56 (rate limit)", item: item)

        XCTAssertEqual(
            item.lastToolWarning, "this tweet is age-restricted",
            "the wait line must not overwrite the diagnostic that explains an empty run")
    }

    func testGalleryDlFileLineClearsStaleWaitEta() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        GalleryDlService.parseLine("[twitter][info] Waiting for 14 minutes until 12:34:56 (rate limit)", item: item)
        GalleryDlService.parseLine("/tmp/out/user - clip [123] #1.mp4", item: item)

        XCTAssertNil(item.eta, "activity resuming must clear the stale wait ETA")
        XCTAssertEqual(item.status, .downloading)
    }

    func testExternalRedirectURLSurvivesReattemptAndIsClearedByRetry() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        var terminated = false
        YtDlpService.parseLine("[redirect] Following redirect to: https://example.com/article", item: item) {
            terminated = true
        }

        XCTAssertTrue(terminated, "the redirect must kill yt-dlp so a fallback can take over")
        XCTAssertEqual(
            item.status, .failed(DownloadStatus.externalRedirectSentinel),
            "the internal sentinel itself must survive parsing")
        XCTAssertEqual(item.externalRedirectURL, "https://example.com/article")

        // Must survive the fallback/auto-retry resets within one run so the
        // final message can name the destination even after gallery-dl ran.
        // (Cleared on a user Retry — see testRetryItemClearsExternalRedirectURL.)
        item.resetForReattempt()
        XCTAssertEqual(item.externalRedirectURL, "https://example.com/article")
    }
}
