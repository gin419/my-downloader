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
        XCTAssertFalse(
            DownloadManager.isEmptySuccessMessage(DownloadManager.cookiesFileMissingFailureMessage))
        XCTAssertFalse(
            DownloadManager.isEmptySuccessMessage(DownloadManager.cookiesFileInaccessibleFeedbackMessage))
        XCTAssertFalse(
            DownloadManager.isEmptySuccessMessage(DownloadManager.cookieSaveFailedFeedbackMessage))
    }
}
