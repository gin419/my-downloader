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
}
