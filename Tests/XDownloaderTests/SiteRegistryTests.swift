import XCTest

@testable import XDownloader

/// `SiteRegistry` is the single source of truth for per-site behavior. First
/// match wins; the `other` profile is the catch-all.
@MainActor
final class SiteRegistryTests: XCTestCase {

    func testProfileMatching() {
        XCTAssertEqual(SiteRegistry.profile(for: "https://x.com/a/status/1").id, "twitter")
        XCTAssertEqual(SiteRegistry.profile(for: "https://twitter.com/a").id, "twitter")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.youtube.com/watch?v=x").id, "youtube")
        XCTAssertEqual(SiteRegistry.profile(for: "https://youtu.be/x").id, "youtube")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.reddit.com/r/x/comments/y").id, "reddit")
        XCTAssertEqual(SiteRegistry.profile(for: "https://example.com/p").id, "other")
    }

    func testInstagramProfileMatching() {
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.instagram.com/p/Daoe_4TTVY0/").id, "instagram")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.instagram.com/reel/Cxyz12345Ab/").id, "instagram")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.instagram.com/stories/user/123/").id, "instagram")
        XCTAssertEqual(SiteRegistry.profile(for: "https://instagr.am/p/Daoe_4TTVY0/").id, "instagram")
    }

    func testCapabilityFlags() {
        let yt = SiteRegistry.profile(for: "https://www.youtube.com/watch?v=x")
        XCTAssertTrue(yt.supportsSubtitles)
        XCTAssertTrue(yt.usesYouTubeFormatSelector)

        let tw = SiteRegistry.profile(for: "https://x.com/a")
        XCTAssertFalse(tw.supportsSubtitles)
        XCTAssertFalse(tw.usesYouTubeFormatSelector)
    }

    /// Twitter's suffix must use the same `{0}` replacement syntax as
    /// Instagram's: the nested %(playlist_index)02d form has never been valid
    /// on yt-dlp's template engine — it corrupts to null bytes and failed
    /// EVERY tweet at filename preparation, silently routing all Twitter
    /// traffic to the gallery-dl fallback. The extractor bakes the author into
    /// %(title)s, and the sweep keeps mixed-post photos from vanishing now
    /// that yt-dlp successes are real.
    func testTwitterProfileDeclaration() {
        let tw = SiteRegistry.twitter
        XCTAssertEqual(tw.outputTemplateSuffix, "%(playlist_index& [{0:02d}]|)s")
        XCTAssertTrue(tw.extractorTitleIncludesUploader)
        XCTAssertEqual(tw.imageSweepArgs, ["-o", "videos=false"])
    }

    /// Instagram: yt-dlp first (videos/Reels), gallery-dl only fallback (image
    /// and mixed carousel posts); no YouTube-style capabilities. The playlist
    /// suffix keeps carousel video entries (which share one post-level title)
    /// from colliding on a single filename and being skipped as "already
    /// downloaded"; it must use the `{0}` replacement syntax — nested %(...)fmt
    /// corrupts to null bytes and fails the whole download.
    func testInstagramProfileDeclaration() {
        let ig = SiteRegistry.instagram
        XCTAssertEqual(ig.fallbacks, [.galleryDl])
        XCTAssertFalse(ig.supportsSubtitles)
        XCTAssertFalse(ig.usesYouTubeFormatSelector)
        XCTAssertFalse(ig.detectsExternalRedirect)
        XCTAssertEqual(ig.outputTemplateSuffix, "%(playlist_index& [{0:02d}]|)s")
        XCTAssertFalse(ig.extractorTitleIncludesUploader)
        XCTAssertEqual(ig.imageSweepArgs, ["-o", "videos=false"])
    }

    /// The sweep's extra args slot in AFTER the profile's own gallery-dl args
    /// (so `-o videos=false` overrides any per-site option default) and before
    /// the trailing URL.
    func testImageSweepArgumentOrder() {
        let args = GalleryDlService.arguments(
            for: "https://x.com/u/status/1",
            outputDirectory: URL(fileURLWithPath: "/out"),
            cookieBrowser: .none, cookiesFile: nil,
            extraArgs: ["-o", "videos=false"])
        XCTAssertEqual(args.last, "https://x.com/u/status/1")
        let sweep = args.lastIndex(of: "videos=false")!
        let filename = args.firstIndex(of: "{author[nick]} - {content!s:.100} [{tweet_id}] #{num}.{extension}")!
        XCTAssertTrue(filename < sweep)
    }

    /// `GalleryDlService.run` appends the matched profile's `galleryDlArgs`
    /// verbatim, so the declaration is the command line. `{description|''}`
    /// substitutes an empty string for stories/highlights, which never carry a
    /// description — without it the filename gets a literal "None".
    func testInstagramGalleryDlArgs() {
        let args = SiteRegistry.profile(for: "https://www.instagram.com/p/Daoe_4TTVY0/").galleryDlArgs
        XCTAssertEqual(
            args,
            ["-f", "{username} - {description|''!s:.100} [{post_shortcode}] #{num}.{extension}"])
    }

    /// `isTwitterContent` is broader than `twitter.matches` — it also covers the
    /// twimg.com CDN, used to detect yt-dlp redirecting out of a tweet.
    func testIsTwitterContent() {
        XCTAssertTrue(SiteRegistry.isTwitterContent("https://x.com/a"))
        XCTAssertTrue(SiteRegistry.isTwitterContent("https://twitter.com/a"))
        XCTAssertTrue(SiteRegistry.isTwitterContent("https://pbs.twimg.com/media/x.jpg"))
        XCTAssertFalse(SiteRegistry.isTwitterContent("https://www.youtube.com/x"))
    }
}
