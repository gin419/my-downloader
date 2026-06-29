import Foundation

extension FileManager {
    /// `~/Library/Application Support/XDownloader`, created if needed. The single
    /// source of the app-support directory (used by QueueStore + HistoryStore).
    func xdownloaderAppSupportDir() -> URL {
        let base =
            urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("XDownloader", isDirectory: true)
        try? createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Homebrew locations, shared so ProcessRunner and RequirementsService don't drift.
enum Homebrew {
    /// Homebrew bin/sbin prefixes (Apple Silicon + Intel).
    static let binPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
    /// A full PATH with Homebrew first, then the standard system dirs.
    static let fullPATH = "\(binPaths):/usr/bin:/bin:/usr/sbin:/sbin"
}
