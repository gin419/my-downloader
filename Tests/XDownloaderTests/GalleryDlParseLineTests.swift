import XCTest

@testable import XDownloader

/// `GalleryDlService.parseLine`'s instagram-login branch replaces the raw
/// "[instagram][error] … login …" line with an actionable message. The raw line
/// itself contains "error", so the first test also pins the branch's position
/// *before* the generic error check: reordered below it, the generic branch
/// would set `.failed(rawLine)` first and the login branch's first-failure
/// guard would then suppress the friendly message.
@MainActor
final class GalleryDlParseLineTests: XCTestCase {

    private let loginLine =
        "[instagram][error] HTTP redirect to login page (https://www.instagram.com/accounts/login/)"

    func testInstagramLoginErrorGetsActionableMessage() {
        let item = DownloadItem(url: "https://www.instagram.com/p/Daoe_4TTVY0/")
        GalleryDlService.parseLine(loginLine, item: item)
        guard case .failed(let message) = item.status else {
            return XCTFail("expected .failed, got \(item.status)")
        }
        XCTAssertTrue(message.contains("Instagram requires login"))
        XCTAssertFalse(message.contains("[instagram][error]"))
    }

    /// The first failure wins: a login error after an earlier fatal error must
    /// not overwrite the original message.
    func testFirstFailureIsKeptWhenLoginErrorFollows() {
        let item = DownloadItem(url: "https://www.instagram.com/p/Daoe_4TTVY0/")
        GalleryDlService.parseLine("[instagram][error] 401 Unauthorized", item: item)
        GalleryDlService.parseLine(loginLine, item: item)
        guard case .failed(let message) = item.status else {
            return XCTFail("expected .failed, got \(item.status)")
        }
        XCTAssertEqual(message, "[instagram][error] 401 Unauthorized")
    }
}
