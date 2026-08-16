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
            versionLineProvider: { _ in
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
            versionLineProvider: { _ in
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
            versionLineProvider: { path in
                if path.hasSuffix("yt-dlp") { return "2024.11.04" }
                if path.hasSuffix("gallery-dl") { return "1.32.9" }
                return "ffmpeg version 9.0.1 Copyright (c) 2000-2025 the FFmpeg developers"
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
            versionLineProvider: { _ in
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
            resolvedPath: { $0.id == "deno" ? "/fresh/deno" : "/x/\($0.id)" })
        XCTAssertTrue(plan.missing.isEmpty)
        XCTAssertEqual(plan.broken.map(\.id), ["yt-dlp"])
        XCTAssertEqual(plan.outdated.map(\.id), ["ffmpeg"])
    }

    func testRepairPlanKeepsStillMissingTools() {
        let plan = ToolHealthMonitor.repairPlan(
            problems: [problemHealth("deno", .missing)],
            resolvedPath: { _ in nil })
        XCTAssertEqual(plan.missing.map(\.id), ["deno"])
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
}
