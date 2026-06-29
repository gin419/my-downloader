import Foundation

/// Owns the security-scoped bookmark and the per-download scope for the optional
/// cookies.txt file. Extracted from `DownloadManager` so the bookmark/grant
/// lifecycle lives in one place. The display path (`cookiesFilePath`) stays on
/// `DownloadManager` because it's `@Published` and bound to the Settings UI.
@MainActor
final class CookieAccessManager {
    private var bookmarkData: Data?
    private let scope = CookieFileScope()

    /// The bookmark to persist (nil when nothing / only a plain path is set).
    var bookmarkForSaving: Data? { bookmarkData }

    /// Restore the persisted bookmark on launch.
    func loadBookmark(_ data: Data?) { bookmarkData = data }

    /// Store a security-scoped bookmark for `url`. Returns false when the bookmark
    /// can't be created — the caller then falls back to a plain path with no grant.
    @discardableResult
    func setFile(_ url: URL) -> Bool {
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarkData = data
            return true
        }
        bookmarkData = nil
        return false
    }

    func clear() { bookmarkData = nil }

    /// Resolve the bookmark fresh for one download: the `--cookies` path and the
    /// granted security-scoped URL. `(nil, nil)` when there's no usable bookmark
    /// (the caller then uses its plain display path). Resolving fresh avoids stale grants.
    func resolveForDownload() -> (path: String?, granted: URL?) {
        guard let data = bookmarkData else { return (nil, nil) }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else { return (nil, nil) }
        return (url.path, url)
    }

    /// Hold the security-scoped grant for `id` across `body` (started in `begin`,
    /// stopped via `defer`). Delegates to the per-item `CookieFileScope`.
    func withScope<T>(for id: UUID, file: String?, grantedURL: URL?,
                      _ body: () async throws -> T) async rethrows -> T {
        try await scope.withScope(for: id, file: file, grantedURL: grantedURL, body)
    }
}
