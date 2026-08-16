import XCTest

@testable import XDownloader

/// The probe's view-model wiring: init seeds from existence alone (no process
/// spawns), and one probe pass derives every tool's status from the injected
/// providers — including asking brew only about tools that exist.
@MainActor
final class ToolHealthMonitorTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testInitSeedsFromExistenceWithoutProbing() {
        let monitor = ToolHealthMonitor(
            pathResolver: { $0.id == "deno" ? nil : "/probe/\($0.id)" },
            versionLineProvider: { _, _ in
                XCTFail("init must not spawn --version probes")
                return nil
            },
            brewOutdatedProvider: { _ in
                XCTFail("init must not run brew")
                return []
            },
            now: { self.date(2026, 8, 16) })

        XCTAssertEqual(monitor.health(for: "deno")?.status, .missing)
        XCTAssertEqual(monitor.health(for: "yt-dlp")?.status, .ok(version: "unknown"))
        XCTAssertEqual(monitor.health(for: "yt-dlp")?.path, "/probe/yt-dlp")
    }

    func testRefreshIfStaleIsInertBeforeActivation() {
        // DownloadManager's init drains the queue, which calls refreshIfStale —
        // headless constructions (unit tests, previews) must stay quiet.
        let monitor = ToolHealthMonitor(
            pathResolver: { _ in "/probe/tool" },
            versionLineProvider: { _, _ in
                XCTFail("refreshIfStale must not probe before activate()")
                return nil
            },
            brewOutdatedProvider: { _ in
                XCTFail("refreshIfStale must not run brew before activate()")
                return []
            },
            now: { self.date(2026, 8, 16) })

        monitor.refreshIfStale()
    }

    func testProbeDerivesStatusesFromInjectedProviders() async {
        let monitor = ToolHealthMonitor(
            pathResolver: { $0.id == "deno" ? nil : "/probe/\($0.id)" },
            versionLineProvider: { path, arguments in
                // The real ffmpeg REJECTS --version; a probe that asks with
                // the wrong flag must fail here like it fails in production.
                if path.hasSuffix("ffmpeg") {
                    guard arguments == ["-version"] else {
                        XCTFail("ffmpeg probed with \(arguments) — it only accepts -version")
                        return nil
                    }
                    return "ffmpeg version 9.0.1 Copyright (c) 2000-2025 the FFmpeg developers"
                }
                guard arguments == ["--version"] else {
                    XCTFail("\(path) probed with \(arguments)")
                    return nil
                }
                if path.hasSuffix("yt-dlp") { return "2024.11.04" }
                if path.hasSuffix("gallery-dl") { return "1.32.9" }
                return nil
            },
            brewOutdatedProvider: { installedPackages in
                // Missing tools must not be asked about — brew errors on names
                // it does not manage.
                XCTAssertFalse(installedPackages.contains("deno"))
                return ["gallery-dl"]
            },
            now: { self.date(2026, 8, 16) })

        await monitor.performProbe()

        XCTAssertEqual(
            monitor.health(for: "yt-dlp")?.status,
            .outdated(installed: "2024.11.04", detail: "21 months old"))
        XCTAssertEqual(
            monitor.health(for: "gallery-dl")?.status,
            .outdated(installed: "1.32.9", detail: nil))
        XCTAssertEqual(monitor.health(for: "ffmpeg")?.status, .ok(version: "9.0.1"))
        XCTAssertEqual(monitor.health(for: "deno")?.status, .missing)

        // The banner's input: missing first, then outdated in catalogue order.
        XCTAssertEqual(monitor.problems.map(\.id), ["deno", "yt-dlp", "gallery-dl"])
    }

    // MARK: - Forced refresh is never dropped

    private final class Counter {
        var value = 0
    }

    func testForcedRefreshDuringInFlightProbeRunsAFollowUp() async {
        // A post-repair refresh(force:) that lands while a cadence probe is
        // in flight must queue exactly ONE follow-up probe — dropping it
        // would leave the sheet judging pre-repair statuses.
        let probes = Counter()
        let monitor = ToolHealthMonitor(
            pathResolver: { _ in "/probe/tool" },
            versionLineProvider: { _, _ in
                probes.value += 1
                return "2026.08.01"
            },
            brewOutdatedProvider: { _ in [] },
            now: { self.date(2026, 8, 16) })

        monitor.refresh(force: true)  // launches probe 1 (its Task has not run yet)
        monitor.refresh(force: true)  // in flight → queues the follow-up
        monitor.refresh(force: true)  // still queued → must NOT queue a third
        await monitor.awaitProbesSettled()

        // 4 catalogue tools × exactly 2 probe passes.
        XCTAssertEqual(probes.value, 8)
    }

    // MARK: - Click-time repair plan

    private func problemHealth(_ id: String, _ status: ToolStatus) -> ToolHealth {
        ToolHealth(
            id: id, name: id, brewPackage: id, docsURL: "",
            path: status == .missing ? nil : "/x/\(id)", status: status)
    }

    func testRepairPlanDropsMissingToolsThatAppearedOnDisk() {
        // A pipx install done in Terminal seconds earlier must not trigger a
        // duplicate brew install: the click-time re-resolve drops it.
        let problems = [
            problemHealth("deno", .missing),
            problemHealth("yt-dlp", .broken(detail: "can't run")),
            problemHealth("ffmpeg", .outdated(installed: "9.0.1", detail: nil)),
        ]
        let plan = ToolHealthMonitor.repairPlan(
            problems: problems,
            resolvedPath: { $0.id == "deno" ? "/fresh/deno" : "/opt/homebrew/bin/\($0.id)" })
        XCTAssertTrue(plan.missing.isEmpty)
        XCTAssertEqual(plan.broken.map(\.id), ["yt-dlp"])
        XCTAssertEqual(plan.outdated.map(\.id), ["ffmpeg"])
        XCTAssertTrue(plan.unmanaged.isEmpty)
    }

    func testRepairPlanKeepsStillMissingTools() {
        let plan = ToolHealthMonitor.repairPlan(
            problems: [problemHealth("deno", .missing)],
            resolvedPath: { _ in nil })
        XCTAssertEqual(plan.missing.map(\.id), ["deno"])
    }

    /// A broken/outdated tool resolved OUTSIDE a Homebrew prefix (pipx,
    /// MacPorts, manual) must not get a doomed brew step — brew only touches
    /// its own cellar, so the run would "succeed" while the resolved binary
    /// stays broken. Missing tools keep brew install: there is no competing
    /// binary to shadow it.
    func testRepairPlanRoutesNonBrewInstallsToUnmanaged() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let problems = [
            problemHealth("gallery-dl", .broken(detail: "can't run")),
            problemHealth("yt-dlp", .outdated(installed: "2024.11.04", detail: nil)),
            problemHealth("deno", .missing),
        ]
        let plan = ToolHealthMonitor.repairPlan(
            problems: problems,
            resolvedPath: { tool in
                switch tool.id {
                case "gallery-dl": return "\(home)/.local/bin/gallery-dl"
                case "yt-dlp": return "/opt/local/bin/yt-dlp"
                default: return nil
                }
            })
        XCTAssertEqual(plan.missing.map(\.id), ["deno"])
        XCTAssertTrue(plan.broken.isEmpty)
        XCTAssertTrue(plan.outdated.isEmpty)
        XCTAssertEqual(plan.unmanaged.map(\.id), ["gallery-dl", "yt-dlp"])
    }

    func testBrewPrefixDetection() {
        XCTAssertTrue(RequirementsService.isBrewManagedPath("/opt/homebrew/bin/gallery-dl"))
        XCTAssertTrue(RequirementsService.isBrewManagedPath("/usr/local/bin/ffmpeg"))
        XCTAssertFalse(RequirementsService.isBrewManagedPath("/opt/local/bin/yt-dlp"))
        XCTAssertFalse(
            RequirementsService.isBrewManagedPath(
                FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/gallery-dl"))
    }

    // MARK: - repairState returns to .idle (stale verdicts)

    /// A finished repair's verdict describes the problem set it was judged
    /// against; when a probe derives a DIFFERENT set, the stale "All done"
    /// must stop rendering — the state returns to .idle.
    func testProbeWithChangedProblemSetResetsDoneToIdle() async {
        var broken = false
        let monitor = ToolHealthMonitor(
            pathResolver: { _ in "/opt/homebrew/bin/tool" },
            versionLineProvider: { _, _ in broken ? nil : "2026.08.01" },
            brewOutdatedProvider: { _ in [] },
            now: { self.date(2026, 8, 16) })
        await monitor.performProbe()
        monitor.plantRepairOutcomeForTesting(.success, judgedAgainst: monitor.problems)

        // Same problem set (none) → the verdict may keep rendering.
        await monitor.performProbe()
        XCTAssertEqual(monitor.repairState, .done(.success))

        // Every tool turns broken → new problem set → back to .idle.
        broken = true
        await monitor.performProbe()
        XCTAssertEqual(monitor.repairState, .idle)
    }

    /// startRepair with an empty brew plan (nothing brew can act on) must
    /// clear a stale verdict instead of leaving it rendered against the
    /// current problems.
    func testStartRepairWithEmptyPlanResetsToIdle() async {
        let monitor = ToolHealthMonitor(
            pathResolver: { _ in "/opt/homebrew/bin/tool" },
            versionLineProvider: { _, _ in "2026.08.01" },
            brewOutdatedProvider: { _ in [] },
            now: { self.date(2026, 8, 16) })
        await monitor.performProbe()
        XCTAssertTrue(monitor.problems.isEmpty)
        monitor.plantRepairOutcomeForTesting(.success, judgedAgainst: monitor.problems)

        monitor.startRepair()

        XCTAssertEqual(monitor.repairState, .idle, "an empty plan must not leave a stale verdict")
    }

    // MARK: - Live probe (fake tools on disk)

    private func makeFakeTool(_ script: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-tool")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testProbeTakesFirstStdoutLineIgnoringStderrNoise() async throws {
        // Python deprecation warnings arrive on stderr BEFORE the version —
        // they must never become the "version".
        let tool = try makeFakeTool(
            "#!/bin/sh\necho 'DeprecationWarning: urllib3 v2 only supports OpenSSL' >&2\necho '1.32.9'\n")
        let line = await ToolHealthMonitor.probeVersionLine(executablePath: tool, timeout: 10)
        XCTAssertEqual(line, "1.32.9")
    }

    func testProbeNonZeroExitYieldsNil() async throws {
        // A crashing tool must derive broken, never a parsed "version".
        let tool = try makeFakeTool("#!/bin/sh\necho '9.9.9'\nexit 3\n")
        let line = await ToolHealthMonitor.probeVersionLine(executablePath: tool, timeout: 10)
        XCTAssertNil(line)
    }

    func testProbeMissingBinaryYieldsNil() async {
        let line = await ToolHealthMonitor.probeVersionLine(
            executablePath: "/nonexistent/fake-tool-\(UUID().uuidString)", timeout: 10)
        XCTAssertNil(line)
    }

    func testProbeTimeoutKillsAHungBinary() async throws {
        // A hung `--version` must never wedge tool health for the session.
        let tool = try makeFakeTool("#!/bin/sh\nsleep 30\n")
        let started = Date()
        let line = await ToolHealthMonitor.probeVersionLine(executablePath: tool, timeout: 1)
        XCTAssertNil(line)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the deadline must cut the wait")
    }

    // MARK: - ffmpeg's argv (per-tool version arguments)

    /// The catalogue must give ffmpeg `-version` — it REJECTS the GNU-style
    /// flag every other tool takes.
    func testCatalogueVersionArguments() {
        XCTAssertEqual(RequirementsService.ffmpeg.versionArguments, ["-version"])
        XCTAssertEqual(RequirementsService.ytdlp.versionArguments, ["--version"])
        XCTAssertEqual(RequirementsService.galleryDl.versionArguments, ["--version"])
        XCTAssertEqual(RequirementsService.deno.versionArguments, ["--version"])
    }

    /// Faithful fake of the real ffmpeg's argv behavior: `--version` exits 8
    /// with an error on stderr and NOTHING on stdout; `-version` prints the
    /// banner on stdout and exits 0. (Verified against ffmpeg 9.0.1.)
    private func makeFakeFfmpeg() throws -> String {
        try makeFakeTool(
            """
            #!/bin/sh
            if [ "$1" = "-version" ]; then
              echo 'ffmpeg version 9.0.1 Copyright (c) 2000-2025 the FFmpeg developers'
              exit 0
            fi
            echo "Unrecognized option '$1'." >&2
            exit 8
            """)
    }

    /// The pre-fix probe argv made every healthy ffmpeg derive `.broken`
    /// (red banner + futile reinstall loop). The fake rejects the wrong flag
    /// like the real tool, so this class of bug cannot pass tests again.
    func testFfmpegProbeSucceedsWithSingleDashVersionOnly() async throws {
        let ffmpeg = try makeFakeFfmpeg()

        let banner = await ToolHealthMonitor.probeVersionLine(
            executablePath: ffmpeg, arguments: ["-version"], timeout: 10)
        XCTAssertEqual(
            banner, "ffmpeg version 9.0.1 Copyright (c) 2000-2025 the FFmpeg developers")
        XCTAssertEqual(RequirementsService.parsedVersion(fromFirstLine: banner ?? ""), "9.0.1")

        let wrongFlag = await ToolHealthMonitor.probeVersionLine(
            executablePath: ffmpeg, arguments: ["--version"], timeout: 10)
        XCTAssertNil(wrongFlag, "the real ffmpeg rejects --version — the fake must too")
    }

    /// End-to-end through the monitor's default probe path: a healthy
    /// argv-sensitive ffmpeg derives .ok because the catalogue supplies
    /// `-version`.
    func testMonitorProbesFfmpegWithItsCatalogueArguments() async throws {
        let ffmpeg = try makeFakeFfmpeg()
        let monitor = ToolHealthMonitor(
            tools: [RequirementsService.ffmpeg],
            pathResolver: { _ in ffmpeg },
            brewOutdatedProvider: { _ in [] },
            now: { self.date(2026, 8, 16) })

        await monitor.performProbe()

        XCTAssertEqual(monitor.health(for: "ffmpeg")?.status, .ok(version: "9.0.1"))
    }
}
