import XCTest

@testable import XDownloader

/// Locks the per-download security-scope lifecycle the cookies.txt feature relies
/// on (and that A2's state cleanup leans on): `begin` returns the `--cookies` path
/// and registers the scope, `end` pairs the stop, and `withScope` guarantees `end`
/// via `defer` on both the normal and throwing paths.
final class CookieFileScopeTests: XCTestCase {

    private func tempCookies() -> (path: String, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scope-\(UUID().uuidString).txt")
        try? "# cookies".write(to: url, atomically: true, encoding: .utf8)
        return (url.path, url)
    }

    func testBeginReturnsPathThenEndsCleanly() {
        let scope = CookieFileScope()
        let (path, _) = tempCookies()
        let id = UUID()
        XCTAssertEqual(scope.begin(for: id, file: path), path)
        scope.end(for: id)  // paired stopAccessing — must not crash
    }

    func testBeginReturnsNilWhenNothingUsable() {
        let scope = CookieFileScope()
        XCTAssertNil(scope.begin(for: UUID(), file: nil))
        XCTAssertNil(scope.begin(for: UUID(), file: ""))
    }

    func testGrantedURLTakesPrecedence() {
        let scope = CookieFileScope()
        let (path, url) = tempCookies()
        let id = UUID()
        XCTAssertEqual(scope.begin(for: id, file: path, grantedURL: url), path)
        scope.end(for: id)
    }

    func testEndForUnknownIdIsNoOp() {
        CookieFileScope().end(for: UUID())  // no registered scope → must not crash
    }

    func testWithScopeReturnsBodyValue() async {
        let scope = CookieFileScope()
        let (path, _) = tempCookies()
        let result = await scope.withScope(for: UUID(), file: path) { 42 }
        XCTAssertEqual(result, 42)
    }

    func testWithScopeRethrowsAndStillEnds() async {
        struct BoomError: Error {}
        let scope = CookieFileScope()
        let (path, _) = tempCookies()
        let id = UUID()
        do {
            _ = try await scope.withScope(for: id, file: path) { throw BoomError() }
            XCTFail("expected the body error to propagate")
        } catch is BoomError {
            // expected — the defer-end ran on the throwing path
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        scope.end(for: id)  // already ended by defer; safe no-op
    }
}
