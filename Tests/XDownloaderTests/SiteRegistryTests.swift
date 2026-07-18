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

    /// Instagram: yt-dlp first (videos/Reels), gallery-dl only fallback (image
    /// and carousel posts); no YouTube-style capabilities.
    func testInstagramProfileDeclaration() {
        let ig = SiteRegistry.instagram
        XCTAssertEqual(ig.fallbacks, [.galleryDl])
        XCTAssertFalse(ig.supportsSubtitles)
        XCTAssertFalse(ig.usesYouTubeFormatSelector)
        XCTAssertFalse(ig.detectsExternalRedirect)
        XCTAssertEqual(ig.outputTemplateSuffix, "")
    }

    /// `GalleryDlService.run` appends the matched profile's `galleryDlArgs`
    /// verbatim, so the declaration is the command line.
    func testInstagramGalleryDlArgs() {
        let args = SiteRegistry.profile(for: "https://www.instagram.com/p/Daoe_4TTVY0/").galleryDlArgs
        XCTAssertEqual(
            args,
            ["-f", "{username} - {description!s:.100} [{post_shortcode}] #{num}.{extension}"])
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
