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

    /// Threads is matched by HOST. The other profiles match by substring,
    /// which is why `threads` leads the registry: "/@fox.com/post/…"
    /// contains "x.com/".
    func testThreadsProfileMatching() {
        let threads = [
            "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK",
            "https://www.threads.net/@user/post/CODE",
            "https://threads.net/t/CODE",
            "https://WWW.THREADS.COM/@a/post/B",
            "https://www.threads.com/@fox.com/post/CODE",
            "https://www.threads.com/@netflix.com/post/CODE",
            "https://www.threads.com/@user/post/CODE/media",
            "https://www.threads.com/@user/post/CODE?xmt=AQF0abc&slof=1",
            // Not a post, but still this site's to turn down.
            "https://www.threads.com/@someone.invented",
        ]
        for link in threads {
            XCTAssertEqual(SiteRegistry.profile(for: link).id, "threads", link)
        }

        let other = [
            // A look-alike domain.
            "https://somethreads.com/a",
            "https://threads.com.example.org/@a/post/B",
            // A Threads link carried in another site's query string.
            "https://example.com/?u=https://www.threads.com/@a/post/B",
            "https://example.com/threads.com/@a/post/B",
        ]
        for link in other {
            XCTAssertEqual(SiteRegistry.profile(for: link).id, "other", link)
        }

        XCTAssertEqual(SiteRegistry.profile(for: "https://x.com/a/status/1").id, "twitter")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.instagram.com/p/Daoe_4TTVY0/").id, "instagram")
    }

    func testThreadsLeadsTheRegistryAndTheCatchAllEndsIt() {
        XCTAssertEqual(SiteRegistry.all.first?.id, "threads")
        XCTAssertEqual(SiteRegistry.all.last?.id, "other")
        XCTAssertEqual(SiteRegistry.all.map(\.id), ["threads", "dmm", "twitter", "youtube", "reddit", "instagram", "other"])
    }

    /// Work pages are matched by the exact HOST. Everything else of the
    /// domain — the direct preview file links above all — stays with the
    /// generic profile, where it has always downloaded.
    func testDmmProfileMatching() {
        let pages = [
            "https://video.dmm.co.jp/cinema/content/?id=test00123",
            "https://video.dmm.co.jp/anime/content/?id=test00123",
            "https://video.dmm.co.jp/anime/content/?id=test00123",
            "https://video.dmm.co.jp/cinema/content/?id=test00123",
            "https://video.dmm.co.jp/cinema/content?id=test00123",
            "http://video.dmm.co.jp/cinema/content/?id=test00123",
            "https://VIDEO.DMM.CO.JP/cinema/content/?id=TEST00123",
            "https://video.dmm.co.jp/cinema/content/?id=test00123&utm_source=share",
            // Text another profile's substring test would claim.
            "https://video.dmm.co.jp/cinema/content/?id=test00123&from=x.com/a",
            // Not a work page, but still this site's to turn down.
            "https://video.dmm.co.jp/cinema/list/",
            "https://video.dmm.co.jp/",
        ]
        for link in pages {
            XCTAssertEqual(SiteRegistry.profile(for: link).id, "dmm", link)
        }

        let generic = [
            // Direct preview file links, in both container forms.
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAAAAAAAAAAAAAAAAAA/test00123hhb.mp4",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenBBBBBBBBBBBBBBBBBBBB/playlist.m3u8",
            // Other hosts of the domain.
            "https://www.dmm.co.jp/digital/video/-/detail/=/cid=test00123/",
            "https://pics.dmm.co.jp/digital/video/test00123/test00123pl.jpg",
            "https://api.video.dmm.co.jp/graphql",
            "https://dmm.co.jp/",
            // The wrapper link as such; capture unwraps it.
            "https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fcinema%2Fcontent%2F%3Fid%3Dtest00123",
            // The general-audience sister domain.
            "https://www.dmm.com/",
            "https://tv.dmm.com/vod/detail/?season=test00123",
            "https://video.dmm.com/cinema/content/?id=test00123",
            // Look-alike domains.
            "https://video.dmm.co.jp.example.com/cinema/content/?id=test00123",
            "https://notvideo.dmm.co.jp/cinema/content/?id=test00123",
            "https://video-dmm.co.jp/cinema/content/?id=test00123",
            // A work page link carried inside another site's link.
            "https://example.com/?u=https://video.dmm.co.jp/cinema/content/?id=test00123",
            "https://example.com/video.dmm.co.jp/cinema/content/?id=test00123",
            // Not a web link.
            "ftp://video.dmm.co.jp/cinema/content/?id=test00123",
        ]
        for link in generic {
            XCTAssertEqual(SiteRegistry.profile(for: link).id, "other", link)
        }

        XCTAssertEqual(SiteRegistry.profile(for: "https://x.com/a/status/1").id, "twitter")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.youtube.com/watch?v=x").id, "youtube")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.reddit.com/r/x/comments/y").id, "reddit")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.instagram.com/p/Daoe_4TTVY0/").id, "instagram")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK").id, "threads")
    }

    /// The preview clip is resolved first and yt-dlp downloads it, logged
    /// out: no fallback, no sweep, nothing of the browser login.
    func testDmmProfileDeclaration() {
        let dmm = SiteRegistry.dmm
        XCTAssertTrue(dmm.usesYtDlp)
        XCTAssertTrue(dmm.resolvesAddressBeforeDownload)
        XCTAssertFalse(dmm.receivesBrowserCookies)
        XCTAssertEqual(dmm.fallbacks, [])
        XCTAssertNil(dmm.imageSweepArgs)
        XCTAssertEqual(dmm.galleryDlArgs, [])
        XCTAssertEqual(dmm.outputTemplateSuffix, "")
        XCTAssertFalse(dmm.supportsSubtitles)
        XCTAssertFalse(dmm.usesYouTubeFormatSelector)
        XCTAssertFalse(dmm.detectsExternalRedirect)
    }

    /// The two new members are off for every profile that was there before.
    func testEveryOtherProfileResolvesNothingAndStillSendsCookies() {
        for profile in SiteRegistry.all where profile.id != "dmm" {
            XCTAssertFalse(profile.resolvesAddressBeforeDownload, profile.id)
            XCTAssertTrue(profile.receivesBrowserCookies, profile.id)
        }
    }

    /// Threads: the in-app resolver is the only downloader. yt-dlp has no
    /// extractor for the site, so it is skipped; no external tool is involved
    /// and there is no photo sweep to run.
    func testThreadsProfileDeclaration() {
        let threads = SiteRegistry.threads
        XCTAssertEqual(threads.fallbacks, [.threads])
        XCTAssertFalse(threads.usesYtDlp)
        XCTAssertNil(threads.imageSweepArgs)
        XCTAssertEqual(threads.galleryDlArgs, [])
        XCTAssertEqual(threads.outputTemplateSuffix, "")
        XCTAssertFalse(threads.supportsSubtitles)
        XCTAssertFalse(threads.usesYouTubeFormatSelector)
        XCTAssertFalse(threads.extractorTitleIncludesUploader)
        XCTAssertFalse(threads.detectsExternalRedirect)
    }

    func testEveryOtherProfileStillRunsYtDlp() {
        for profile in SiteRegistry.all where profile.id != "threads" {
            XCTAssertTrue(profile.usesYtDlp, profile.id)
        }
    }

    /// A site that skips yt-dlp has only its fallbacks. If all of them were
    /// external tools, a Mac without those tools could never download the
    /// site, and the run would end with no downloader having run at all.
    func testEverySiteThatSkipsYtDlpHasAFallbackNeedingNoExternalTool() {
        for profile in SiteRegistry.all where !profile.usesYtDlp {
            XCTAssertTrue(profile.fallbacks.contains { !$0.needsExternalTool }, profile.id)
        }
        XCTAssertTrue(SiteProfile.Fallback.galleryDl.needsExternalTool)
        XCTAssertFalse(SiteProfile.Fallback.fxTwitter.needsExternalTool)
        XCTAssertFalse(SiteProfile.Fallback.threads.needsExternalTool)
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
