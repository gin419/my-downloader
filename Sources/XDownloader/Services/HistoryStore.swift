import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct HistoryEntry {
    var id: String
    var url: String
    var title: String?
    var site: String?
    var mediaCategory: String?
    var outputPath: String?
    var fileSizeBytes: Int64?
    var status: String  // "completed" or "failed"
    var errorMessage: String?
    var startedAt: Date?
    var finishedAt: Date
}

/// Local SQLite store for completed/failed download history. Single shared file
/// at ~/Library/Application Support/XDownloader/history.sqlite. All access is
/// main-actor confined so the raw sqlite3* handle isn't shared across threads.
@MainActor
final class HistoryStore {
    let fileURL: URL
    private var db: OpaquePointer?

    init() {
        let fm = FileManager.default
        let base =
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("XDownloader", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("history.sqlite")
        open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func open() {
        var handle: OpaquePointer?
        guard sqlite3_open(fileURL.path, &handle) == SQLITE_OK else {
            if let h = handle { sqlite3_close(h) }
            return
        }
        db = handle
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        createSchema()
    }

    private func createSchema() {
        let sql = """
            CREATE TABLE IF NOT EXISTS download_history (
                id TEXT PRIMARY KEY,
                url TEXT NOT NULL,
                title TEXT,
                site TEXT,
                media_category TEXT,
                output_path TEXT,
                file_size_bytes INTEGER,
                status TEXT NOT NULL,
                error_message TEXT,
                started_at REAL,
                finished_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_history_url ON download_history(url);
            CREATE INDEX IF NOT EXISTS idx_history_finished_at ON download_history(finished_at DESC);
            """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func record(_ entry: HistoryEntry) {
        let sql = """
            INSERT OR REPLACE INTO download_history
            (id, url, title, site, media_category, output_path, file_size_bytes, status, error_message, started_at, finished_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, entry.id)
        bindText(stmt, 2, entry.url)
        bindOptText(stmt, 3, entry.title)
        bindOptText(stmt, 4, entry.site)
        bindOptText(stmt, 5, entry.mediaCategory)
        bindOptText(stmt, 6, entry.outputPath)
        if let bytes = entry.fileSizeBytes { sqlite3_bind_int64(stmt, 7, bytes) } else { sqlite3_bind_null(stmt, 7) }
        bindText(stmt, 8, entry.status)
        bindOptText(stmt, 9, entry.errorMessage)
        if let s = entry.startedAt { sqlite3_bind_double(stmt, 10, s.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 10) }
        sqlite3_bind_double(stmt, 11, entry.finishedAt.timeIntervalSince1970)

        sqlite3_step(stmt)
    }

    /// Most recent *completed* entry for the given URL — failed prior attempts
    /// don't trigger duplicate warnings.
    func mostRecentCompleted(for url: String) -> HistoryEntry? {
        let sql = """
            SELECT id, url, title, site, media_category, output_path, file_size_bytes, status, error_message, started_at, finished_at
            FROM download_history
            WHERE url = ? AND status = 'completed'
            ORDER BY finished_at DESC
            LIMIT 1;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, url)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readRow(stmt)
    }

    func count() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM download_history;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func fileSize() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    func clear() {
        sqlite3_exec(db, "DELETE FROM download_history;", nil, nil, nil)
        sqlite3_exec(db, "VACUUM;", nil, nil, nil)
    }

    // MARK: - bind/read helpers

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(stmt, idx, $0, -1, SQLITE_TRANSIENT) }
    }

    private func bindOptText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let v = value { bindText(stmt, idx, v) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func readRow(_ stmt: OpaquePointer?) -> HistoryEntry {
        func text(_ idx: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, idx) else { return nil }
            return String(cString: c)
        }
        func int64(_ idx: Int32) -> Int64? {
            sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, idx)
        }
        func double(_ idx: Int32) -> Double? {
            sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, idx)
        }
        return HistoryEntry(
            id: text(0) ?? "",
            url: text(1) ?? "",
            title: text(2),
            site: text(3),
            mediaCategory: text(4),
            outputPath: text(5),
            fileSizeBytes: int64(6),
            status: text(7) ?? "completed",
            errorMessage: text(8),
            startedAt: double(9).map { Date(timeIntervalSince1970: $0) },
            finishedAt: Date(timeIntervalSince1970: double(10) ?? 0)
        )
    }
}
