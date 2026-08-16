import XCTest

@testable import XDownloader

@MainActor
final class LikesSyncStoreTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("likes-\(UUID().uuidString)")
    }

    func testCreatesIndependentLikesDatabaseAndPersistsAccountRunTweetMedia() throws {
        let dir = tempDir()
        let store = LikesSyncStore(directory: dir)
        let account = try store.upsertAccount(input: "@Gin", rootDirectory: dir)
        let accountID = try XCTUnwrap(account.id)
        let run = store.startRun(accountID: accountID, id: "run-1", startedAt: Date(timeIntervalSince1970: 10))

        store.recordTweet(
            LikesSyncTweet(
                tweetID: "123",
                accountID: accountID,
                runID: run.id,
                url: "https://x.com/gin/status/123",
                text: "hello",
                authorHandle: "gin"
            )
        )
        store.recordMedia(
            LikesSyncMedia(
                id: "m1",
                accountID: accountID,
                tweetID: "123",
                runID: run.id,
                kind: "image",
                url: "https://cdn/img.jpg",
                filePath: "/tmp/img.jpg"
            )
        )

        var summary = LikesSyncRunAccumulator()
        summary.apply(
            LikesSyncEvent(
                name: .after, tweetID: "123", tweetURL: nil, text: nil, authorHandle: nil, mediaID: "m1", mediaURL: nil, mediaPath: nil,
                mediaKind: nil, message: nil, failureCategory: nil))
        store.finishRun(id: run.id, status: .completed, summary: summary, finishedAt: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(store.fileURL.lastPathComponent, "likes.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.count("likes_accounts"), 1)
        XCTAssertEqual(store.count("likes_runs"), 1)
        XCTAssertEqual(store.count("likes_tweets"), 1)
        XCTAssertEqual(store.count("likes_media"), 1)
        XCTAssertEqual(store.run(id: "run-1")?.status, .completed)
        XCTAssertEqual(store.run(id: "run-1")?.tweetCount, 1)
        XCTAssertEqual(store.run(id: "run-1")?.mediaCount, 1)
    }

    func testTweetAndMediaIdentityIsScopedToAccount() throws {
        let dir = tempDir()
        let store = LikesSyncStore(directory: dir)
        let firstID = try XCTUnwrap(store.upsertAccount(input: "@first", rootDirectory: dir).id)
        let secondID = try XCTUnwrap(store.upsertAccount(input: "@second", rootDirectory: dir).id)

        for (accountID, runID) in [(firstID, "run-1"), (secondID, "run-2")] {
            _ = store.startRun(accountID: accountID, id: runID)
            store.recordTweet(
                LikesSyncTweet(
                    tweetID: "shared-tweet", accountID: accountID, runID: runID,
                    url: "https://x.com/i/status/shared-tweet", text: nil, authorHandle: nil))
            store.recordMedia(
                LikesSyncMedia(
                    id: "shared-media", accountID: accountID, tweetID: "shared-tweet",
                    runID: runID, kind: "image", url: nil, filePath: nil))
        }

        XCTAssertEqual(store.count("likes_tweets"), 2)
        XCTAssertEqual(store.count("likes_media"), 2)
    }

    func testOpeningStoreRecoversInterruptedRuns() throws {
        let dir = tempDir()
        do {
            let store = LikesSyncStore(directory: dir)
            let account = try store.upsertAccount(input: "@Gin", rootDirectory: dir)
            _ = store.startRun(accountID: try XCTUnwrap(account.id), id: "run-1")
            XCTAssertEqual(store.run(id: "run-1")?.status, .running)
        }

        let reopened = LikesSyncStore(directory: dir)
        XCTAssertEqual(reopened.run(id: "run-1")?.status, .interrupted)
        XCTAssertNotNil(reopened.run(id: "run-1")?.finishedAt)
    }

    func testFailureIgnoreRestoreAndRetryQueries() throws {
        let dir = tempDir()
        let store = LikesSyncStore(directory: dir)
        let account = try store.upsertAccount(input: "@Gin", rootDirectory: dir)
        let accountID = try XCTUnwrap(account.id)
        let run = store.startRun(accountID: accountID, id: "run-1")

        store.recordFailure(
            LikesSyncFailure(
                id: "f1",
                accountID: accountID,
                runID: run.id,
                tweetID: "123",
                url: "https://x.com/gin/status/123",
                category: .authentication,
                message: "login required",
                ignoredAt: nil,
                resolvedAt: nil,
                retryCount: 0
            )
        )

        XCTAssertEqual(store.pendingFailures(accountID: accountID).map(\.id), ["f1"])
        XCTAssertEqual(store.failuresForRetry(accountID: accountID).map(\.id), ["f1"])

        store.ignoreFailure(id: "f1", at: Date(timeIntervalSince1970: 10))
        XCTAssertTrue(store.pendingFailures(accountID: accountID).isEmpty)
        XCTAssertEqual(store.ignoredFailures(accountID: accountID).map(\.id), ["f1"])

        store.restoreFailure(id: "f1")
        store.markFailureRetried(id: "f1")
        let restored = try XCTUnwrap(store.pendingFailures(accountID: accountID).first)
        XCTAssertNil(restored.ignoredAt)
        XCTAssertEqual(restored.retryCount, 1)
    }

    func testRecurringFailurePreservesIgnoreAndSuccessResolvesIt() throws {
        let dir = tempDir()
        let store = LikesSyncStore(directory: dir)
        let account = try store.upsertAccount(input: "@Gin", rootDirectory: dir)
        let accountID = try XCTUnwrap(account.id)
        let run = store.startRun(accountID: accountID, id: "run-1")
        let base = LikesSyncFailure(
            id: "f1", accountID: accountID, runID: run.id, tweetID: "123",
            url: "https://x.com/gin/status/123", category: .network,
            message: "connection reset", ignoredAt: nil, resolvedAt: nil, retryCount: 0)
        store.recordFailure(base)
        store.ignoreFailure(id: base.id, at: Date(timeIntervalSince1970: 10))

        var recurring = base
        recurring.runID = "run-2"
        recurring.message = "connection timed out"
        store.recordFailure(recurring)
        XCTAssertEqual(store.ignoredFailures(accountID: accountID).map(\.id), ["f1"])

        store.resolveFailures(accountID: accountID, tweetID: "123", at: Date(timeIntervalSince1970: 20))
        XCTAssertTrue(store.pendingFailures(accountID: accountID).isEmpty)
        XCTAssertTrue(store.ignoredFailures(accountID: accountID).isEmpty)
    }

    // MARK: - Run-level failure resolution (fix 1)

    private func runLevelFailure(
        accountID: Int64, runID: String, category: LikesSyncFailureCategory = .authentication
    ) -> LikesSyncFailure {
        LikesSyncFailure(
            id: "\(accountID):\(category.rawValue)",
            accountID: accountID,
            runID: runID,
            tweetID: nil,
            url: nil,
            category: category,
            message: "login required",
            ignoredAt: nil,
            resolvedAt: nil,
            retryCount: 0)
    }

    /// `resolveFailures(_:tweetID:)` matches `tweet_id = ?` and can never
    /// reach a run-level row; `resolveRunLevelFailures` resolves exactly the
    /// NULL-tweet_id rows and leaves per-item failures pending.
    func testResolveRunLevelFailuresResolvesOnlyNullTweetRows() throws {
        let dir = tempDir()
        let store = LikesSyncStore(directory: dir)
        let accountID = try XCTUnwrap(store.upsertAccount(input: "@Gin", rootDirectory: dir).id)
        let run = store.startRun(accountID: accountID, id: "run-1")
        store.recordFailure(runLevelFailure(accountID: accountID, runID: run.id))
        store.recordFailure(
            LikesSyncFailure(
                id: "\(accountID):123", accountID: accountID, runID: run.id, tweetID: "123",
                url: "https://x.com/gin/status/123", category: .network,
                message: "connection reset", ignoredAt: nil, resolvedAt: nil, retryCount: 0))

        store.resolveRunLevelFailures(accountID: accountID, at: Date(timeIntervalSince1970: 30))

        XCTAssertEqual(store.pendingFailures(accountID: accountID).map(\.tweetID), ["123"])
    }

    /// Like per-item resolution, run-level resolution supersedes Ignore — a
    /// proven-gone cause must not linger in the ignored list either.
    func testResolveRunLevelFailuresSupersedesIgnore() throws {
        let dir = tempDir()
        let store = LikesSyncStore(directory: dir)
        let accountID = try XCTUnwrap(store.upsertAccount(input: "@Gin", rootDirectory: dir).id)
        let run = store.startRun(accountID: accountID, id: "run-1")
        let failure = runLevelFailure(accountID: accountID, runID: run.id)
        store.recordFailure(failure)
        store.ignoreFailure(id: failure.id, at: Date(timeIntervalSince1970: 10))

        store.resolveRunLevelFailures(accountID: accountID, at: Date(timeIntervalSince1970: 30))

        XCTAssertTrue(store.pendingFailures(accountID: accountID).isEmpty)
        XCTAssertTrue(store.ignoredFailures(accountID: accountID).isEmpty)
    }

    /// Resolution is scoped to the account whose scan succeeded.
    func testResolveRunLevelFailuresIsScopedToTheAccount() throws {
        let dir = tempDir()
        let store = LikesSyncStore(directory: dir)
        let firstID = try XCTUnwrap(store.upsertAccount(input: "@first", rootDirectory: dir).id)
        let secondID = try XCTUnwrap(store.upsertAccount(input: "@second", rootDirectory: dir).id)
        for (accountID, runID) in [(firstID, "run-1"), (secondID, "run-2")] {
            _ = store.startRun(accountID: accountID, id: runID)
            store.recordFailure(runLevelFailure(accountID: accountID, runID: runID))
        }

        store.resolveRunLevelFailures(accountID: firstID)

        XCTAssertTrue(store.pendingFailures(accountID: firstID).isEmpty)
        XCTAssertEqual(store.pendingFailures(accountID: secondID).count, 1)
    }
}
