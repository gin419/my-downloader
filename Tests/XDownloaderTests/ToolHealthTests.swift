import XCTest

@testable import XDownloader

/// The Honest Toolbox probe: existence alone is not health. The origin
/// incident was a manually-installed yt-dlp from 2024 that passed the
/// existence-only check for months while every YouTube download failed with
/// misleading errors. These tests pin the version parsing, the CalVer age
/// math (injected "now"), the probe-result → ToolStatus derivation, and the
/// unified path resolver the banner shares with the launch paths.
final class ToolHealthTests: XCTestCase {

    /// Deterministic UTC dates — the implementation must use a fixed
    /// gregorian/UTC calendar, never the user's locale.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func health(_ id: String, _ status: ToolStatus) -> ToolHealth {
        ToolHealth(
            id: id, name: id, brewPackage: id, docsURL: "",
            path: status == .missing ? nil : "/opt/homebrew/bin/\(id)",
            status: status)
    }

    private func derive(
        _ toolID: String,
        path: String?,
        versionLine: String?,
        brewOutdated: Set<String> = [],
        now: Date
    ) -> ToolStatus {
        RequirementsService.deriveStatus(
            toolID: toolID,
            brewPackage: toolID,
            installedPath: path,
            versionLine: versionLine,
            brewOutdated: brewOutdated,
            now: now)
    }

    // MARK: - Catalogue: deno is a first-class tool

    func testDenoIsAFirstClassCatalogueTool() {
        let deno = RequirementsService.tool(withID: "deno")
        XCTAssertNotNil(deno)
        XCTAssertEqual(deno?.brewPackage, "deno")
        XCTAssertEqual(deno?.docsURL, "https://docs.deno.com/runtime/")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(deno?.searchPaths.first, "/opt/homebrew/bin/deno")
        XCTAssertTrue(deno?.searchPaths.contains("/usr/local/bin/deno") ?? false)
        XCTAssertTrue(deno?.searchPaths.contains("\(home)/.deno/bin/deno") ?? false)
        XCTAssertTrue(RequirementsService.all.contains { $0.id == "deno" })
    }

    func testEveryToolSearchesPipxAndMacPortsLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for tool in RequirementsService.all {
            XCTAssertTrue(
                tool.searchPaths.contains("\(home)/.local/bin/\(tool.id)"),
                "\(tool.id) does not search the pipx location")
            XCTAssertTrue(
                tool.searchPaths.contains("/opt/local/bin/\(tool.id)"),
                "\(tool.id) does not search the MacPorts location")
        }
    }

    func testAppManagedPathIsLastSearchPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for tool in RequirementsService.all {
            XCTAssertEqual(
                tool.searchPaths.last,
                AppPaths.appManagedToolPath(tool.id, home: home),
                "\(tool.id) must search the app-managed dir last so brew/pipx still win")
        }
    }

    func testIsAppManagedPath() {
        let dest = AppPaths.appManagedToolPath("yt-dlp")
        XCTAssertTrue(RequirementsService.isAppManagedPath(dest))
        XCTAssertTrue(
            RequirementsService.isAppManagedPath(AppPaths.galleryDlPackageDirectory()))
        XCTAssertFalse(RequirementsService.isAppManagedPath("/opt/homebrew/bin/yt-dlp"))
        XCTAssertFalse(
            RequirementsService.isAppManagedPath(
                FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/yt-dlp"))
    }

    // MARK: - Unified path resolver

    func testResolverFirstExistingSearchPathWins() {
        let tool = ToolRequirement(
            id: "t", name: "t", brewPackage: "t", docsURL: "",
            searchPaths: ["/a/t", "/b/t", "/c/t"])
        let resolved = RequirementsService.resolvedPath(for: tool) { ["/b/t", "/c/t"].contains($0) }
        XCTAssertEqual(resolved, "/b/t")
    }

    func testResolverReturnsNilWhenNoSearchPathExists() {
        let tool = ToolRequirement(
            id: "t", name: "t", brewPackage: "t", docsURL: "",
            searchPaths: ["/a/t", "/b/t"])
        XCTAssertNil(RequirementsService.resolvedPath(for: tool) { _ in false })
    }

    // MARK: - Version parsing (verbatim `--version` first lines)

    func testParsesYtDlpCalVerFirstLine() {
        XCTAssertEqual(RequirementsService.parsedVersion(fromFirstLine: "2026.07.04"), "2026.07.04")
    }

    func testParsesGalleryDlSemverFirstLine() {
        XCTAssertEqual(RequirementsService.parsedVersion(fromFirstLine: "1.32.9"), "1.32.9")
    }

    func testParsesFfmpegBannerFirstLine() {
        XCTAssertEqual(
            RequirementsService.parsedVersion(
                fromFirstLine: "ffmpeg version 9.0.1 Copyright (c) 2000-2025 the FFmpeg developers"),
            "9.0.1")
    }

    func testParsesDenoFirstLine() {
        XCTAssertEqual(
            RequirementsService.parsedVersion(fromFirstLine: "deno 2.4.2 (stable, release, x86_64-apple-darwin)"),
            "2.4.2")
    }

    func testCopyrightYearRangeIsNotAVersion() {
        // "2000-2025" contains digits but no dotted version — must not match.
        XCTAssertNil(RequirementsService.parsedVersion(fromFirstLine: "Copyright (c) 2000-2025 the FFmpeg developers"))
    }

    func testShellNoiseYieldsNoVersion() {
        XCTAssertNil(RequirementsService.parsedVersion(fromFirstLine: "zsh: command not found: yt-dlp"))
    }

    // MARK: - CalVer age math (injected now)

    func testCalVerDateParsesYtDlpVersions() {
        XCTAssertEqual(RequirementsService.calVerDate("2026.07.04"), date(2026, 7, 4))
    }

    func testCalVerDateAcceptsFourPartNightly() {
        // Nightly builds append a timestamp part — the first three parts are
        // still the build date.
        XCTAssertEqual(RequirementsService.calVerDate("2024.11.04.232815"), date(2024, 11, 4))
    }

    func testCalVerDateRejectsSemver() {
        // gallery-dl is SEMVER — age is NOT derivable from "1.32.9".
        XCTAssertNil(RequirementsService.calVerDate("1.32.9"))
        XCTAssertNil(RequirementsService.calVerDate("1.2.3.4"))
    }

    func testHumanizedAgeInMonths() {
        XCTAssertEqual(
            RequirementsService.humanizedAge(from: date(2024, 11, 4), now: date(2026, 8, 16)),
            "21 months old")
    }

    func testHumanizedAgeInDays() {
        XCTAssertEqual(
            RequirementsService.humanizedAge(from: date(2026, 7, 2), now: date(2026, 8, 16)),
            "45 days old")
    }

    func testHumanizedAgeClampsAtZero() {
        // A build date in the future (clock skew) must never read negative.
        XCTAssertEqual(
            RequirementsService.humanizedAge(from: date(2026, 8, 20), now: date(2026, 8, 16)),
            "0 days old")
    }

    // MARK: - Status derivation (probe result × brew-outdated list)

    func testNoPathIsMissingRegardlessOfOtherEvidence() {
        XCTAssertEqual(
            derive("yt-dlp", path: nil, versionLine: "2026.07.04", brewOutdated: ["yt-dlp"], now: date(2026, 8, 16)),
            .missing)
    }

    func testFreshYtDlpIsOK() {
        XCTAssertEqual(
            derive("yt-dlp", path: "/usr/local/bin/yt-dlp", versionLine: "2026.07.04", now: date(2026, 8, 16)),
            .ok(version: "2026.07.04"))
    }

    func testYtDlpEightyNineDaysOldIsStillOK() {
        XCTAssertEqual(
            derive("yt-dlp", path: "/usr/local/bin/yt-dlp", versionLine: "2026.05.19", now: date(2026, 8, 16)),
            .ok(version: "2026.05.19"))
    }

    func testYtDlpNinetyOneDaysOldIsOutdated() {
        XCTAssertEqual(
            derive("yt-dlp", path: "/usr/local/bin/yt-dlp", versionLine: "2026.05.17", now: date(2026, 8, 16)),
            .outdated(installed: "2026.05.17", detail: "2 months old"))
    }

    func testOriginIncidentYtDlp2024IsOutdatedWithHumanizedAge() {
        // The exact fixture from the approved mockup's State C banner.
        XCTAssertEqual(
            derive("yt-dlp", path: "/usr/local/bin/yt-dlp", versionLine: "2024.11.04", now: date(2026, 8, 16)),
            .outdated(installed: "2024.11.04", detail: "21 months old"))
    }

    func testBrewOutdatedFlagsSemverToolWithoutAge() {
        XCTAssertEqual(
            derive(
                "ffmpeg", path: "/opt/homebrew/bin/ffmpeg",
                versionLine: "ffmpeg version 9.0.1 Copyright (c) 2000-2025 the FFmpeg developers",
                brewOutdated: ["ffmpeg"], now: date(2026, 8, 16)),
            .outdated(installed: "9.0.1", detail: nil))
    }

    func testBrewOutdatedYtDlpKeepsDerivableAge() {
        // Even when the CalVer itself is younger than 90 days, a brew-outdated
        // listing wins — and the age stays on display because it IS derivable.
        XCTAssertEqual(
            derive("yt-dlp", path: "/usr/local/bin/yt-dlp", versionLine: "2026.07.04", brewOutdated: ["yt-dlp"], now: date(2026, 8, 16)),
            .outdated(installed: "2026.07.04", detail: "43 days old"))
    }

    func testGalleryDlHasNoAgeRule() {
        // SEMVER carries no date, so age must never be inferred from it —
        // without a brew-outdated listing the tool is OK whatever its number.
        XCTAssertEqual(
            derive("gallery-dl", path: "/usr/local/bin/gallery-dl", versionLine: "1.32.9", now: date(2026, 8, 16)),
            .ok(version: "1.32.9"))
    }

    func testUnrunnableProbeDerivesBrokenNotOK() {
        // Exec failure, non-zero exit, or a hung probe all surface here as a
        // nil version line — an unrunnable binary must never read as OK.
        XCTAssertEqual(
            derive("ffmpeg", path: "/opt/homebrew/bin/ffmpeg", versionLine: nil, now: date(2026, 8, 16)),
            .broken(detail: "can't run"))
    }

    func testGarbageProbeOutputDerivesBroken() {
        XCTAssertEqual(
            derive("ffmpeg", path: "/opt/homebrew/bin/ffmpeg", versionLine: "usage: tool [options]", now: date(2026, 8, 16)),
            .broken(detail: "can't run"))
    }

    func testBrokenBeatsBrewOutdated() {
        // A binary that can't even run needs a reinstall, not an upgrade.
        XCTAssertEqual(
            derive("ffmpeg", path: "/opt/homebrew/bin/ffmpeg", versionLine: nil, brewOutdated: ["ffmpeg"], now: date(2026, 8, 16)),
            .broken(detail: "can't run"))
    }

    // MARK: - Problem ordering

    func testProblemsOrderMissingThenBrokenThenOutdated() {
        let healths = [
            health("yt-dlp", .outdated(installed: "2024.11.04", detail: "21 months old")),
            health("gallery-dl", .broken(detail: "can't run")),
            health("ffmpeg", .missing),
            health("deno", .missing),
        ]
        let problems = RequirementsService.orderedProblems(healths)
        XCTAssertEqual(problems.map(\.id), ["ffmpeg", "deno", "gallery-dl", "yt-dlp"])
    }

    // MARK: - Child-process PATH truth

    func testLaunchPATHIncludesResolvedToolParentDirs() {
        // The probe certifies tools wherever the resolver finds them; the
        // children must be able to exec those SAME binaries — deduped,
        // order-stable, inherited PATH last.
        XCTAssertEqual(
            Homebrew.launchPATH(
                toolPaths: [
                    "/usr/local/bin/yt-dlp",
                    "/Users/gin/.deno/bin/deno",
                    "/Users/gin/.local/bin/gallery-dl",
                    "/Users/gin/.deno/bin/other",
                ],
                existingPath: "/usr/bin:/bin"),
            "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/Users/gin/.deno/bin:/Users/gin/.local/bin:/usr/bin:/bin"
        )
    }

    func testLaunchPATHFallsBackToSystemDirsWhenEnvEmpty() {
        XCTAssertEqual(Homebrew.launchPATH(toolPaths: [], existingPath: ""), Homebrew.fullPATH)
    }
}
