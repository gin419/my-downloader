import Foundation
import SQLite3

private let LIKES_SYNC_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class LikesSyncStore {
    let fileURL: URL
    private var db: OpaquePointer?

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.xdownloaderAppSupportDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("likes.sqlite")
        open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func upsertAccount(input: String, rootDirectory: URL) throws -> LikesSyncAccount {
        let handle = try LikesSyncHandle(input)
        let plan = LikesSyncPlanner.plan(for: handle, rootDirectory: rootDirectory)
        let now = Date().timeIntervalSince1970
        let sql = """
            INSERT INTO likes_accounts (handle, input, profile_url, output_directory, archive_path, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(handle) DO UPDATE SET
                input = excluded.input,
                profile_url = excluded.profile_url,
                output_directory = excluded.output_directory,
                archive_path = excluded.archive_path,
                updated_at = excluded.updated_at;
            """
        withStatement(sql) { stmt in
            bindText(stmt, 1, handle.value)
            bindText(stmt, 2, input)
            bindText(stmt, 3, handle.profileURL.absoluteString)
            bindText(stmt, 4, plan.outputDirectory.path)
            bindText(stmt, 5, plan.archivePath.path)
            sqlite3_bind_double(stmt, 6, now)
            sqlite3_bind_double(stmt, 7, now)
            sqlite3_step(stmt)
        }
        guard let account = account(for: handle) else { throw LikesSyncStoreError.writeFailed }
        return account
    }

    func account(for handle: LikesSyncHandle) -> LikesSyncAccount? {
        let sql = """
            SELECT id, handle, input, output_directory, archive_path
            FROM likes_accounts
            WHERE handle = ?;
            """
        var account: LikesSyncAccount?
        withStatement(sql) { stmt in
            bindText(stmt, 1, handle.value)
            if sqlite3_step(stmt) == SQLITE_ROW {
                account = LikesSyncAccount(
                    id: sqlite3_column_int64(stmt, 0),
                    handle: (try? LikesSyncHandle(text(stmt, 1) ?? "")) ?? handle,
                    input: text(stmt, 2) ?? handle.displayName,
                    outputDirectory: URL(fileURLWithPath: text(stmt, 3) ?? ""),
                    archivePath: URL(fileURLWithPath: text(stmt, 4) ?? "")
                )
            }
        }
        return account
    }

    func startRun(accountID: Int64, id: String = UUID().uuidString, startedAt: Date = Date()) -> LikesSyncRun {
        let run = LikesSyncRun(
            id: id,
            accountID: accountID,
            status: .running,
            startedAt: startedAt,
            finishedAt: nil,
            tweetCount: 0,
            mediaCount: 0,
            failureCount: 0
        )
        let sql = """
            INSERT OR REPLACE INTO likes_runs
            (id, account_id, status, started_at, finished_at, tweet_count, media_count, failure_count,
             skipped_count, no_media_count, ignored_count)
            VALUES (?, ?, ?, ?, NULL, 0, 0, 0, 0, 0, 0);
            """
        withStatement(sql) { stmt in
            bindText(stmt, 1, run.id)
            sqlite3_bind_int64(stmt, 2, accountID)
            bindText(stmt, 3, run.status.rawValue)
            sqlite3_bind_double(stmt, 4, startedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        return run
    }

    func finishRun(
        id: String,
        status: LikesSyncRunStatus,
        summary: LikesSyncRunAccumulator,
        ignoredCount: Int = 0,
        finishedAt: Date = Date()
    ) {
        let sql = """
            UPDATE likes_runs
            SET status = ?, finished_at = ?, tweet_count = ?, media_count = ?, failure_count = ?,
                skipped_count = ?, no_media_count = ?, ignored_count = ?
            WHERE id = ?;
            """
        withStatement(sql) { stmt in
            bindText(stmt, 1, status.rawValue)
            sqlite3_bind_double(stmt, 2, finishedAt.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 3, Int64(summary.tweetCount))
            sqlite3_bind_int64(stmt, 4, Int64(summary.downloadedCount))
            sqlite3_bind_int64(stmt, 5, Int64(summary.failureCount))
            sqlite3_bind_int64(stmt, 6, Int64(summary.skippedCount))
            sqlite3_bind_int64(stmt, 7, Int64(summary.noMediaCount))
            sqlite3_bind_int64(stmt, 8, Int64(ignoredCount))
            bindText(stmt, 9, id)
            sqlite3_step(stmt)
        }
    }

    @discardableResult
    func recoverInterruptedRuns(finishedAt: Date = Date()) -> Int {
        let sql = """
            UPDATE likes_runs
            SET status = ?, finished_at = ?
            WHERE status IN (?, ?);
            """
        var changed = 0
        withStatement(sql) { stmt in
            bindText(stmt, 1, LikesSyncRunStatus.interrupted.rawValue)
            sqlite3_bind_double(stmt, 2, finishedAt.timeIntervalSince1970)
            bindText(stmt, 3, LikesSyncRunStatus.running.rawValue)
            bindText(stmt, 4, LikesSyncRunStatus.cancelling.rawValue)
            sqlite3_step(stmt)
            changed = Int(sqlite3_changes(db))
        }
        return changed
    }

    func run(id: String) -> LikesSyncRun? {
        let sql = """
            SELECT id, account_id, status, started_at, finished_at, tweet_count, media_count, failure_count,
                   skipped_count, no_media_count, ignored_count
            FROM likes_runs WHERE id = ?;
            """
        var run: LikesSyncRun?
        withStatement(sql) { stmt in
            bindText(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                run = readRun(stmt)
            }
        }
        return run
    }

    func latestRun(accountID: Int64) -> LikesSyncRun? {
        let sql = """
            SELECT id, account_id, status, started_at, finished_at, tweet_count, media_count, failure_count,
                   skipped_count, no_media_count, ignored_count
            FROM likes_runs WHERE account_id = ? ORDER BY started_at DESC LIMIT 1;
            """
        var run: LikesSyncRun?
        withStatement(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, accountID)
            if sqlite3_step(stmt) == SQLITE_ROW { run = readRun(stmt) }
        }
        return run
    }

    func updateRunStatus(id: String, status: LikesSyncRunStatus) {
        withStatement("UPDATE likes_runs SET status = ? WHERE id = ?;") { stmt in
            bindText(stmt, 1, status.rawValue)
            bindText(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    func recordTweet(_ tweet: LikesSyncTweet) {
        let sql = """
            INSERT OR REPLACE INTO likes_tweets
            (tweet_id, account_id, run_id, url, text, author_handle, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        withStatement(sql) { stmt in
            bindText(stmt, 1, tweet.tweetID)
            sqlite3_bind_int64(stmt, 2, tweet.accountID)
            bindText(stmt, 3, tweet.runID)
            bindOptText(stmt, 4, tweet.url)
            bindOptText(stmt, 5, tweet.text)
            bindOptText(stmt, 6, tweet.authorHandle)
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func recordMedia(_ media: LikesSyncMedia) {
        let sql = """
            INSERT OR REPLACE INTO likes_media
            (id, account_id, tweet_id, run_id, kind, url, file_path, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        withStatement(sql) { stmt in
            bindText(stmt, 1, media.id)
            sqlite3_bind_int64(stmt, 2, media.accountID)
            bindText(stmt, 3, media.tweetID)
            bindText(stmt, 4, media.runID)
            bindOptText(stmt, 5, media.kind)
            bindOptText(stmt, 6, media.url)
            bindOptText(stmt, 7, media.filePath)
            sqlite3_bind_double(stmt, 8, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func recordFailure(_ failure: LikesSyncFailure) {
        let sql = """
            INSERT INTO likes_failures
            (id, account_id, run_id, tweet_id, url, category, message, ignored_at, resolved_at, retry_count, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                run_id = excluded.run_id,
                tweet_id = excluded.tweet_id,
                url = excluded.url,
                category = excluded.category,
                message = excluded.message,
                ignored_at = COALESCE(likes_failures.ignored_at, excluded.ignored_at),
                resolved_at = excluded.resolved_at,
                retry_count = likes_failures.retry_count,
                updated_at = excluded.updated_at;
            """
        withStatement(sql) { stmt in
            bindText(stmt, 1, failure.id)
            sqlite3_bind_int64(stmt, 2, failure.accountID)
            bindOptText(stmt, 3, failure.runID)
            bindOptText(stmt, 4, failure.tweetID)
            bindOptText(stmt, 5, failure.url)
            bindText(stmt, 6, failure.category.rawValue)
            bindText(stmt, 7, failure.message)
            bindOptDate(stmt, 8, failure.ignoredAt)
            bindOptDate(stmt, 9, failure.resolvedAt)
            sqlite3_bind_int64(stmt, 10, Int64(failure.retryCount))
            sqlite3_bind_double(stmt, 11, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func pendingFailures(accountID: Int64? = nil) -> [LikesSyncFailure] {
        failures(whereClause: "ignored_at IS NULL AND resolved_at IS NULL", accountID: accountID)
    }

    func ignoredFailures(accountID: Int64? = nil) -> [LikesSyncFailure] {
        failures(whereClause: "ignored_at IS NOT NULL AND resolved_at IS NULL", accountID: accountID)
    }

    func failuresForRetry(accountID: Int64? = nil) -> [LikesSyncFailure] {
        failures(whereClause: "ignored_at IS NULL AND resolved_at IS NULL", accountID: accountID)
    }

    func ignoreFailure(id: String, at date: Date = Date()) {
        updateFailureDate(id: id, column: "ignored_at", date: date)
    }

    func restoreFailure(id: String) {
        updateFailureDate(id: id, column: "ignored_at", date: nil)
    }

    func markFailureRetried(id: String) {
        let sql = """
            UPDATE likes_failures
            SET retry_count = retry_count + 1, updated_at = ?
            WHERE id = ?;
            """
        withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            bindText(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    func resolveFailures(accountID: Int64, tweetID: String, at date: Date = Date()) {
        let sql = """
            UPDATE likes_failures
            SET resolved_at = ?, updated_at = ?
            WHERE account_id = ? AND tweet_id = ? AND resolved_at IS NULL;
            """
        withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 3, accountID)
            bindText(stmt, 4, tweetID)
            sqlite3_step(stmt)
        }
    }

    func count(_ table: String) -> Int {
        guard ["likes_accounts", "likes_runs", "likes_tweets", "likes_media", "likes_failures"].contains(table) else {
            return 0
        }
        var value = 0
        withStatement("SELECT COUNT(*) FROM \(table);") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                value = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return value
    }

    private func open() {
        var handle: OpaquePointer?
        guard sqlite3_open(fileURL.path, &handle) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return
        }
        db = handle
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        createSchema()
        _ = recoverInterruptedRuns()
    }

    private func createSchema() {
        let sql = """
            CREATE TABLE IF NOT EXISTS likes_accounts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                handle TEXT NOT NULL UNIQUE,
                input TEXT NOT NULL,
                profile_url TEXT NOT NULL,
                output_directory TEXT NOT NULL,
                archive_path TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS likes_runs (
                id TEXT PRIMARY KEY,
                account_id INTEGER NOT NULL,
                status TEXT NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL,
                tweet_count INTEGER NOT NULL DEFAULT 0,
                media_count INTEGER NOT NULL DEFAULT 0,
                failure_count INTEGER NOT NULL DEFAULT 0,
                skipped_count INTEGER NOT NULL DEFAULT 0,
                no_media_count INTEGER NOT NULL DEFAULT 0,
                ignored_count INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY(account_id) REFERENCES likes_accounts(id)
            );
            CREATE TABLE IF NOT EXISTS likes_tweets (
                tweet_id TEXT NOT NULL,
                account_id INTEGER NOT NULL,
                run_id TEXT NOT NULL,
                url TEXT,
                text TEXT,
                author_handle TEXT,
                updated_at REAL NOT NULL,
                PRIMARY KEY(account_id, tweet_id),
                FOREIGN KEY(account_id) REFERENCES likes_accounts(id),
                FOREIGN KEY(run_id) REFERENCES likes_runs(id)
            );
            CREATE TABLE IF NOT EXISTS likes_media (
                id TEXT NOT NULL,
                account_id INTEGER NOT NULL,
                tweet_id TEXT NOT NULL,
                run_id TEXT NOT NULL,
                kind TEXT,
                url TEXT,
                file_path TEXT,
                updated_at REAL NOT NULL,
                PRIMARY KEY(account_id, id),
                FOREIGN KEY(account_id, tweet_id) REFERENCES likes_tweets(account_id, tweet_id),
                FOREIGN KEY(run_id) REFERENCES likes_runs(id)
            );
            CREATE TABLE IF NOT EXISTS likes_failures (
                id TEXT PRIMARY KEY,
                account_id INTEGER NOT NULL,
                run_id TEXT,
                tweet_id TEXT,
                url TEXT,
                category TEXT NOT NULL,
                message TEXT NOT NULL,
                ignored_at REAL,
                resolved_at REAL,
                retry_count INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL,
                FOREIGN KEY(account_id) REFERENCES likes_accounts(id)
            );
            CREATE INDEX IF NOT EXISTS idx_likes_runs_account ON likes_runs(account_id, started_at DESC);
            CREATE INDEX IF NOT EXISTS idx_likes_failures_account ON likes_failures(account_id, ignored_at, resolved_at);
            CREATE INDEX IF NOT EXISTS idx_likes_media_tweet ON likes_media(tweet_id);
            """
        sqlite3_exec(db, sql, nil, nil, nil)
        // Forward-compatible for development builds that created the v0 schema.
        for migration in [
            "ALTER TABLE likes_runs ADD COLUMN skipped_count INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE likes_runs ADD COLUMN no_media_count INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE likes_runs ADD COLUMN ignored_count INTEGER NOT NULL DEFAULT 0;",
        ] {
            sqlite3_exec(db, migration, nil, nil, nil)
        }
    }

    private func failures(whereClause: String, accountID: Int64?) -> [LikesSyncFailure] {
        var sql = """
            SELECT id, account_id, run_id, tweet_id, url, category, message, ignored_at, resolved_at, retry_count
            FROM likes_failures
            WHERE \(whereClause)
            """
        if accountID != nil { sql += " AND account_id = ?" }
        sql += " ORDER BY updated_at DESC;"

        var rows: [LikesSyncFailure] = []
        withStatement(sql) { stmt in
            if let accountID {
                sqlite3_bind_int64(stmt, 1, accountID)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readFailure(stmt))
            }
        }
        return rows
    }

    private func updateFailureDate(id: String, column: String, date: Date?) {
        guard column == "ignored_at" || column == "resolved_at" else { return }
        let sql = "UPDATE likes_failures SET \(column) = ?, updated_at = ? WHERE id = ?;"
        withStatement(sql) { stmt in
            bindOptDate(stmt, 1, date)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            bindText(stmt, 3, id)
            sqlite3_step(stmt)
        }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        body(stmt)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(stmt, idx, $0, -1, LIKES_SYNC_SQLITE_TRANSIENT) }
    }

    private func bindOptText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value { bindText(stmt, idx, value) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindOptDate(_ stmt: OpaquePointer?, _ idx: Int32, _ date: Date?) {
        if let date {
            sqlite3_bind_double(stmt, idx, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func text(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func double(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, idx)
    }

    private func readRun(_ stmt: OpaquePointer?) -> LikesSyncRun {
        LikesSyncRun(
            id: text(stmt, 0) ?? "",
            accountID: sqlite3_column_int64(stmt, 1),
            status: LikesSyncRunStatus(rawValue: text(stmt, 2) ?? "") ?? .failed,
            startedAt: Date(timeIntervalSince1970: double(stmt, 3) ?? 0),
            finishedAt: double(stmt, 4).map { Date(timeIntervalSince1970: $0) },
            tweetCount: Int(sqlite3_column_int64(stmt, 5)),
            mediaCount: Int(sqlite3_column_int64(stmt, 6)),
            failureCount: Int(sqlite3_column_int64(stmt, 7)),
            skippedCount: Int(sqlite3_column_int64(stmt, 8)),
            noMediaCount: Int(sqlite3_column_int64(stmt, 9)),
            ignoredCount: Int(sqlite3_column_int64(stmt, 10))
        )
    }

    private func readFailure(_ stmt: OpaquePointer?) -> LikesSyncFailure {
        LikesSyncFailure(
            id: text(stmt, 0) ?? "",
            accountID: sqlite3_column_int64(stmt, 1),
            runID: text(stmt, 2),
            tweetID: text(stmt, 3),
            url: text(stmt, 4),
            category: LikesSyncFailureCategory(rawValue: text(stmt, 5) ?? "") ?? .unknown,
            message: text(stmt, 6) ?? "",
            ignoredAt: double(stmt, 7).map { Date(timeIntervalSince1970: $0) },
            resolvedAt: double(stmt, 8).map { Date(timeIntervalSince1970: $0) },
            retryCount: Int(sqlite3_column_int64(stmt, 9))
        )
    }
}

enum LikesSyncStoreError: Error {
    case writeFailed
}
