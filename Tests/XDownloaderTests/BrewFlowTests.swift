import XCTest

@testable import XDownloader

/// The combined Homebrew repair flow: exact argument construction (install
/// missing, then upgrade outdated), "already installed" noise suppression,
/// and the friendly network-failure line above the log.
final class BrewFlowTests: XCTestCase {

    // MARK: - Argument construction

    func testCombinedFlowInstallsThenUpgrades() {
        XCTAssertEqual(
            RequirementsService.brewInvocations(missing: ["deno"], outdated: ["yt-dlp", "ffmpeg"]),
            [["install", "deno"], ["upgrade", "yt-dlp", "ffmpeg"]])
    }

    func testUpgradeOnlyFlowSkipsInstall() {
        XCTAssertEqual(
            RequirementsService.brewInvocations(missing: [], outdated: ["yt-dlp"]),
            [["upgrade", "yt-dlp"]])
    }

    func testInstallOnlyFlowSkipsUpgrade() {
        XCTAssertEqual(
            RequirementsService.brewInvocations(missing: ["gallery-dl", "deno"], outdated: []),
            [["install", "gallery-dl", "deno"]])
    }

    func testNothingToDoRunsNothing() {
        XCTAssertEqual(RequirementsService.brewInvocations(missing: [], outdated: []), [])
    }

    // MARK: - Log noise suppression

    func testAlreadyInstalledNoiseIsSuppressed() {
        XCTAssertTrue(
            RequirementsService.isSuppressedBrewNoise(
                "Warning: deno 2.4.2 is already installed and up-to-date."))
        XCTAssertTrue(
            RequirementsService.isSuppressedBrewNoise("Warning: yt-dlp 2026.08.01 already installed"))
    }

    func testRealLogLinesAreKept() {
        XCTAssertFalse(RequirementsService.isSuppressedBrewNoise("==> Upgrading yt-dlp 2024.11.04 -> 2026.08.01"))
        XCTAssertFalse(RequirementsService.isSuppressedBrewNoise("Error: yt-dlp: no bottle available!"))
    }

    // MARK: - Failure mapping

    func testNetworkFailureGetsFriendlyLine() {
        XCTAssertEqual(
            RequirementsService.friendlyBrewFailure(inLog: [
                "==> Upgrading yt-dlp",
                "curl: (6) Could not resolve host: github.com",
            ]),
            "Homebrew couldn't reach the network — check your connection and try again.")
    }

    func testUnreachableNetworkGetsFriendlyLine() {
        XCTAssertEqual(
            RequirementsService.friendlyBrewFailure(inLog: [
                "Error: Failure while executing; `git fetch` exited with 128: fatal: unable to access: Network is unreachable"
            ]),
            RequirementsService.brewNetworkFailureMessage)
    }

    func testOtherFailuresKeepTheLogPointer() {
        XCTAssertNil(
            RequirementsService.friendlyBrewFailure(inLog: [
                "Error: yt-dlp: no bottle available for this macOS version"
            ]))
        XCTAssertNil(RequirementsService.friendlyBrewFailure(inLog: []))
    }
}
