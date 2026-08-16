import XCTest

@testable import XDownloader

/// Pure plan builder: which installers a problem can use, what freeze keeps,
/// and that unmanaged existing paths cannot be selected for overwrite.
final class ToolSetupPlanTests: XCTestCase {

    private let toolsDir = "/tmp/xdownloader-tools-test"

    private func health(
        _ id: String, path: String?, _ status: ToolStatus
    ) -> ToolHealth {
        ToolHealth(
            id: id, name: id, brewPackage: id, docsURL: "", path: path, status: status)
    }

    private func draft(
        problems: [ToolHealth],
        resolved: [String: String?],
        brewPath: String?
    ) -> ToolSetupDraft {
        ToolSetupPlanner.makeDraft(
            problems: problems,
            resolvedPath: { resolved[$0.id] ?? nil },
            brewPath: brewPath,
            toolsDirectory: toolsDir)
    }

    func testMissingWithoutBrewIsStandaloneOnly() {
        let made = draft(
            problems: [health("deno", path: nil, .missing)],
            resolved: ["deno": nil],
            brewPath: nil)
        let row = made.choices.first { $0.toolID == "deno" }
        XCTAssertEqual(row?.availableInstallers, [.standalone])
        XCTAssertEqual(row?.selectedInstaller, .standalone)
        XCTAssertEqual(row?.action, .install)
        XCTAssertTrue(row?.isSelected ?? false)
        XCTAssertEqual(row?.standaloneDestination, "\(toolsDir)/deno")
    }

    func testMissingWithBrewOffersBothAndPrefersHomebrew() {
        let made = draft(
            problems: [health("yt-dlp", path: nil, .missing)],
            resolved: ["yt-dlp": nil],
            brewPath: "/opt/homebrew/bin/brew")
        let row = made.choices.first { $0.toolID == "yt-dlp" }
        XCTAssertEqual(row?.availableInstallers, [.homebrew, .standalone])
        XCTAssertEqual(row?.selectedInstaller, .homebrew)
        XCTAssertEqual(row?.brewDestination, "/opt/homebrew/bin/yt-dlp")
    }

    func testBrewManagedOutdatedIsHomebrewOnly() {
        let made = draft(
            problems: [
                health(
                    "ffmpeg", path: "/opt/homebrew/bin/ffmpeg",
                    .outdated(installed: "6.0", detail: nil))
            ],
            resolved: ["ffmpeg": "/opt/homebrew/bin/ffmpeg"],
            brewPath: "/opt/homebrew/bin/brew")
        let row = made.choices.first { $0.toolID == "ffmpeg" }
        XCTAssertEqual(row?.availableInstallers, [.homebrew])
        XCTAssertEqual(row?.action, .update)
        XCTAssertEqual(row?.currentVersion, "6.0")
    }

    func testAppManagedBrokenIsStandaloneOnly() {
        let dest = "\(toolsDir)/gallery-dl"
        let made = draft(
            problems: [health("gallery-dl", path: dest, .broken(detail: "can't run"))],
            resolved: ["gallery-dl": dest],
            brewPath: "/opt/homebrew/bin/brew")
        let row = made.choices.first { $0.toolID == "gallery-dl" }
        XCTAssertEqual(row?.availableInstallers, [.standalone])
        XCTAssertEqual(row?.action, .reinstall)
        XCTAssertTrue(RequirementsService.isAppManagedPath(dest) || dest.hasPrefix(toolsDir))
    }

    func testUnmanagedExistingPathCannotBeSelectedForOverwrite() {
        let local = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/yt-dlp"
        let made = draft(
            problems: [
                health(
                    "yt-dlp", path: local, .outdated(installed: "2024.11.04", detail: nil))
            ],
            resolved: ["yt-dlp": local],
            brewPath: "/opt/homebrew/bin/brew")
        let row = made.choices.first { $0.toolID == "yt-dlp" }
        XCTAssertEqual(row?.unmanagedPath, local)
        XCTAssertFalse(row?.canAct ?? true)
        XCTAssertFalse(row?.isSelected ?? true)
        XCTAssertTrue(row?.availableInstallers.isEmpty ?? false)

        var mutable = made
        mutable.setSelected(toolID: "yt-dlp", selected: true)
        XCTAssertFalse(mutable.choices.first?.isSelected ?? true)
        XCTAssertNil(ToolSetupPlanner.freeze(mutable))
    }

    func testMixedPlanFreezesOnlySelectedActionableRows() {
        var made = draft(
            problems: [
                health("deno", path: nil, .missing),
                health(
                    "ffmpeg", path: "/opt/homebrew/bin/ffmpeg",
                    .outdated(installed: "6.0", detail: nil)),
                health(
                    "yt-dlp",
                    path: FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/yt-dlp",
                    .broken(detail: "can't run")),
            ],
            resolved: [
                "deno": nil,
                "ffmpeg": "/opt/homebrew/bin/ffmpeg",
                "yt-dlp": FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/yt-dlp",
            ],
            brewPath: "/opt/homebrew/bin/brew")
        made.setInstaller(toolID: "deno", installer: .standalone)
        let plan = ToolSetupPlanner.freeze(made)
        XCTAssertEqual(plan?.items.map(\.toolID), ["deno", "ffmpeg"])
        XCTAssertEqual(plan?.items.first?.installer, .standalone)
        XCTAssertEqual(plan?.items.last?.installer, .homebrew)
        XCTAssertFalse(plan?.items.contains { $0.toolID == "yt-dlp" } ?? true)
    }

    func testFreezeNilWhenEverythingUnchecked() {
        var made = draft(
            problems: [health("deno", path: nil, .missing)],
            resolved: ["deno": nil],
            brewPath: nil)
        made.setSelected(toolID: "deno", selected: false)
        XCTAssertNil(ToolSetupPlanner.freeze(made))
    }

    func testConfirmationNamesStandaloneHostAndRollback() {
        let plan = ToolSetupPlan(items: [
            ToolSetupPlanItem(
                toolID: "yt-dlp", name: "yt-dlp", action: .install, installer: .standalone,
                destination: "\(toolsDir)/yt-dlp", currentPath: nil, currentVersion: nil,
                sourceHost: "github.com/yt-dlp", brewPackage: "yt-dlp"),
            ToolSetupPlanItem(
                toolID: "ffmpeg", name: "ffmpeg", action: .update, installer: .homebrew,
                destination: "/opt/homebrew/bin/ffmpeg",
                currentPath: "/opt/homebrew/bin/ffmpeg", currentVersion: "6.0",
                sourceHost: nil, brewPackage: "ffmpeg"),
        ])
        let lines = ToolSetupPlanner.confirmationLines(for: plan)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].actionAndInstaller, "Install yt-dlp via standalone download")
        XCTAssertTrue(lines[0].source?.contains("github.com/yt-dlp") ?? false)
        XCTAssertNil(lines[0].replacing)
        XCTAssertEqual(lines[1].actionAndInstaller, "Update ffmpeg via Homebrew")
        XCTAssertEqual(lines[1].replacing, "Current: /opt/homebrew/bin/ffmpeg · 6.0")
        XCTAssertNil(lines[1].source)
        XCTAssertTrue(ToolSetupPlanner.rollbackNotice.contains("restore"))
    }

    func testConfirmationNamesEveryStandaloneHost() {
        for (id, needle) in [
            ("yt-dlp", "github.com/yt-dlp"),
            ("deno", "github.com/denoland"),
            ("ffmpeg", "evermeet.cx"),
            ("gallery-dl", "PyPI"),
        ] {
            XCTAssertTrue(
                ToolSetupPlanner.sourceDescription(for: id).contains(needle), id)
        }
        XCTAssertTrue(
            ToolSetupPlanner.sourceDescription(for: "gallery-dl").contains("github.com/astral-sh"))
    }
}
