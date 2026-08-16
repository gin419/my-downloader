import XCTest

@testable import XDownloader

/// The post-video image sweep's per-item failures stay deliberately silent
/// (video-only posts are the normal case) — but a SYSTEMATICALLY broken
/// gallery-dl fails every sweep and silently loses all photos from mixed
/// posts under green "Done" rows. The manager counts CONSECUTIVE non-zero
/// sweep exits and surfaces a once-per-session persistent notice at the
/// threshold; any clean exit resets the count.
@MainActor
final class ImageSweepFeedbackTests: XCTestCase {

    private func makeManager() -> DownloadManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!
        return DownloadManager(
            history: HistoryStore(directory: dir),
            queueStore: QueueStore(directory: dir),
            settingsStore: SettingsStore(defaults: defaults),
            likesSyncStore: LikesSyncStore(directory: dir),
            galleryDlPathProvider: { nil })
    }

    func testNoticeAppearsAtThreeConsecutiveFailures() {
        let manager = makeManager()
        for _ in 0..<(DownloadManager.imageSweepFailureThreshold - 1) {
            manager.recordImageSweepOutcome(exitedCleanly: false)
        }
        XCTAssertNil(manager.captureFeedback, "below the threshold nothing may surface")

        manager.recordImageSweepOutcome(exitedCleanly: false)

        XCTAssertEqual(manager.captureFeedback?.message, DownloadManager.imageSweepBrokenFeedbackMessage)
        XCTAssertEqual(manager.captureFeedback?.kind, .warning)
        XCTAssertEqual(manager.captureFeedback?.isPersistent, true)
    }

    func testCleanExitResetsTheCounter() {
        // A sweep that exits 0 — files found or not — proves gallery-dl still
        // works; only an unbroken run of failures may raise the notice.
        let manager = makeManager()
        manager.recordImageSweepOutcome(exitedCleanly: false)
        manager.recordImageSweepOutcome(exitedCleanly: false)
        manager.recordImageSweepOutcome(exitedCleanly: true)
        manager.recordImageSweepOutcome(exitedCleanly: false)
        manager.recordImageSweepOutcome(exitedCleanly: false)
        XCTAssertNil(manager.captureFeedback)

        manager.recordImageSweepOutcome(exitedCleanly: false)
        XCTAssertEqual(manager.captureFeedback?.message, DownloadManager.imageSweepBrokenFeedbackMessage)
    }

    func testNoticeShowsOncePerSession() {
        // Same pattern as the cookie-access notice: repeating it every mixed
        // post would drown the status line the user already read.
        let manager = makeManager()
        for _ in 0..<DownloadManager.imageSweepFailureThreshold {
            manager.recordImageSweepOutcome(exitedCleanly: false)
        }
        XCTAssertNotNil(manager.captureFeedback)

        manager.captureFeedback = nil
        for _ in 0..<DownloadManager.imageSweepFailureThreshold {
            manager.recordImageSweepOutcome(exitedCleanly: false)
        }
        XCTAssertNil(manager.captureFeedback, "the notice must not re-surface within one session")
    }

    func testCleanExitsAloneNeverSurfaceAnything() {
        let manager = makeManager()
        for _ in 0..<10 { manager.recordImageSweepOutcome(exitedCleanly: true) }
        XCTAssertNil(manager.captureFeedback)
    }
}

/// The sweep must REPORT its exit result so the manager can count systematic
/// failures — a fake gallery-dl (a /tmp shell script) stands in for the tool.
@MainActor
final class ImageSweepExitResultTests: XCTestCase {

    private func makeScript(exitCode: Int32) throws -> (script: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake-gallery-dl")
        try "#!/bin/sh\nexit \(exitCode)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, dir)
    }

    func testSweepReportsCleanExit() async throws {
        let (script, dir) = try makeScript(exitCode: 0)
        let item = DownloadItem(url: "https://x.com/a/status/123")
        let result = await GalleryDlService.runImageSweep(
            item: item, executablePath: script, outputDirectory: dir,
            cookieBrowser: .none, register: { _ in }, unregister: {})

        XCTAssertEqual(result?.isSuccess, true)
    }

    func testSweepReportsNonZeroExit() async throws {
        let (script, dir) = try makeScript(exitCode: 4)
        let item = DownloadItem(url: "https://x.com/a/status/123")
        let result = await GalleryDlService.runImageSweep(
            item: item, executablePath: script, outputDirectory: dir,
            cookieBrowser: .none, register: { _ in }, unregister: {})

        XCTAssertEqual(result?.isSuccess, false)

        XCTAssertEqual(item.status, .queued, "the sweep must never touch the item's status")
    }

    func testProfilesWithoutASweepReportNothing() async throws {
        let (script, dir) = try makeScript(exitCode: 0)
        let item = DownloadItem(url: "https://www.youtube.com/watch?v=abcdefghijk")
        let result = await GalleryDlService.runImageSweep(
            item: item, executablePath: script, outputDirectory: dir,
            cookieBrowser: .none, register: { _ in }, unregister: {})

        XCTAssertNil(result, "no sweep ran, so there is no exit to count")
    }
}
