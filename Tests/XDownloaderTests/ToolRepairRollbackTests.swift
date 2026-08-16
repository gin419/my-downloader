import XCTest

@testable import XDownloader

/// Transactional standalone install: dest is untouched until verify, a failed
/// run restores every snapshotted tool, and success leaves no staging files.
final class ToolRepairRollbackTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    private func dest(_ id: String) -> URL {
        tempDir.appendingPathComponent(id)
    }

    private func write(_ url: URL, _ body: String, executable: Bool = true) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func planItem(
        _ id: String, action: ToolSetupAction = .install, current: String? = nil
    ) -> ToolSetupPlanItem {
        ToolSetupPlanItem(
            toolID: id, name: id, action: action, installer: .standalone,
            destination: dest(id).path, currentPath: current, currentVersion: nil,
            sourceHost: ToolSetupPlanner.sourceHost(for: id), brewPackage: id)
    }

    private func runner(
        download: @escaping (URL, URL) async throws -> Void,
        verify: @escaping (String, [String]) async -> Bool = { _, _ in true },
        extractZip: @escaping (URL, URL) throws -> Void = { _, _ in },
        extractTarGz: @escaping (URL, URL) throws -> Void = { _, _ in },
        runProcess: @escaping (String, [String], [String: String]?) async -> Int32 = { _, _, _ in 0 },
        resolvePython3: @escaping () async -> String? = { "/usr/bin/python3" },
        runBrew:
            @escaping (
                [ToolRequirement], [ToolRequirement], [ToolRequirement],
                @escaping @MainActor @Sendable (String) -> Void
            ) async -> Int32 = { _, _, _, _ in 0 }
    ) -> ToolRepairRunner {
        ToolRepairRunner(
            seams: ToolRepairRunner.Seams(
                fileManager: fm,
                toolsDirectory: tempDir,
                architecture: { "arm64" },
                brewPath: { nil },
                download: download,
                extractZip: extractZip,
                extractTarGz: extractTarGz,
                verify: verify,
                runProcess: runProcess,
                resolvePython3: resolvePython3,
                runBrew: runBrew))
    }

    private func contents(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func testFailedDownloadLeavesExistingDestUnchanged() async throws {
        let target = dest("yt-dlp")
        try write(target, "OLD")
        let repair = runner(download: { _, _ in throw ToolRepairError.downloadFailed })
        let result = await repair.run(
            plan: ToolSetupPlan(items: [planItem("yt-dlp", action: .update, current: target.path)]),
            onLine: { _ in })
        XCTAssertTrue(result.rolledBack)
        XCTAssertEqual(contents(target), "OLD")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("partial").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("pre-repair").path))
    }

    func testFailedDownloadWhenAbsentLeavesAbsent() async {
        let target = dest("yt-dlp")
        let repair = runner(download: { _, _ in throw ToolRepairError.downloadFailed })
        let result = await repair.run(
            plan: ToolSetupPlan(items: [planItem("yt-dlp")]),
            onLine: { _ in })
        XCTAssertTrue(result.rolledBack)
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("partial").path))
    }

    func testVerifyFailAfterDownloadRestoresDestAndRemovesPartial() async throws {
        let target = dest("yt-dlp")
        try write(target, "OLD")
        let repair = runner(
            download: { _, dest in
                try "NEW".write(to: dest, atomically: true, encoding: .utf8)
            },
            verify: { _, _ in false })
        let result = await repair.run(
            plan: ToolSetupPlan(items: [planItem("yt-dlp", action: .update, current: target.path)]),
            onLine: { _ in })
        XCTAssertTrue(result.rolledBack)
        XCTAssertEqual(contents(target), "OLD")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("partial").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("pre-repair").path))
    }

    func testSecondToolFailRestoresFirstToPreRunBytes() async throws {
        let first = dest("yt-dlp")
        let second = dest("deno")
        try write(first, "OLD-YT")
        try write(second, "OLD-DENO")
        var downloads = 0
        let repair = runner(
            download: { _, dest in
                downloads += 1
                if dest.path.contains("deno") { throw ToolRepairError.downloadFailed }
                try "NEW-YT".write(to: dest, atomically: true, encoding: .utf8)
            },
            extractZip: { _, dir in
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try "NEW-DENO".write(
                    to: dir.appendingPathComponent("deno"), atomically: true, encoding: .utf8)
            })
        let result = await repair.run(
            plan: ToolSetupPlan(items: [
                planItem("yt-dlp", action: .update, current: first.path),
                planItem("deno", action: .update, current: second.path),
            ]),
            onLine: { _ in })
        XCTAssertTrue(result.rolledBack)
        XCTAssertGreaterThanOrEqual(downloads, 1)
        XCTAssertEqual(contents(first), "OLD-YT")
        XCTAssertEqual(contents(second), "OLD-DENO")
        XCTAssertFalse(fm.fileExists(atPath: first.appendingPathExtension("partial").path))
        XCTAssertFalse(fm.fileExists(atPath: first.appendingPathExtension("pre-repair").path))
        XCTAssertFalse(fm.fileExists(atPath: second.appendingPathExtension("partial").path))
        XCTAssertFalse(fm.fileExists(atPath: second.appendingPathExtension("pre-repair").path))
    }

    func testSuccessLeavesNoStagingFiles() async throws {
        let target = dest("yt-dlp")
        try write(target, "OLD")
        let repair = runner(download: { _, dest in
            try "NEW".write(to: dest, atomically: true, encoding: .utf8)
        })
        let result = await repair.run(
            plan: ToolSetupPlan(items: [planItem("yt-dlp", action: .update, current: target.path)]),
            onLine: { _ in })
        XCTAssertFalse(result.rolledBack)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(contents(target), "NEW")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("partial").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("pre-repair").path))
    }

    func testBrewFailureRollsBackSuccessfulStandalone() async throws {
        let target = dest("yt-dlp")
        try write(target, "OLD")
        let repair = runner(
            download: { _, dest in
                try "NEW".write(to: dest, atomically: true, encoding: .utf8)
            },
            runBrew: { _, _, _, _ in 1 })
        let brewItem = ToolSetupPlanItem(
            toolID: "ffmpeg", name: "ffmpeg", action: .update, installer: .homebrew,
            destination: dest("ffmpeg").path, currentPath: dest("ffmpeg").path,
            currentVersion: "6.0", sourceHost: nil, brewPackage: "ffmpeg")
        try write(dest("ffmpeg"), "BREW-OLD")
        let result = await repair.run(
            plan: ToolSetupPlan(items: [
                planItem("yt-dlp", action: .update, current: target.path),
                brewItem,
            ]),
            onLine: { _ in })
        XCTAssertTrue(result.rolledBack)
        XCTAssertEqual(contents(target), "OLD")
        XCTAssertEqual(contents(dest("ffmpeg")), "BREW-OLD")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("pre-repair").path))
    }

    func testGalleryDlPipFailLeavesWrapperUnchanged() async throws {
        let wrapper = dest("gallery-dl")
        try write(wrapper, "OLD-WRAPPER")
        let repair = runner(
            download: { _, _ in
                XCTFail("pip fail must not download"); throw ToolRepairError.downloadFailed
            },
            runProcess: { _, _, _ in 1 },
            resolvePython3: { "/usr/bin/python3" })
        let result = await repair.run(
            plan: ToolSetupPlan(items: [planItem("gallery-dl", action: .update, current: wrapper.path)]),
            onLine: { _ in })
        XCTAssertTrue(result.rolledBack)
        XCTAssertEqual(contents(wrapper), "OLD-WRAPPER")
        XCTAssertFalse(fm.fileExists(atPath: dest("gallery-dl-pkg").path))
        XCTAssertFalse(fm.fileExists(atPath: dest("gallery-dl-pkg.partial").path))
        XCTAssertFalse(fm.fileExists(atPath: wrapper.appendingPathExtension("partial").path))
    }

    func testDownloadWritesOnlyToPartialNotDest() async throws {
        let target = dest("yt-dlp")
        try write(target, "OLD")
        var downloadDests: [String] = []
        let repair = runner(download: { _, dest in
            downloadDests.append(dest.path)
            XCTAssertTrue(dest.path.hasSuffix(".partial"), dest.path)
            XCTAssertNotEqual(dest.path, target.path)
            try "NEW".write(to: dest, atomically: true, encoding: .utf8)
        })
        _ = await repair.run(
            plan: ToolSetupPlan(items: [planItem("yt-dlp", action: .update, current: target.path)]),
            onLine: { _ in })
        XCTAssertEqual(downloadDests.count, 1)
        XCTAssertEqual(contents(target), "NEW")
    }
}
