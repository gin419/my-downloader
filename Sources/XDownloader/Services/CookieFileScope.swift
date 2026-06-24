import Foundation

/// Manages per-download-item security-scoped URLs so that the grant
/// for a cookies.txt file stays alive exactly for the lifetime of the
/// child process (yt-dlp or gallery-dl) that needs it. Uses `defer` inside
/// `withScope` to guarantee `end` on all exit paths (normal, error, early return).
final class CookieFileScope {
    private var scopes: [UUID: URL] = [:]

    /// Begin scope for the given item and file path. If a grantedURL (resolved from bookmarkData with active startAccessing)
    /// is provided, use it instead of a plain file URL so the exact grant object is kept alive and stopped in pair.
    /// Returns the path for --cookies.
    func begin(for id: UUID, file: String?, grantedURL: URL? = nil) -> String? {
        let url: URL
        if let g = grantedURL {
            url = g
            _ = g.startAccessingSecurityScopedResource() // re-ensure while we hold ref
        } else if let f = file, !f.isEmpty {
            url = URL(fileURLWithPath: f)
            if !url.startAccessingSecurityScopedResource() { return nil }
        } else {
            return nil
        }
        scopes[id] = url
        return file ?? url.path
    }

    func end(for id: UUID) {
        if let url = scopes.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Run `body` while holding the scope for `id`. `end` is guaranteed via `defer`.
    /// Pass grantedURL (the resolved bookmark one) when available to transfer the correct grant.
    func withScope<T>(for id: UUID, file: String?, grantedURL: URL? = nil, _ body: () async throws -> T) async rethrows -> T {
        let _ = begin(for: id, file: file, grantedURL: grantedURL)
        defer { end(for: id) }
        return try await body()
    }
}
