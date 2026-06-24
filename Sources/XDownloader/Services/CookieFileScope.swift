import Foundation

/// Manages per-download-item security-scoped URLs so that the grant
/// for a cookies.txt file stays alive exactly for the lifetime of the
/// child process (yt-dlp or gallery-dl) that needs it. Uses `defer` inside
/// `withScope` to guarantee `end` on all exit paths (normal, error, early return).
final class CookieFileScope {
    private var scopes: [UUID: URL] = [:]

    /// Begin scope for the given item and (bookmark-resolved) file path.
    /// Returns the path to pass to --cookies, or nil.
    func begin(for id: UUID, file: String?) -> String? {
        guard let f = file, !f.isEmpty else { return nil }
        let url = URL(fileURLWithPath: f)
        if url.startAccessingSecurityScopedResource() {
            scopes[id] = url
            return f
        }
        return nil
    }

    func end(for id: UUID) {
        if let url = scopes.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Run `body` while holding the scope for `id`. `end` is guaranteed via `defer`
    /// even if body throws or returns early.
    func withScope<T>(for id: UUID, file: String?, _ body: () async throws -> T) async rethrows -> T {
        let _ = begin(for: id, file: file)
        defer { end(for: id) }
        return try await body()
    }
}
