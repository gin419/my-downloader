import XCTest

@testable import XDownloader

/// The combined Homebrew repair flow: exact argument construction (install
/// missing → reinstall broken → upgrade outdated), environment composition,
/// ANSI stripping, noise suppression, failure mapping, and the post-repair
/// outcome judgment.
final class BrewFlowTests: XCTestCase {

    private func health(_ id: String, _ status: ToolStatus) -> ToolHealth {
        ToolHealth(
            id: id, name: id, brewPackage: id, docsURL: "",
            path: status == .missing ? nil : "/opt/homebrew/bin/\(id)",
            status: status)
    }

    // MARK: - Argument construction

    func testCombinedFlowInstallsReinstallsThenUpgrades() {
        XCTAssertEqual(
            RequirementsService.brewInvocations(
                missing: ["deno"], broken: ["gallery-dl"], outdated: ["yt-dlp", "ffmpeg"]),
            [["install", "deno"], ["reinstall", "gallery-dl"], ["upgrade", "yt-dlp", "ffmpeg"]])
    }

    func testUpgradeOnlyFlowSkipsInstall() {
        XCTAssertEqual(
            RequirementsService.brewInvocations(missing: [], broken: [], outdated: ["yt-dlp"]),
            [["upgrade", "yt-dlp"]])
    }

    func testInstallOnlyFlowSkipsUpgrade() {
        XCTAssertEqual(
            RequirementsService.brewInvocations(missing: ["gallery-dl", "deno"], broken: [], outdated: []),
            [["install", "gallery-dl", "deno"]])
    }

    func testNothingToDoRunsNothing() {
        XCTAssertEqual(RequirementsService.brewInvocations(missing: [], broken: [], outdated: []), [])
    }

    // MARK: - Environment composition

    func testUpgradeEnvironmentStripsAnInheritedNoAutoUpdate() {
        // A shell-profile `export HOMEBREW_NO_AUTO_UPDATE=1` must not silently
        // keep the index stale through an upgrade.
        let env = RequirementsService.brewEnvironment(
            base: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOME": "/Users/gin"],
            allowAutoUpdate: true)
        XCTAssertNil(env["HOMEBREW_NO_AUTO_UPDATE"])
        XCTAssertEqual(env["PATH"], Homebrew.fullPATH)
        XCTAssertEqual(env["HOME"], "/Users/gin")
    }

    func testInstallEnvironmentDisablesAutoUpdate() {
        let env = RequirementsService.brewEnvironment(base: [:], allowAutoUpdate: false)
        XCTAssertEqual(env["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertEqual(env["PATH"], Homebrew.fullPATH)
    }

    // MARK: - ANSI stripping (load-bearing for the log and failure matching)

    func testStripsRealBrewColorCodes() {
        XCTAssertEqual(
            RequirementsService.strippedANSI("\u{1B}[34m==>\u{1B}[0m \u{1B}[1mUpgrading yt-dlp\u{1B}[0m"),
            "==> Upgrading yt-dlp")
    }

    func testPlainLinesPassThroughUnchanged() {
        XCTAssertEqual(RequirementsService.strippedANSI("==> Pouring yt-dlp"), "==> Pouring yt-dlp")
    }

    // MARK: - Log noise classification

    func testAlreadyInstalledNoiseIsRecognized() {
        XCTAssertTrue(
            RequirementsService.isSuppressedBrewNoise(
                "Warning: deno 2.4.2 is already installed and up-to-date."))
        XCTAssertTrue(
            RequirementsService.isSuppressedBrewNoise("Warning: yt-dlp 2026.08.01 already installed"))
    }

    func testRealLogLinesAreNotNoise() {
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

    // MARK: - Post-repair outcome (judged AFTER the forced re-probe)

    func testRepairOutcomeSuccessOnlyWhenNoProblemRemains() {
        XCTAssertEqual(
            RequirementsService.repairOutcome(exitCode: 0, remainingProblems: [], log: ["==> Upgrading yt-dlp"]),
            .success)
    }

    func testExitZeroWithARemainingProblemNamesTheIndexLag() {
        // brew exited 0 ("already up-to-date") but the tool is still outdated:
        // never claim "All done".
        XCTAssertEqual(
            RequirementsService.repairOutcome(
                exitCode: 0,
                remainingProblems: [health("yt-dlp", .outdated(installed: "2024.11.04", detail: nil))],
                log: ["Warning: yt-dlp 2024.11.04 already installed"]),
            .indexMayLag(
                "Homebrew reports it's already at its newest available version — the index may lag the release; try again later or update manually (brew upgrade yt-dlp)."
            ))
    }

    func testFailedRepairMapsNetworkCause() {
        XCTAssertEqual(
            RequirementsService.repairOutcome(
                exitCode: 1, remainingProblems: [],
                log: ["curl: (6) Could not resolve host: github.com"]),
            .failed(RequirementsService.brewNetworkFailureMessage))
    }

    func testFailedRepairWithoutKnownCauseKeepsLogPointer() {
        XCTAssertEqual(
            RequirementsService.repairOutcome(
                exitCode: 1, remainingProblems: [], log: ["Error: something else"]),
            .failed(nil))
    }
}
