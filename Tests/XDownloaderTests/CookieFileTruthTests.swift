import XCTest

@testable import XDownloader

/// A user's cookies.txt can silently stop working in three ways — yt-dlp's
/// post-download cookie-save traceback, a stale security-scoped bookmark, and
/// a stored plain path whose file vanished. These tests pin the classifier
/// that recognises the traceback and keep the new user-facing copy from ever
/// joining the empty-success auto-retry family.
@MainActor
final class CookieFileTruthTests: XCTestCase {

    private let cookiesPath = "/tmp/profile/cookies.txt"

    // MARK: - isCookieSaveTraceback classifier

    func testFileNotFoundTracebackWithMatchingFilenameIsCookieSaveTraceback() {
        let line = "FileNotFoundError: [Errno 2] No such file or directory: '/tmp/profile/cookies.txt'"
        XCTAssertTrue(DownloadManager.isCookieSaveTraceback(message: line, cookiesFilePath: cookiesPath))
    }

    func testPermissionErrorTracebackWithMatchingFilenameIsCookieSaveTraceback() {
        let line = "PermissionError: [Errno 13] Permission denied: '/tmp/profile/cookies.txt'"
        XCTAssertTrue(DownloadManager.isCookieSaveTraceback(message: line, cookiesFilePath: cookiesPath))
    }

    /// Both the error tokens and the filename match case-insensitively — a
    /// "Cookies.TXT" selection still matches the traceback's quoted path.
    func testClassifierMatchesCaseInsensitively() {
        let line = "FILENOTFOUNDERROR: [Errno 2] No such file or directory: '/tmp/profile/cookies.txt'"
        XCTAssertTrue(
            DownloadManager.isCookieSaveTraceback(
                message: line, cookiesFilePath: "/tmp/Profile/Cookies.TXT"))
    }

    /// A FileNotFoundError about some OTHER file is a real failure — only the
    /// run's own cookies file earns the rescue.
    func testTracebackWithoutCookiesFilenameIsNotCookieSaveTraceback() {
        let line = "FileNotFoundError: [Errno 2] No such file or directory: '/tmp/fragments.part'"
        XCTAssertFalse(DownloadManager.isCookieSaveTraceback(message: line, cookiesFilePath: cookiesPath))
    }

    /// Mentioning cookies.txt is not enough — the NSFW guidance copy mentions
    /// it too. Only the Python cookie-save traceback tokens qualify.
    func testUnrelatedErrorMentioningCookiesFilenameIsNotCookieSaveTraceback() {
        let line = "ERROR: NSFW tweet requires authentication — export a cookies.txt in Settings"
        XCTAssertFalse(DownloadManager.isCookieSaveTraceback(message: line, cookiesFilePath: cookiesPath))
    }

    func testNilCookiesPathIsNeverCookieSaveTraceback() {
        let line = "FileNotFoundError: [Errno 2] No such file or directory: '/tmp/profile/cookies.txt'"
        XCTAssertFalse(DownloadManager.isCookieSaveTraceback(message: line, cookiesFilePath: nil))
    }

    // MARK: - New copy stays out of the empty-success auto-retry family

    func testCookieMessagesNeverMatchEmptySuccess() {
        // Structural gate since Phase 4d: the cookie-truth branches never arm
        // `item.emptySuccessFailure`, so their copy can't re-queue an item no
        // matter how it is worded.
        for message in [
            DownloadManager.cookiesFileMissingFailureMessage,
            DownloadManager.cookiesFileInaccessibleFeedbackMessage,
            DownloadManager.cookieSaveFailedFeedbackMessage,
        ] {
            let item = DownloadItem(url: "https://x.com/gin/status/1")
            item.status = .failed(message)
            XCTAssertFalse(
                DownloadManager.shouldAutoRetryEmptySuccess(item), "\"\(message)\" must not auto-retry")
        }
    }

    // MARK: - isCookieSaveOnlyFailure rescue decision (mirror of subtitleOnlyFailure)

    private func failedItem(outputPath: String?, message: String) -> DownloadItem {
        let item = DownloadItem(url: "https://x.com/gin/status/1")
        item.outputPath = outputPath
        item.status = .failed(message)
        return item
    }

    func testCookieSaveOnlyFailureRescuesDownloadedMedia() {
        let item = failedItem(
            outputPath: "/tmp/video.mp4",
            message: "FileNotFoundError: [Errno 2] No such file or directory: '/tmp/profile/cookies.txt'")
        XCTAssertTrue(
            DownloadManager.isCookieSaveOnlyFailure(item: item, exitedCleanly: false, cookiesFilePath: cookiesPath))
    }

    func testCookieSaveOnlyFailureRequiresMediaOnDisk() {
        let item = failedItem(
            outputPath: nil,
            message: "FileNotFoundError: [Errno 2] No such file or directory: '/tmp/profile/cookies.txt'")
        XCTAssertFalse(
            DownloadManager.isCookieSaveOnlyFailure(item: item, exitedCleanly: false, cookiesFilePath: cookiesPath))
    }

    func testCookieSaveOnlyFailureRequiresNonZeroExit() {
        let item = failedItem(
            outputPath: "/tmp/video.mp4",
            message: "FileNotFoundError: [Errno 2] No such file or directory: '/tmp/profile/cookies.txt'")
        XCTAssertFalse(
            DownloadManager.isCookieSaveOnlyFailure(item: item, exitedCleanly: true, cookiesFilePath: cookiesPath))
    }

    func testCookieSaveOnlyFailureRequiresMatchingTraceback() {
        let item = failedItem(
            outputPath: "/tmp/video.mp4",
            message: "ERROR: unable to download video data: HTTP Error 403: Forbidden")
        XCTAssertFalse(
            DownloadManager.isCookieSaveOnlyFailure(item: item, exitedCleanly: false, cookiesFilePath: cookiesPath))
    }

    func testCookieSaveOnlyFailureRequiresFailedStatus() {
        let item = DownloadItem(url: "https://x.com/gin/status/1")
        item.outputPath = "/tmp/video.mp4"
        item.status = .completed
        XCTAssertFalse(
            DownloadManager.isCookieSaveOnlyFailure(item: item, exitedCleanly: false, cookiesFilePath: cookiesPath))
    }

    // MARK: - resolveCookiesForDownload / setCookiesFile manager behavior

    private func makeManager(seedDefaults: ((UserDefaults) -> Void)? = nil) -> DownloadManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookie-truth-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "cookie-truth-\(UUID().uuidString)")!
        seedDefaults?(defaults)
        let manager = DownloadManager(
            history: HistoryStore(directory: directory),
            queueStore: QueueStore(directory: directory),
            settingsStore: SettingsStore(defaults: defaults),
            likesSyncStore: LikesSyncStore(directory: directory),
            galleryDlPathProvider: { nil })
        manager.outputDirectory = directory.appendingPathComponent("downloads")
        return manager
    }

    /// Bug 2 (plain-path half): a stored cookiesFilePath whose file no longer
    /// exists must behave exactly like .bookmarkFailed — browser-cookie
    /// fallback plus the persistent feedback, once per session.
    func testResolveFallsBackToBrowserCookiesWhenStoredPathIsMissing() {
        let manager = makeManager()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookie-truth-missing-\(UUID().uuidString)")
            .appendingPathComponent("cookies.txt").path
        manager.cookiesFilePath = missing

        let resolved = manager.resolveCookiesForDownload()

        XCTAssertNil(resolved.path)
        XCTAssertNil(resolved.granted)
        XCTAssertEqual(manager.captureFeedback?.message, DownloadManager.cookiesFileInaccessibleFeedbackMessage)
        XCTAssertEqual(manager.captureFeedback?.isPersistent, true)

        // Once per session: the next affected download must not re-post it.
        let firstID = manager.captureFeedback?.id
        _ = manager.resolveCookiesForDownload()
        XCTAssertEqual(manager.captureFeedback?.id, firstID)
    }

    func testResolveUsesStoredPlainPathWhenFileExists() throws {
        let manager = makeManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookie-truth-exists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("cookies.txt")
        try "# Netscape HTTP Cookie File".write(to: file, atomically: true, encoding: .utf8)
        manager.cookiesFilePath = file.path

        let resolved = manager.resolveCookiesForDownload()

        XCTAssertEqual(resolved.path, file.path)
        XCTAssertNil(resolved.granted)
        XCTAssertNil(manager.captureFeedback)
    }

    func testResolveWithNoCookiesFileConfiguredStaysSilent() {
        let manager = makeManager()

        let resolved = manager.resolveCookiesForDownload()

        XCTAssertNil(resolved.path)
        XCTAssertNil(resolved.granted)
        XCTAssertNil(manager.captureFeedback)
    }

    /// Bug 2 (bookmark half): a bookmark that no longer resolves must surface
    /// itself instead of silently downgrading to browser cookies.
    func testResolveSurfacesFeedbackWhenBookmarkFails() {
        let manager = makeManager { defaults in
            // Garbage bookmark data: loads on init, never resolves.
            defaults.set(Data([1, 2, 3]), forKey: "cookiesFileBookmarkData")
            defaults.set("/tmp/profile/cookies.txt", forKey: "cookiesFilePath")
        }

        let resolved = manager.resolveCookiesForDownload()

        XCTAssertNil(resolved.path)
        XCTAssertNil(resolved.granted)
        XCTAssertEqual(manager.captureFeedback?.message, DownloadManager.cookiesFileInaccessibleFeedbackMessage)
        XCTAssertEqual(manager.captureFeedback?.isPersistent, true)
    }

    /// Bug 3: bookmark creation fails at selection time (the file must exist
    /// for a bookmark to be created). The plain path still stores — downloads
    /// can work while the app stays open — but the user hears immediately
    /// that persistence is broken.
    func testSetCookiesFileWithFailingBookmarkStoresPathAndSurfacesFeedback() {
        let manager = makeManager()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookie-truth-nofile-\(UUID().uuidString)")
            .appendingPathComponent("cookies.txt")

        manager.setCookiesFile(from: missing)

        XCTAssertEqual(manager.cookiesFilePath, missing.path)
        XCTAssertEqual(manager.captureFeedback?.message, DownloadManager.cookiesFileInaccessibleFeedbackMessage)
        XCTAssertEqual(manager.captureFeedback?.isPersistent, true)
    }
}
