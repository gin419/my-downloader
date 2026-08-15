import XCTest

@testable import XDownloader

/// Pure failure-message composition: gallery-dl's exit bitmask decode, the
/// site-branched empty-success copy, the external-redirect replacement, the
/// signal-aware yt-dlp exit line, and the persisted-status decode fallback.
@MainActor
final class FailureMessageCompositionTests: XCTestCase {

    // MARK: - gallery-dl exit bitmask decode

    func testExitBitmaskDecodesSingleCauses() {
        let cases: [(code: Int32, cause: String)] = [
            (4, "a network/HTTP error"),
            (8, "a connection problem"),
            (16, "an authorization problem — check Settings → Cookies"),
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
            DownloadManager.externalRedirectMessage(detectedURL: "https://example.com/article?x=1"),
            "This tweet links to external content (example.com) — paste that link directly to download it.")
    }

    func testExternalRedirectMessageWithoutURLDropsParenthetical() {
        let expected = "This tweet links to external content — paste that link directly to download it."
        XCTAssertEqual(DownloadManager.externalRedirectMessage(detectedURL: nil), expected)
        // Host-less strings (a relative path) fall back the same way.
        XCTAssertEqual(DownloadManager.externalRedirectMessage(detectedURL: "/relative/path"), expected)
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
}

/// The empty-success auto-retry predicate, pinned in both directions: it must
/// keep matching every "exit 0, no files" message (the paths that auto-retry
/// today) and must NOT match any of the Phase-2 error-mapping copy — the
/// pre-Phase-2 substring check ("cookies.txt", …) would have silently re-run
/// broken-tool and auth failures as messages changed.
@MainActor
final class EmptySuccessMatcherTests: XCTestCase {

    func testEveryEmptySuccessMessageTriggersAutoRetry() {
        let matching = [
            GalleryDlService.noMediaTwitterMessage,
            GalleryDlService.noMediaInstagramMessage,
            GalleryDlService.noMediaRedditMessage,
            GalleryDlService.noMediaGenericMessage,
            // Dynamic variant: the run's captured warning is appended.
            GalleryDlService.noMediaWarningPrefix + "this tweet is age-restricted",
            DownloadManager.ytDlpEmptySuccessMessage,
            // The gallery-dl-missing hint may be appended in the !ranFallback branch.
            DownloadManager.ytDlpEmptySuccessMessage + DownloadManager.galleryDlMissingHint,
        ]
        for message in matching {
            XCTAssertTrue(DownloadManager.isEmptySuccessMessage(message), "must auto-retry: \(message)")
        }
    }

    func testNoErrorMappingMessageTriggersAutoRetry() {
        let nonMatching = [
            YtDlpService.privateVideoMessage,
            YtDlpService.ageRestrictedMessage,
            YtDlpService.membersOnlyMessage,
            YtDlpService.botCheckMessage,
            YtDlpService.http403Message,
            YtDlpService.cookieDatabaseMessage,
            YtDlpService.ffmpegMissingMessage,
            YtDlpService.staleToolMessage,
            YtDlpService.missingJSRuntimeMessage,
            YtDlpService.transientFormatMessage,
            GalleryDlService.nsfwTweetMessage,  // mentions cookies.txt — the old matcher's trap
            GalleryDlService.protectedTweetMessage,
            GalleryDlService.xAuthMessage,
            GalleryDlService.internalErrorMessage,
            GalleryDlService.instagramChallengeMessage,
            GalleryDlService.unsupportedURLMessage,
            GalleryDlService.instagramLoginMessage,
            GalleryDlService.exitFailureMessage(code: 16, lastWarning: "AuthRequired"),
            DownloadManager.ytDlpFailureMessage(code: 2, wasSignal: false, lastWarning: nil),
            DownloadManager.ytDlpFailureMessage(code: 15, wasSignal: true, lastWarning: nil),
            DownloadManager.externalRedirectMessage(detectedURL: "https://example.com/a"),
            DownloadStatus.decodedFailureFallbackMessage,
            "external_redirect",  // the internal sentinel must never re-queue
        ]
        for message in nonMatching {
            XCTAssertFalse(DownloadManager.isEmptySuccessMessage(message), "must NOT auto-retry: \(message)")
        }
    }
}

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

    func testGalleryDlRateLimitWaitIsCapturedAndSurfacedAsEta() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        GalleryDlService.parseLine("[twitter][info] Waiting for 14 minutes until 12:34:56 (rate limit)", item: item)

        XCTAssertEqual(item.lastToolWarning, "Waiting for 14 minutes until 12:34:56 (rate limit)")
        XCTAssertEqual(item.eta, "14 minutes (rate limit)")
        XCTAssertEqual(item.status, .queued, "the wait is not a failure")
    }

    func testExternalRedirectURLIsRememberedAndClearedOnReattempt() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        var terminated = false
        YtDlpService.parseLine("[redirect] Following redirect to: https://example.com/article", item: item) {
            terminated = true
        }

        XCTAssertTrue(terminated, "the redirect must kill yt-dlp so a fallback can take over")
        XCTAssertEqual(item.status, .failed("external_redirect"), "the internal sentinel itself must survive parsing")
        XCTAssertEqual(item.externalRedirectURL, "https://example.com/article")

        item.resetForReattempt()
        XCTAssertNil(item.externalRedirectURL)
    }
}
