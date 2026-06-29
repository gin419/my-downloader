import Foundation

/// Persists the download queue to a JSON file under Application Support, mirroring
/// `HistoryStore`. Pure file I/O — `DownloadManager` owns the item ↔ snapshot
/// mapping, the empty-success self-heal, and the restore ordering.
struct QueueStore {
    private let fileURL: URL

    /// `directory` is injectable for tests; defaults to `~/Library/Application Support/XDownloader`.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.xdownloaderAppSupportDir()
        // Ensure the dir exists (xdownloaderAppSupportDir already creates it; an
        // injected directory might not, so this guards the atomic write below).
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("queue.json")
    }

    /// Best-effort atomic write; persistence failures are intentionally swallowed
    /// (we never surface them to the user).
    func save(_ snapshot: [PersistedDownloadItem]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // best-effort: ignore
        }
    }

    /// The persisted snapshot, or `[]` when the file is missing or unreadable.
    func load() -> [PersistedDownloadItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL),
            let persisted = try? JSONDecoder().decode([PersistedDownloadItem].self, from: data)
        else {
            return []
        }
        return persisted
    }
}
