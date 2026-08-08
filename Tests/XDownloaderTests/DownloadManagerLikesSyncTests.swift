import XCTest

@testable import XDownloader

@MainActor
private final class FakeLikesSyncProcessRunner: LikesSyncProcessRunning {
    struct Run {
        var lines: [String]
        var exitCode: Int32
        var waitsForCancellation = false
    }

    private(set) var invocations: [[String]] = []
    var runs: [Run]

    init(runs: [Run]) {
        self.runs = runs
    }

    func run(
        executablePath _: String,
        arguments: [String],
        register _: @escaping (Process) -> Void,
        unregister _: @escaping () -> Void,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Int32 {
        invocations.append(arguments)
        let run = runs.removeFirst()
        if run.waitsForCancellation {
            while !Task.isCancelled { await Task.yield() }
            return 15
        }
        for line in run.lines {
            onLine(line)
            await Task.yield()
        }
        return run.exitCode
    }
}

@MainActor
final class DownloadManagerLikesSyncTests: XCTestCase {
    private func makeManager(
        runs: [FakeLikesSyncProcessRunner.Run]
    ) -> (DownloadManager, FakeLikesSyncProcessRunner, LikesSyncStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("likes-manager-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "likes-manager-\(UUID().uuidString)")!
        let runner = FakeLikesSyncProcessRunner(runs: runs)
        let store = LikesSyncStore(directory: directory)
        let manager = DownloadManager(
            history: HistoryStore(directory: directory),
            queueStore: QueueStore(directory: directory),
            settingsStore: SettingsStore(defaults: defaults),
            likesSyncStore: store,
            likesProcessRunner: runner,
            galleryDlPathProvider: { "/fake/gallery-dl" })
        manager.outputDirectory = directory.appendingPathComponent("downloads")
        manager.twitterHandle = "@gin"
        return (manager, runner, store, directory)
    }

    private func waitForLikesRun(_ manager: DownloadManager) async {
        for _ in 0..<10_000 {
            if manager.likesSyncSnapshot.status != .idle,
                !manager.likesSyncSnapshot.status.isActive
            {
                return
            }
            await Task.yield()
        }
        XCTFail("Likes sync did not finish")
    }

    private func waitForVerification(_ manager: DownloadManager) async {
        for _ in 0..<10_000 {
            if manager.likesAccessVerification != .verifying { return }
            await Task.yield()
        }
        XCTFail("Likes verification did not finish")
    }

    private func event(_ name: String, _ json: String) -> String {
        "\(name):likes-sync\t\(json)"
    }

    func testFirstRunDownloadsAndSecondRunArchiveSkipsWithoutDuplicates() async throws {
        let post = event(
            "post", #"{"tweet_id":"123","url":"https://x.com/gin/status/123","author":{"nick":"gin"}}"#)
        let after = event(
            "after", #"{"tweet_id":"123","media_id":"m1","_path":"/tmp/a.jpg","extension":"jpg"}"#)
        let postAfter = event("post-after", #"{"tweet_id":"123"}"#)
        let skip = event(
            "skip", #"{"tweet_id":"123","media_id":"m1","_path":"/tmp/a.jpg","extension":"jpg"}"#)
        let (manager, runner, store, _) = makeManager(runs: [
            .init(lines: [post, after, postAfter], exitCode: 0),
            .init(lines: [post, skip, postAfter], exitCode: 0),
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.downloaded, 1)
        XCTAssertEqual(store.count("likes_tweets"), 1)
        XCTAssertEqual(store.count("likes_media"), 1)

        manager.startLikesSync()
        await waitForLikesRun(manager)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.downloaded, 0)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.skipped, 1)
        XCTAssertEqual(store.count("likes_media"), 1)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertTrue(runner.invocations[0].contains("extractor.twitter.cards=false"))
        XCTAssertEqual(runner.invocations[0].last, "https://x.com/gin/likes")
    }

    func testCookieExtractionInfoDoesNotFailSuccessfulVerification() async throws {
        let (manager, runner, _, _) = makeManager(runs: [
            .init(lines: ["[cookies][info] Extracted 863 cookies from Chrome"], exitCode: 0)
        ])

        manager.verifyLikesAccess()
        await waitForVerification(manager)

        XCTAssertEqual(manager.likesAccessVerification, .verified(try LikesSyncHandle("@gin")))
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testCookieExtractionInfoDoesNotCreateSuccessfulSyncFailure() async {
        let (manager, _, _, _) = makeManager(runs: [
            .init(lines: ["[cookies][info] Extracted 863 cookies from Chrome"], exitCode: 0)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertTrue(manager.likesSyncSnapshot.failures.isEmpty)
    }

    func testCancelBeforeRunnerStartsFinishesCancelledWithoutFailure() async throws {
        let (manager, _, store, _) = makeManager(runs: [
            .init(lines: [], exitCode: 15, waitsForCancellation: true)
        ])

        manager.startLikesSync()
        manager.cancelLikesSync()
        await waitForLikesRun(manager)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .cancelled)
        XCTAssertTrue(manager.likesSyncSnapshot.failures.isEmpty)
        let accountID = try XCTUnwrap(store.account(for: LikesSyncHandle("gin"))?.id)
        XCTAssertEqual(store.latestRun(accountID: accountID)?.status, .cancelled)
    }

    func testFailedItemCanRetryItsURLAndResolveTheFailure() async throws {
        let url = "https://x.com/gin/status/999"
        let error = event(
            "error", #"{"tweet_id":"999","url":"https://x.com/gin/status/999","message":"connection timeout"}"#)
        let skip = event(
            "skip", #"{"tweet_id":"999","media_id":"m999","_path":"/tmp/retry.jpg"}"#)
        let (manager, runner, _, _) = makeManager(runs: [
            .init(lines: [error], exitCode: 1),
            .init(lines: [skip], exitCode: 0),
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .failed)
        XCTAssertEqual(failure.category, .network)

        manager.retryLikesFailure(failure)
        await waitForLikesRun(manager)
        XCTAssertEqual(runner.invocations.last?.last, url)
        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertTrue(manager.likesSyncSnapshot.failures.isEmpty)
    }

    func testIgnoringLastFailureClearsAttentionButKeepsIgnoredCount() async throws {
        let error = event("error", #"{"tweet_id":"999","message":"item unavailable"}"#)
        let (manager, _, store, _) = makeManager(runs: [
            .init(lines: [error], exitCode: 1)
        ])

        manager.startLikesSync()
        await waitForLikesRun(manager)
        let failure = try XCTUnwrap(manager.likesSyncSnapshot.failures.first)
        manager.ignoreLikesFailure(failure)

        XCTAssertEqual(manager.likesSyncSnapshot.status, .completed)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.failed, 0)
        XCTAssertEqual(manager.likesSyncSnapshot.counts.ignored, 1)
        let accountID = try XCTUnwrap(store.account(for: LikesSyncHandle("gin"))?.id)
        XCTAssertEqual(store.latestRun(accountID: accountID)?.status, .completed)
    }
}
