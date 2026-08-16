import XCTest

@testable import XDownloader

/// The install sheet's footer primary button adapts to the problem mix — pins
/// the three labels from the approved mockup, and that a healthy toolbox
/// offers no primary action at all.
final class InstallSheetLabelTests: XCTestCase {

    func testOnlyMissingToolsOffersInstall() {
        XCTAssertEqual(
            InstallSheetModel.primaryActionLabel(missingCount: 2, outdatedCount: 0),
            "Install Missing Tools")
    }

    func testOnlyOutdatedToolsOffersUpdate() {
        XCTAssertEqual(
            InstallSheetModel.primaryActionLabel(missingCount: 0, outdatedCount: 1),
            "Update Outdated Tools")
    }

    func testMixedProblemsOfferTheCombinedFlow() {
        XCTAssertEqual(
            InstallSheetModel.primaryActionLabel(missingCount: 1, outdatedCount: 1),
            "Install Missing + Update Outdated")
    }

    func testHealthyToolboxHasNoPrimaryAction() {
        XCTAssertNil(InstallSheetModel.primaryActionLabel(missingCount: 0, outdatedCount: 0))
    }

    // MARK: - Row meta lines ("path · version · age")

    private func health(_ id: String, path: String?, _ status: ToolStatus) -> ToolHealth {
        ToolHealth(id: id, name: id, brewPackage: id, docsURL: "", path: path, status: status)
    }

    func testMetaLineForOKToolShowsPathAndVersion() {
        XCTAssertEqual(
            InstallSheetModel.metaLine(
                for: health("yt-dlp", path: "/usr/local/bin/yt-dlp", .ok(version: "2026.08.01"))),
            "/usr/local/bin/yt-dlp · 2026.08.01")
    }

    func testMetaLineForOutdatedToolIncludesAge() {
        XCTAssertEqual(
            InstallSheetModel.metaLine(
                for: health(
                    "yt-dlp", path: "/usr/local/bin/yt-dlp",
                    .outdated(installed: "2024.11.04", detail: "21 months old"))),
            "/usr/local/bin/yt-dlp · 2024.11.04 · 21 months old")
    }

    func testMetaLineForMissingToolExplainsItself() {
        XCTAssertEqual(
            InstallSheetModel.metaLine(for: health("deno", path: nil, .missing)),
            "not found in any search path")
    }

    func testMetaLineForBrokenToolShowsTheProbeDetail() {
        XCTAssertEqual(
            InstallSheetModel.metaLine(
                for: health("yt-dlp", path: "/usr/local/bin/yt-dlp", .broken(detail: "can't run"))),
            "/usr/local/bin/yt-dlp · can't run")
    }

    // MARK: - Status pills

    func testPillLabels() {
        XCTAssertEqual(InstallSheetModel.pillLabel(for: .ok(version: "1.0")), "OK")
        XCTAssertEqual(InstallSheetModel.pillLabel(for: .outdated(installed: "1.0", detail: nil)), "Outdated")
        XCTAssertEqual(InstallSheetModel.pillLabel(for: .missing), "Missing")
        XCTAssertEqual(InstallSheetModel.pillLabel(for: .broken(detail: "can't run")), "Broken")
    }

    // MARK: - Manual commands per problem kind

    func testManualCommandsMatchTheProblemKind() {
        XCTAssertEqual(
            InstallSheetModel.manualCommand(for: health("deno", path: nil, .missing)),
            "brew install deno")
        XCTAssertEqual(
            InstallSheetModel.manualCommand(
                for: health("yt-dlp", path: "/x/yt-dlp", .broken(detail: "can't run"))),
            "brew reinstall yt-dlp")
        XCTAssertEqual(
            InstallSheetModel.manualCommand(
                for: health("ffmpeg", path: "/x/ffmpeg", .outdated(installed: "9.0.1", detail: nil))),
            "brew upgrade ffmpeg")
    }
}
