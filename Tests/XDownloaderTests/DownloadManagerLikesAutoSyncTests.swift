import XCTest

@testable import XDownloader

@MainActor
private final class FakeAutoSyncRunner: LikesSyncProcessRunning {
    struct Run {
        var lines: [String]
        var exitCode: Int32
    }

    private(set) var invocations: [[String]] = []
    var runs: [Run]

    init(runs: [Run]) { self.runs = runs }

    func run(
        executablePath _: String,
        arguments: [String],
        register _: @escaping (Process) -> Void,
        unregister _: @escaping () -> Void,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> ProcessResult {
        invocations.append(arguments)
        let run = runs.removeFirst()
        for line in run.lines {
            onLine(line)
            await Task.yield()
        }
        return ProcessResult(code: run.exitCode, wasSignal: false)
    }
}

/// Stands in for the scheduler's sleep: records each requested delay, lets
/// the first `immediate` ones elapse at once, and holds the rest (until
/// cancelled) so a test sees exactly the checks it allowed.
@MainActor
private final class FakeSleeper {
    private(set) var delays: [TimeInterval] = []
    var immediate: Int

    init(immediate: Int) { self.immediate = immediate }

    func sleep(_ delay: TimeInterval) async throws {
        delays.append(delay)
        if delays.count > immediate {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }
}

@MainActor
final class DownloadManagerLikesAutoSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeManager(
        runs: [FakeAutoSyncRunner.Run], immediateChecks: Int = 1, defaults: UserDefaults? = nil
    ) -> (DownloadManager, FakeAutoSyncRunner, FakeSleeper, LikesSyncStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("likes-auto-\(UUID().uuidString)")
        let defaults = defaults ?? UserDefaults(suiteName: "likes-auto-\(UUID().uuidString)")!
        let runner = FakeAutoSyncRunner(runs: runs)
        let sleeper = FakeSleeper(immediate: immediateChecks)
        let store = LikesSyncStore(directory: directory)
        let fixedNow = now
        let manager = DownloadManager(
            history: HistoryStore(directory: directory),
            queueStore: QueueStore(directory: directory),
            settingsStore: SettingsStore(defaults: defaults),
            likesSyncStore: store,
            likesProcessRunner: runner,
            galleryDlPathProvider: { "/fake/gallery-dl" },
            likesAutoSyncSleeper: { [sleeper] delay in try await sleeper.sleep(delay) },
            likesAutoSyncNow: { fixedNow })
        manager.outputDirectory = directory.appendingPathComponent("downloads")
        manager.twitterHandle = "@gin"
        return (manager, runner, sleeper, store)
    }

    private func enable(_ manager: DownloadManager, interval: LikesAutoSyncInterval = .thirtyMinutes) {
        manager.likesAutoSyncInterval = interval
        manager.likesAutoSyncEnabled = true
        manager.likesAutoSyncSettingsChanged()
    }

    private func disable(_ manager: DownloadManager) {
        manager.likesAutoSyncEnabled = false
        manager.likesAutoSyncSettingsChanged()
    }

    private func waitUntil(_ condition: () -> Bool, _ message: String = "condition not met") async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(message)
    }

    private func waitForLikesRun(_ manager: DownloadManager) async {
        await waitUntil(
            { manager.likesSyncSnapshot.status != .idle && !manager.likesSyncSnapshot.status.isActive },
            "Likes sync did not finish")
    }

    private func event(_ name: String, _ json: String) -> String {
        "likes-sync\t\(name):\(json)"
    }

    private func savedMedia(_ count: Int) -> [String] {
        (0..<count).flatMap { index -> [String] in
            let id = "\(500 + index)"
            return [
                event("post", #"{"tweet_id":"\#(id)","url":"https://x.com/a/status/\#(id)"}"#),
                event("skip", #"{"tweet_id":"\#(id)","media_id":"m\#(id)","extension":"jpg"}"#),
            ]
        }
    }

    // MARK: -

    func testDisabledByDefaultArmsNothing() async {
        let (manager, runner, sleeper, _) = makeManager(runs: [])
        await Task.yield()
        XCTAssertFalse(manager.likesAutoSyncEnabled)
        XCTAssertNil(manager.likesAutoSyncStatus.nextCheckAt)
        XCTAssertTrue(sleeper.delays.isEmpty)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    /// The due check runs an incremental scan (`-A 30`); gallery-dl's abort
    /// is a clean exit 0, which completes the run, and the next check is
    /// armed one interval later.
    func testDueCheckRunsIncrementalScanThenReschedules() async {
        let new = event(
            "after", #"{"tweet_id":"900","media_id":"n1","_path":"/tmp/n1.jpg","extension":"jpg"}"#)
        let (manager, runner, sleeper, _) = makeManager(runs: [
            .init(lines: [event("post", #"{"tweet_id":"900"}"#), new] + savedMedia(30), exitCode: 0)
        ])

        enable(manager)
        await waitUntil({ sleeper.delays.count == 2 }, "next check was not armed")

        XCTAssertEqual(sleeper.delays, [60, 1800])
        XCTAssertEqual(runner.invocations.count, 1)
        let args = runner.invocations[0]
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == "-A" && $1 == "30" })
        XCTAssertEqual(args.last, "https://x.com/gin/likes")
        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.downloaded, 1)
        XCTAssertEqual(manager.likesAutoSyncStatus.lastCheckAt, now)
        XCTAssertEqual(manager.likesAutoSyncStatus.nextCheckAt, now.addingTimeInterval(1800))
        disable(manager)
    }

    func testManualSyncStaysAFullScan() async {
        let (manager, runner, _, _) = makeManager(runs: [.init(lines: savedMedia(1), exitCode: 0)])
        enable(manager)
        manager.startLikesSync()
        await waitForLikesRun(manager)
        XCTAssertFalse(runner.invocations[0].contains("-A"))
        disable(manager)
    }

    /// An incremental run never reaches the end of the Likes, so its clean
    /// finish must not resolve run-level failure rows (only a full scan's
    /// may) — and failures the user already knows about don't re-flag the
    /// menu bar on every automatic check.
    func testIncrementalRunKeepsRunLevelFailuresAndDoesNotReflagOldOnes() async throws {
        let (manager, _, sleeper, store) = makeManager(
            runs: [
                .init(lines: ["[twitter][error] Login required"], exitCode: 1),
                .init(lines: savedMedia(30), exitCode: 0),
            ])
        manager.startLikesSync()
        await waitForLikesRun(manager)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .failed)
        let accountID = try XCTUnwrap(store.account(for: try LikesSyncHandle("@gin"))?.id)
        XCTAssertEqual(store.pendingFailures(accountID: accountID).count, 1)
        manager.markFailuresSeen()
        XCTAssertFalse(manager.menuBarState.showsAttention)

        enable(manager)
        await waitUntil({ sleeper.delays.count == 2 }, "automatic run did not finish")

        XCTAssertEqual(store.pendingFailures(accountID: accountID).count, 1)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .partial)
        XCTAssertFalse(manager.menuBarState.showsAttention)
        disable(manager)
    }

    func testRateLimitedRunDoublesTheNextDelay() async {
        let (manager, _, sleeper, _) = makeManager(runs: [
            .init(lines: ["[twitter][error] 429 Too Many Requests"], exitCode: 1)
        ])
        enable(manager)
        await waitUntil({ sleeper.delays.count == 2 }, "next check was not armed")
        XCTAssertEqual(sleeper.delays, [60, 3600])
        XCTAssertEqual(manager.likesAutoSyncStatus.backoffLevel, 1)
        disable(manager)
    }

    /// A login failure pauses automatic sync instead of failing every
    /// interval; a clean manual sync resumes it.
    func testLoginFailurePausesUntilAManualSyncSucceeds() async {
        let (manager, runner, sleeper, _) = makeManager(runs: [
            .init(lines: ["[twitter][error] Login required"], exitCode: 1),
            .init(lines: savedMedia(2), exitCode: 0),
        ])
        enable(manager)
        await waitUntil({
            runner.invocations.count == 1 && !manager.likesSyncSnapshot.status.isActive
                && manager.likesSyncSnapshot.status != .idle
        })
        await Task.yield()

        XCTAssertEqual(manager.likesAutoSyncStatus.pauseReason, .authentication)
        XCTAssertNil(manager.likesAutoSyncStatus.nextCheckAt)
        XCTAssertEqual(sleeper.delays, [60])

        manager.startLikesSync()
        await waitUntil({ sleeper.delays.count == 2 }, "manual sync did not resume auto-sync")
        XCTAssertNil(manager.likesAutoSyncStatus.pauseReason)
        XCTAssertEqual(sleeper.delays, [60, 1800])
        disable(manager)
    }

    func testDueCheckWithoutAValidHandleSkipsQuietly() async {
        let (manager, runner, sleeper, _) = makeManager(runs: [])
        manager.twitterHandle = ""
        enable(manager)
        await waitUntil({ sleeper.delays.count == 2 }, "skipped check did not re-arm")
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertEqual(sleeper.delays, [60, 1800])
        XCTAssertEqual(manager.likesSyncSnapshot.status, .idle)
        disable(manager)
    }

    func testSettingIsRestoredAtLaunch() async {
        let defaults = UserDefaults(suiteName: "likes-auto-\(UUID().uuidString)")!
        let (first, _, _, _) = makeManager(runs: [], immediateChecks: 0, defaults: defaults)
        // Its check is held by the fake sleeper and never runs.
        enable(first, interval: .oneHour)

        let (second, _, sleeper, _) = makeManager(runs: [], immediateChecks: 0, defaults: defaults)
        XCTAssertTrue(second.likesAutoSyncEnabled)
        XCTAssertEqual(second.likesAutoSyncInterval, .oneHour)
        XCTAssertEqual(second.likesAutoSyncStatus.nextCheckAt, now.addingTimeInterval(60))
        await waitUntil({ sleeper.delays == [60] }, "restored schedule did not arm")
        disable(second)
    }
}
