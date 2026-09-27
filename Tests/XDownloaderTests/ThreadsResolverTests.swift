import XCTest

@testable import XDownloader

/// `ThreadsService`'s pure half: link parsing, picking the linked post out of
/// a page, media extraction, the quoted/reposted/linked fallback, failure
/// classification, file names and message copy. The pages are SYNTHETIC
/// (invented accounts and captions, host scontent.example.invalid) and each
/// one also holds decoy media in replies, the author's own thread, the
/// parent thread and related posts. Fixtures/manifest.json states what every
/// page must resolve to.
@MainActor
final class ThreadsResolverTests: XCTestCase {

    // MARK: - Fixture loading

    private struct Expectation: Decodable {
        struct ExpectedMedia: Decodable {
            let type: String
            let url: String
            let width: Int?
            let height: Int?
        }

        let link: String
        let final_url: String?
        let fixture: String
        let expect_ok: Bool
        let expect_error: String?
        let expect_media_source: String?
        let expect_media: [ExpectedMedia]
        let expect_author: String?
        let expect_code: String?
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name)")
        return url
    }

    private func expectation(for fixture: String) throws -> Expectation {
        let manifest = try JSONDecoder().decode([Expectation].self, from: Data(contentsOf: fixtureURL("manifest.json")))
        return try XCTUnwrap(manifest.first { $0.fixture == fixture }, "no manifest entry for \(fixture)")
    }

    private func resolve(_ expected: Expectation) throws -> Result<ThreadsService.ResolvedPost, ThreadsService.Failure> {
        let html = try String(contentsOf: fixtureURL(expected.fixture), encoding: .utf8)
        let link = try XCTUnwrap(ThreadsService.parseLink(expected.link))
        return ThreadsService.resolve(html: html, finalURL: URL(string: expected.final_url ?? expected.link), code: link.code)
    }

    /// Resolves one fixture and checks it against its manifest entry.
    private func assertMatchesManifest(_ fixture: String, line: UInt = #line) throws {
        let expected = try expectation(for: fixture)
        switch try resolve(expected) {
        case .success(let post):
            XCTAssertTrue(expected.expect_ok, "resolved, but the manifest expects \(expected.expect_error ?? "a failure")", line: line)
            XCTAssertEqual(post.source.rawValue, expected.expect_media_source, line: line)
            XCTAssertEqual(post.author, expected.expect_author, line: line)
            XCTAssertEqual(post.code, expected.expect_code, line: line)
            XCTAssertEqual(post.media.map(\.kind.rawValue), expected.expect_media.map(\.type), line: line)
            // Byte for byte: the addresses are signed.
            XCTAssertEqual(post.media.map(\.url.absoluteString), expected.expect_media.map(\.url), line: line)
            XCTAssertEqual(post.media.map(\.width), expected.expect_media.map(\.width), line: line)
            XCTAssertEqual(post.media.map(\.height), expected.expect_media.map(\.height), line: line)
            XCTAssertFalse(post.media.contains { $0.url.absoluteString.contains("decoy") }, "picked decoy media", line: line)
        case .failure(let failure):
            XCTAssertFalse(expected.expect_ok, "failed with \(failure), but the manifest expects media", line: line)
            XCTAssertEqual(Self.manifestName(of: failure), expected.expect_error, line: line)
        }
    }

    private static func manifestName(of failure: ThreadsService.Failure) -> String {
        switch failure {
        case .notFound: return "not_found"
        case .loginRequired: return "login_required"
        case .restricted: return "restricted_audience"
        case .blockedShell: return "blocked_shell"
        case .noPostData: return "no_post_data"
        case .noMedia: return "no_media"
        }
    }

    func testEveryFixtureHasAManifestEntryAndATest() throws {
        // A fixture added without a test would sit in the repo proving nothing.
        let manifest = try JSONDecoder().decode([Expectation].self, from: Data(contentsOf: fixtureURL("manifest.json")))
        let pages = try FileManager.default.contentsOfDirectory(atPath: fixtureURL("").path).filter { $0.hasSuffix(".html") }
        XCTAssertEqual(Set(manifest.map(\.fixture)), Set(pages))
        XCTAssertEqual(manifest.count, 15)
    }

    // MARK: - Posts with media of their own

    func testSingleImage() throws {
        try assertMatchesManifest("threads_single_image.html")
    }

    func testSingleImageWebpWithoutSizeParameter() throws {
        try assertMatchesManifest("threads_single_image_webp_no_stp.html")
    }

    func testImageCarouselKeepsOrder() throws {
        try assertMatchesManifest("threads_image_carousel.html")
    }

    func testSingleVideo() throws {
        try assertMatchesManifest("threads_single_video.html")
    }

    func testMixedCarouselKeepsOrderAndTakesTheVideoNotItsCover() throws {
        try assertMatchesManifest("threads_mixed_carousel.html")
    }

    func testReplyYieldsOnlyItsOwnImage() throws {
        try assertMatchesManifest("threads_reply_with_image.html")
    }

    // MARK: - Posts without media of their own

    func testTextOnlyPostHasNoMedia() throws {
        try assertMatchesManifest("threads_text_only.html")
    }

    func testGifPlaceholderCountsAsNoMedia() throws {
        try assertMatchesManifest("threads_gif_placeholder.html")
    }

    func testLinkCardAloneIsNotMedia() throws {
        try assertMatchesManifest("threads_link_card_only.html")
    }

    func testQuoteFallsBackToTheQuotedPostsVideo() throws {
        try assertMatchesManifest("threads_quote_with_video.html")
    }

    func testLinkedInlineVideoIsAttributedToItsOriginalAuthor() throws {
        // A text post whose only video sits under an Instagram link card.
        try assertMatchesManifest("threads_linked_inline_video.html")
        guard case .success(let post) = try resolve(expectation(for: "threads_linked_inline_video.html")) else {
            return XCTFail("expected media")
        }
        XCTAssertEqual(post.media.count, 1)
        XCTAssertEqual(post.media.first?.kind, .video)
        XCTAssertEqual(post.source, .linkedInlineMedia)
        XCTAssertEqual(post.author, "Reel Maker")
        XCTAssertEqual(post.text, "Synthetic reel caption")
        XCTAssertEqual(
            ThreadsService.fileStem(author: post.author, text: post.text, code: post.code),
            "Reel Maker - Synthetic reel caption [SYNreel00001]")
    }

    // MARK: - Failure pages

    func testRestrictedAudiencePage() throws {
        try assertMatchesManifest("threads_fail_restricted_audience.html")
    }

    func testNotFoundRedirectNeverYieldsTheFeedsMedia() throws {
        // The redirect lands on the logged-out feed, full of strangers' videos.
        try assertMatchesManifest("threads_fail_not_found_invalid_post.html")
    }

    func testBlockedShellPage() throws {
        try assertMatchesManifest("threads_fail_blocked_shell_404.html")
    }

    func testLoginRedirect() throws {
        try assertMatchesManifest("threads_fail_login_redirect.html")
    }

    func testClassifyFailureOrder() {
        let geo = "<html>BarcelonaGeoBlockedErrorRoot initialRouteInfo</html>"
        let shell = "<html>Barcelona404ErrorRoot</html>"
        let post = URL(string: "https://www.threads.com/@example_author/post/SYNimage0001")
        // The final address outranks anything in the page.
        XCTAssertEqual(
            ThreadsService.classifyFailure(finalURL: URL(string: "https://www.threads.com/?error=invalid_post"), html: geo), .notFound)
        XCTAssertEqual(
            ThreadsService.classifyFailure(finalURL: URL(string: "https://www.threads.com/login/?next=x"), html: geo), .loginRequired)
        XCTAssertEqual(ThreadsService.classifyFailure(finalURL: post, html: geo + shell), .restricted)
        XCTAssertEqual(ThreadsService.classifyFailure(finalURL: post, html: shell), .blockedShell)
        // With route information the 404 component is an ordinary part of the page.
        XCTAssertEqual(ThreadsService.classifyFailure(finalURL: post, html: shell + "initialRouteInfo"), .noPostData)
        XCTAssertEqual(ThreadsService.classifyFailure(finalURL: nil, html: ""), .noPostData)
    }

    func testClassifyFailureIgnoresVisibleText() {
        // The same page in another language, or with the English notice
        // pasted into an ordinary page, must classify on the component name.
        let post = URL(string: "https://www.threads.com/@example_author/post/SYNimage0001")
        XCTAssertEqual(
            ThreadsService.classifyFailure(finalURL: post, html: "<html>BarcelonaGeoBlockedErrorRoot 無法顯示串文</html>"), .restricted)
        XCTAssertEqual(
            ThreadsService.classifyFailure(
                finalURL: post, html: "<html>initialRouteInfo This content isn't available to everyone. Thread not available</html>"),
            .noPostData)
    }

    // MARK: - Decoy guard

    func testNoFixtureYieldsDecoyMedia() throws {
        let manifest = try JSONDecoder().decode([Expectation].self, from: Data(contentsOf: fixtureURL("manifest.json")))
        for expected in manifest {
            let html = try String(contentsOf: fixtureURL(expected.fixture), encoding: .utf8)
            guard html.contains("decoy") else { continue }
            if case .success(let post) = try resolve(expected) {
                XCTAssertFalse(post.media.contains { $0.url.absoluteString.contains("decoy") }, expected.fixture)
                XCTAssertFalse(post.author.contains("Third Party"), expected.fixture)
            }
        }
    }

    func testQuotedCopyOfTheTargetInRelatedPostsIsNotTheTarget() throws {
        // In this page a related post quotes the target, so the target's
        // code appears in an EARLIER script tag, on an object with a user
        // and with an image the real post doesn't have. A search for the
        // first object carrying the code would return that copy.
        let html = try String(contentsOf: fixtureURL("threads_linked_inline_video.html"), encoding: .utf8)
        let copy = try XCTUnwrap(html.range(of: "img_SYNdecoyQcp1"))
        let target = try XCTUnwrap(html.range(of: "BarcelonaPostPageTargetQuery"))
        XCTAssertLessThan(copy.lowerBound, target.lowerBound)

        let post = try XCTUnwrap(ThreadsService.findTarget(html: html, code: "SYNlinked001"))
        XCTAssertEqual(post["media_type"] as? Int, 19)
        XCTAssertTrue(ThreadsService.mediaOf(post).isEmpty)
    }

    func testFindTargetRequiresTheLinksCode() throws {
        let html = try String(contentsOf: fixtureURL("threads_single_image.html"), encoding: .utf8)
        XCTAssertNotNil(ThreadsService.findTarget(html: html, code: "SYNimage0001"))
        // Decoys are full posts with users, but none sits at data.media.
        XCTAssertNil(ThreadsService.findTarget(html: html, code: "SYNdecoyRel1"))
        XCTAssertNil(ThreadsService.findTarget(html: html, code: "SYNdecoyRpl1"))
        XCTAssertNil(ThreadsService.findTarget(html: html, code: "SYNabsent001"))
    }

    // MARK: - Fallback chain and media rules

    private func node(
        code: String, name: String?, username: String, image: String? = nil, video: String? = nil, extra: [String: Any] = [:]
    ) -> [String: Any] {
        var node: [String: Any] = [
            "code": code,
            "user": ["full_name": name as Any, "username": username],
            "caption": ["text": "caption of \(code)"],
            "original_width": 100, "original_height": 50,
            "image_versions2": ["candidates": image.map { [["url": $0, "width": 100, "height": 50]] } ?? []],
        ]
        if let video { node["video_versions"] = [["type": 101, "url": video]] }
        node.merge(extra) { $1 }
        return node
    }

    func testOwnMediaWinsOverQuotedMedia() throws {
        let quoted = node(code: "SYNq0000001", name: "Other Person", username: "other_person", video: "https://example.invalid/q.mp4")
        let post = node(
            code: "SYNp0000001", name: "Example Author", username: "example_author", image: "https://example.invalid/own.jpg",
            extra: ["text_post_app_info": ["share_info": ["quoted_post": quoted]]])
        let resolved = try XCTUnwrap(ThreadsService.resolveMedia(in: post, linkCode: "SYNp0000001"))
        XCTAssertEqual(resolved.source, .post)
        XCTAssertEqual(resolved.author, "Example Author")
        XCTAssertEqual(resolved.media.map(\.url.absoluteString), ["https://example.invalid/own.jpg"])
    }

    func testFallbackOrderIsQuotedThenRepostedThenLinked() throws {
        let quoted = node(code: "SYNq0000001", name: "Quoted", username: "quoted", image: "https://example.invalid/q.jpg")
        let reposted = node(code: "SYNr0000001", name: "Reposted", username: "reposted", image: "https://example.invalid/r.jpg")
        let linked = node(code: "SYNl0000001", name: "Linked", username: "linked", image: "https://example.invalid/l.jpg")
        let emptyQuoted = node(code: "SYNq0000002", name: "Quoted", username: "quoted")

        func post(quoted: [String: Any]?, reposted: [String: Any]?, linked: [String: Any]?) -> [String: Any] {
            var share: [String: Any] = [:]
            share["quoted_post"] = quoted as Any? ?? NSNull()
            share["reposted_post"] = reposted as Any? ?? NSNull()
            return node(
                code: "SYNp0000001", name: "Example Author", username: "example_author",
                extra: ["text_post_app_info": ["share_info": share, "linked_inline_media": linked as Any? ?? NSNull()]])
        }

        let all = try XCTUnwrap(ThreadsService.resolveMedia(in: post(quoted: quoted, reposted: reposted, linked: linked), linkCode: "x"))
        XCTAssertEqual(all.source, .quotedPost)
        XCTAssertEqual(all.author, "Quoted")
        XCTAssertEqual(all.code, "SYNq0000001")
        XCTAssertEqual(all.text, "caption of SYNq0000001")

        let repost = try XCTUnwrap(ThreadsService.resolveMedia(in: post(quoted: nil, reposted: reposted, linked: linked), linkCode: "x"))
        XCTAssertEqual(repost.source, .repostedPost)
        XCTAssertEqual(repost.author, "Reposted")

        // A quoted post that is itself text-only doesn't end the search.
        let link = try XCTUnwrap(ThreadsService.resolveMedia(in: post(quoted: emptyQuoted, reposted: nil, linked: linked), linkCode: "x"))
        XCTAssertEqual(link.source, .linkedInlineMedia)
        XCTAssertEqual(link.author, "Linked")

        XCTAssertNil(ThreadsService.resolveMedia(in: post(quoted: emptyQuoted, reposted: nil, linked: nil), linkCode: "x"))
    }

    func testAuthorFallsBackToUsernameThenToASiteName() throws {
        let noName = node(code: "SYNp0000001", name: nil, username: "example_author", image: "https://example.invalid/a.jpg")
        XCTAssertEqual(ThreadsService.resolveMedia(in: noName, linkCode: "x")?.author, "example_author")
        let blankName = node(code: "SYNp0000001", name: "  ", username: "example_author", image: "https://example.invalid/a.jpg")
        XCTAssertEqual(ThreadsService.resolveMedia(in: blankName, linkCode: "x")?.author, "example_author")
        var noUser = noName
        noUser["user"] = nil
        noUser["caption"] = NSNull()
        noUser["code"] = nil
        let resolved = try XCTUnwrap(ThreadsService.resolveMedia(in: noUser, linkCode: "SYNlink0001"))
        XCTAssertEqual(resolved.author, "threads")
        XCTAssertEqual(resolved.text, "")
        XCTAssertEqual(resolved.code, "SYNlink0001")
    }

    func testImagePickIsTheOriginalSizeNotTheFirstOrASquareCrop() {
        let candidates: [[String: Any]] = [
            ["url": "https://example.invalid/crop.jpg", "width": 1500, "height": 1500],
            ["url": "https://example.invalid/small.jpg", "width": 720, "height": 540],
            ["url": "https://example.invalid/original.jpg", "width": 1440, "height": 1080],
        ]
        let node: [String: Any] = ["image_versions2": ["candidates": candidates], "original_width": 1440, "original_height": 1080]
        XCTAssertEqual(ThreadsService.mediaOf(node).map(\.url.absoluteString), ["https://example.invalid/original.jpg"])

        // No candidate has the stated size: the largest by area.
        let unmatched: [String: Any] = ["image_versions2": ["candidates": candidates], "original_width": 4000, "original_height": 3000]
        XCTAssertEqual(ThreadsService.mediaOf(unmatched).map(\.url.absoluteString), ["https://example.invalid/crop.jpg"])
    }

    func testVideoEntryWithoutAddressIsSkipped() {
        let node: [String: Any] = [
            "video_versions": [["type": 101], ["type": 102, "url": ""], ["type": 103, "url": "https://example.invalid/v.mp4"]]
        ]
        XCTAssertEqual(
            ThreadsService.mediaOf(node),
            [ThreadsService.Media(kind: .video, url: URL(string: "https://example.invalid/v.mp4")!, width: nil, height: nil)])
    }

    // MARK: - Link parsing

    func testParseLinkTable() {
        typealias Link = ThreadsService.PostLink
        let cases: [(link: String, expected: Link?)] = [
            ("https://www.threads.com/@example_author/post/SYNimage0001", Link(username: "example_author", code: "SYNimage0001")),
            ("https://threads.com/@example_author/post/SYNimage0001", Link(username: "example_author", code: "SYNimage0001")),
            ("https://www.threads.net/@example_author/post/SYNimage0001", Link(username: "example_author", code: "SYNimage0001")),
            ("http://threads.net/@example_author/post/SYNimage0001/", Link(username: "example_author", code: "SYNimage0001")),
            ("https://WWW.THREADS.COM/@Example.Author/post/SYN-im_g001", Link(username: "Example.Author", code: "SYN-im_g001")),
            // No "@": still a post.
            ("https://www.threads.com/example_author/post/SYNimage0001", Link(username: "example_author", code: "SYNimage0001")),
            // The username is kept as written even when it may be the wrong
            // one — the server redirects to the owner.
            ("https://www.threads.com/@someone_else/post/SYNimage0001", Link(username: "someone_else", code: "SYNimage0001")),
            // A username that looks like another site's address.
            ("https://www.threads.com/@fox.com/post/SYNimage0001", Link(username: "fox.com", code: "SYNimage0001")),
            ("https://www.threads.com/t/SYNimage0001", Link(username: nil, code: "SYNimage0001")),
            ("https://threads.net/t/SYNimage0001/", Link(username: nil, code: "SYNimage0001")),
            ("https://www.threads.com/@example_author/post/SYNimage0001/media", Link(username: "example_author", code: "SYNimage0001")),
            ("https://www.threads.com/@example_author/post/SYNimage0001/embed", Link(username: "example_author", code: "SYNimage0001")),
            ("https://www.threads.com/@example_author/post/SYNimage0001/embed/", Link(username: "example_author", code: "SYNimage0001")),
            (
                "https://www.threads.net/@example_author/post/SYNimage0001/?xmt=AQF0abc&slof=1&igshid=abc",
                Link(username: "example_author", code: "SYNimage0001")
            ),
            ("  https://www.threads.com/@example_author/post/SYNimage0001\n", Link(username: "example_author", code: "SYNimage0001")),
            // Threads, but not a single post.
            ("https://www.threads.com/@example_author", nil),
            ("https://www.threads.com/@example_author/", nil),
            ("https://www.threads.com/@example_author/replies", nil),
            ("https://www.threads.com/@example_author/post/", nil),
            ("https://www.threads.com/@example_author/post/abc", nil),
            ("https://www.threads.com/@example_author/post/SYNimage0001/likes", nil),
            ("https://www.threads.com/", nil),
            ("https://www.threads.com/search?q=SYNimage0001", nil),
            ("https://www.threads.com/?error=invalid_post", nil),
            ("https://www.threads.com/login/?next=x", nil),
            // Not Threads at all.
            ("https://www.instagram.com/p/SYNimage0001/", nil),
            ("https://somethreads.com/@example_author/post/SYNimage0001", nil),
            ("https://threads.com.example.invalid/@example_author/post/SYNimage0001", nil),
            ("https://example.invalid/?u=https://www.threads.com/@example_author/post/SYNimage0001", nil),
            ("https://example.invalid/www.threads.com/@example_author/post/SYNimage0001", nil),
            ("ftp://www.threads.com/@example_author/post/SYNimage0001", nil),
            ("threads.com/@example_author/post/SYNimage0001", nil),
            ("", nil),
        ]
        for c in cases {
            XCTAssertEqual(ThreadsService.parseLink(c.link), c.expected, c.link)
        }
    }

    func testCanonicalURLDropsEverythingButUserAndCode() throws {
        let cases: [(link: String, canonical: String)] = [
            (
                "http://threads.net/@example_author/post/SYNimage0001/media?xmt=AQF0abc&slof=1",
                "https://www.threads.com/@example_author/post/SYNimage0001"
            ),
            ("https://www.threads.com/example_author/post/SYNimage0001/", "https://www.threads.com/@example_author/post/SYNimage0001"),
            ("https://threads.net/t/SYNimage0001/?igshid=abc", "https://www.threads.com/t/SYNimage0001"),
        ]
        for c in cases {
            let link = try XCTUnwrap(ThreadsService.parseLink(c.link), c.link)
            XCTAssertEqual(ThreadsService.canonicalURL(for: link)?.absoluteString, c.canonical)
        }
    }

    // MARK: - File names

    func testFileStemMatchesTheShapeOfXDownloads() {
        XCTAssertEqual(
            ThreadsService.fileStem(author: "Example Author", text: "Synthetic single image post", code: "SYNimage0001"),
            "Example Author - Synthetic single image post [SYNimage0001]")
        // Same sanitizing as X: separators and line breaks can't reach the file system.
        XCTAssertEqual(
            ThreadsService.fileStem(author: "A/B", text: "line one\nline two", code: "SYNimage0001"),
            "A_B - line one line two [SYNimage0001]")
        // No text: the code alone keeps posts by one author apart.
        XCTAssertEqual(ThreadsService.fileStem(author: "Example Author", text: "", code: "SYNimage0001"), "Example Author -  [SYNimage0001]")
    }

    func testFileStemCutsTheTextAt100Characters() {
        // Characters, not bytes: "é" is one character and two bytes.
        let text = String(repeating: "é", count: 99) + "ab"
        XCTAssertEqual(
            ThreadsService.fileStem(author: "Example Author", text: text, code: "SYNimage0001"),
            "Example Author - " + String(repeating: "é", count: 99) + "a [SYNimage0001]")
    }

    func testFileStemFitsAFileNameWhateverTheScript() {
        // 100 Chinese characters are 300 bytes, more than a file name holds:
        // cut at 100 characters only, the file could never be saved.
        let text = String(repeating: "字", count: 150)
        let stem = ThreadsService.fileStem(author: "Example Author", text: text, code: "SYNimage0001")
        XCTAssertLessThanOrEqual(stem.utf8.count, ThreadsService.maxStemBytes)
        XCTAssertLessThanOrEqual(ThreadsService.fileName(stem: stem, index: 98, count: 99, fileExtension: "webp").utf8.count, 255)
        XCTAssertTrue(stem.hasPrefix("Example Author - 字字字"))
        XCTAssertTrue(stem.hasSuffix("字 [SYNimage0001]"), "the code must survive the cut")
        // As much of the text as fits, not a fixed shorter cut.
        XCTAssertGreaterThan(stem.utf8.count, ThreadsService.maxStemBytes - 3)
    }

    func testFileNameNumbersOnlyMultiFilePosts() {
        let stem = "Example Author - text [SYNimage0001]"
        XCTAssertEqual(
            ThreadsService.fileName(stem: stem, index: 0, count: 1, fileExtension: "mp4"), "Example Author - text [SYNimage0001].mp4")
        XCTAssertEqual(
            ThreadsService.fileName(stem: stem, index: 0, count: 3, fileExtension: "jpg"), "Example Author - text [SYNimage0001] #1.jpg")
        XCTAssertEqual(
            ThreadsService.fileName(stem: stem, index: 2, count: 3, fileExtension: "webp"), "Example Author - text [SYNimage0001] #3.webp")
    }

    func testDisplayTitleIsTheStemWithoutItsCode() {
        XCTAssertEqual(ThreadsService.displayTitle(author: "Example Author", text: "line one\nline two"), "Example Author - line one line two")
        XCTAssertEqual(ThreadsService.displayTitle(author: "Example Author", text: ""), "Example Author")
        // Agrees with what the X title cleanup makes of the same file name
        // for a real 11-character code.
        let stem = ThreadsService.fileStem(author: "Example Author", text: "some text", code: "SYN_code-01")
        let name = ThreadsService.fileName(stem: stem, index: 1, count: 2, fileExtension: "jpg")
        XCTAssertEqual(
            GalleryDlService.displayTitle(forPath: "/out/" + name), ThreadsService.displayTitle(author: "Example Author", text: "some text"))
    }

    // MARK: - Messages

    func testMessageConstantsAreTheLiteralCopy() {
        XCTAssertEqual(
            ThreadsService.notAPostLinkMessage,
            "This Threads link isn't a single post — open the post on threads.com and paste its own link instead.")
        XCTAssertEqual(
            ThreadsService.notFoundMessage,
            "Threads post not found — it may be deleted, or the link may be incomplete; check the link, then Retry.")
        XCTAssertEqual(
            ThreadsService.loginRequiredMessage,
            "This post needs sign-in at threads.com — XDownloader can't download signed-in Threads posts yet, so Retry won't help for now.")
        XCTAssertEqual(
            ThreadsService.restrictedMessage,
            "Threads limits who can see this post — it needs sign-in at threads.com, which XDownloader can't use yet, "
                + "so Retry won't help for now.")
        XCTAssertEqual(
            ThreadsService.blockedShellMessage,
            "Threads returned an empty page — the link may be malformed, or Threads changed its site; check the link, then Retry.")
        XCTAssertEqual(
            ThreadsService.noPostDataMessage,
            "Threads sent the page without the post's data — wait a moment, then Retry. If it persists, Threads may have changed its site.")
        XCTAssertEqual(
            ThreadsService.noMediaMessage,
            "No photo or video in this Threads post — text, link cards and GIFs can't be downloaded.")
    }

    func testEveryFailureHasItsOwnMessage() {
        let messages = ThreadsService.Failure.allCases.map(ThreadsService.message(for:))
        XCTAssertEqual(Set(messages).count, ThreadsService.Failure.allCases.count)
        XCTAssertEqual(ThreadsService.message(for: .restricted), ThreadsService.restrictedMessage)
        XCTAssertEqual(ThreadsService.message(for: .loginRequired), ThreadsService.loginRequiredMessage)
        XCTAssertEqual(ThreadsService.message(for: .notFound), ThreadsService.notFoundMessage)
        XCTAssertEqual(ThreadsService.message(for: .blockedShell), ThreadsService.blockedShellMessage)
        XCTAssertEqual(ThreadsService.message(for: .noPostData), ThreadsService.noPostDataMessage)
        XCTAssertEqual(ThreadsService.message(for: .noMedia), ThreadsService.noMediaMessage)
        // Both sign-in failures name the site to sign in to, and neither
        // sends the owner to Settings → Cookies: this build reads no cookies.
        for message in [ThreadsService.restrictedMessage, ThreadsService.loginRequiredMessage] {
            XCTAssertTrue(message.contains("sign-in at threads.com"))
            XCTAssertFalse(message.contains("Settings"))
        }
    }
}
