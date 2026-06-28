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

    func testCapabilityFlags() {
        let yt = SiteRegistry.profile(for: "https://www.youtube.com/watch?v=x")
        XCTAssertTrue(yt.supportsSubtitles)
        XCTAssertTrue(yt.usesYouTubeFormatSelector)

        let tw = SiteRegistry.profile(for: "https://x.com/a")
        XCTAssertFalse(tw.supportsSubtitles)
        XCTAssertFalse(tw.usesYouTubeFormatSelector)
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
