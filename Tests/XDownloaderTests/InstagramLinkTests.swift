import XCTest

@testable import XDownloader

/// `InstagramLink`'s rules: which links name one post, reel or story, which
/// name a profile and download its newest posts, which name another tab, a
/// collection or a page of the site and are turned down, and which are not
/// Instagram page links at all. Every username, code and id here is
/// invented.
@MainActor
final class InstagramLinkTests: XCTestCase {

    private typealias Shape = InstagramLink.Shape

    func testShapeTable() {
        let cases: [(link: String, expected: Shape)] = [
            // The basic shapes: posts, reels, share forms, stories, profiles,
            // profile tabs, pages of the site.
            ("https://www.instagram.com/p/SYNpost0001_/", .singleItem),
            ("https://www.instagram.com/p/SYNpost0001_/?img_index=2", .singleItem),
            ("https://www.instagram.com/reel/SYNreel0001_/", .singleItem),
            ("https://www.instagram.com/reels/SYNreel0001_/", .singleItem),
            ("https://www.instagram.com/tv/SYNvideo001_/", .singleItem),
            ("https://www.instagram.com/share/p/SYNshare01/", .singleItem),
            ("https://www.instagram.com/share/reel/SYNshare01/", .singleItem),
            ("https://www.instagram.com/share/SYNshare01/", .singleItem),
            ("https://www.instagram.com/stories/someone.invented/3456789012345678901/", .singleItem),
            ("https://www.instagram.com/stories/someone.invented/", .notASingleItem),
            ("https://www.instagram.com/stories/highlights/17900000000000000/", .notASingleItem),
            ("https://www.instagram.com/s/aGlnaGxpZ2h0OjE3OTAwMDAwMDAwMDAwMDAw", .notASingleItem),
            ("https://www.instagram.com/someone.invented/", .profile(username: "someone.invented")),
            ("https://www.instagram.com/someone.invented", .profile(username: "someone.invented")),
            ("https://www.instagram.com/someone.invented/reels/", .profile(username: "someone.invented")),
            ("https://www.instagram.com/someone.invented/tagged/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/p/SYNpost0001_/", .singleItem),
            ("https://www.instagram.com/someone.invented/reel/SYNreel0001_/", .singleItem),
            ("https://instagram.com/p/SYNpost0001_/", .singleItem),
            ("https://instagr.am/p/SYNpost0001_/", .singleItem),
            ("https://www.instagram.com/explore/tags/invented/", .notASingleItem),
            ("https://www.instagram.com/reels/audio/1234567890/", .notASingleItem),
            ("https://www.instagram.com/", .notASingleItem),
            ("https://www.instagram.com/direct/inbox/", .notASingleItem),
            ("https://www.instagram.com/accounts/login/?next=/p/abc/", .notASingleItem),
            ("https://www.instagram.com/explore/", .notASingleItem),

            // Host spellings.
            ("https://WWW.INSTAGRAM.COM/p/SYNpost0001_/", .singleItem),
            ("https://Instagram.com/reel/SYNreel0001_/", .singleItem),
            ("https://INSTAGR.AM/p/SYNpost0001_/", .singleItem),
            ("https://www.instagr.am/p/SYNpost0001_/", .singleItem),
            ("https://m.instagram.com/p/SYNpost0001_/", .singleItem),
            ("http://www.instagram.com/p/SYNpost0001_/", .singleItem),
            ("https://WWW.INSTAGRAM.COM/someone.invented/", .profile(username: "someone.invented")),
            ("https://instagram.com/someone.invented/", .profile(username: "someone.invented")),
            ("https://instagr.am/someone.invented/", .profile(username: "someone.invented")),
            ("https://m.instagram.com/someone.invented/", .profile(username: "someone.invented")),
            ("  https://www.instagram.com/p/SYNpost0001_/\n", .singleItem),

            // The trailing slash, present and absent.
            ("https://www.instagram.com/p/SYNpost0001_", .singleItem),
            ("https://www.instagram.com/reel/SYNreel0001_", .singleItem),
            ("https://www.instagram.com/tv/SYNvideo001_", .singleItem),
            ("https://www.instagram.com/share/SYNshare01", .singleItem),
            ("https://www.instagram.com/share/p/SYNshare01", .singleItem),
            ("https://www.instagram.com/someone.invented/p/SYNpost0001_", .singleItem),
            ("https://www.instagram.com/stories/someone.invented/3456789012345678901", .singleItem),
            ("https://www.instagram.com/stories/someone.invented", .notASingleItem),
            ("https://www.instagram.com/someone.invented/reels", .profile(username: "someone.invented")),
            ("https://www.instagram.com/someone.invented/posts", .profile(username: "someone.invented")),
            ("https://www.instagram.com/explore", .notASingleItem),
            ("https://www.instagram.com", .notASingleItem),

            // The query string and the fragment are not read.
            ("https://www.instagram.com/p/SYNpost0001_/?igsh=SYNtracking", .singleItem),
            ("https://www.instagram.com/reel/SYNreel0001_/?utm_source=ig_web_copy_link", .singleItem),
            ("https://www.instagram.com/stories/someone.invented/3456789012345678901/?igsh=SYNtracking", .singleItem),
            ("https://www.instagram.com/p/SYNpost0001_/#comments", .singleItem),
            ("https://www.instagram.com/someone.invented/?hl=en", .profile(username: "someone.invented")),
            ("https://www.instagram.com/someone.invented/?next=/p/SYNpost0001_/", .profile(username: "someone.invented")),
            ("https://www.instagram.com/someone.invented/#/p/SYNpost0001_/", .profile(username: "someone.invented")),
            ("https://www.instagram.com/someone.invented/?igsh=SYNtracking", .profile(username: "someone.invented")),
            ("https://www.instagram.com/stories/someone.invented/?story_id=3456789012345678901", .notASingleItem),

            // The item is named once its code is read.
            ("https://www.instagram.com/p/SYNpost0001_/embed/", .singleItem),
            ("https://www.instagram.com/reel/SYNreel0001_/embed/captioned/", .singleItem),
            ("https://www.instagram.com/someone.invented/reels/SYNreel0001_/", .singleItem),
            ("https://www.instagram.com/someone.invented/tv/SYNvideo001_/", .singleItem),
            ("https://www.instagram.com/share/reels/SYNshare01/", .singleItem),
            ("https://www.instagram.com/share/tv/SYNshare01/", .singleItem),

            // An item kind with nothing to name.
            ("https://www.instagram.com/p/", .notASingleItem),
            ("https://www.instagram.com/reel/", .notASingleItem),
            ("https://www.instagram.com/reels/", .notASingleItem),
            ("https://www.instagram.com/tv/", .notASingleItem),
            ("https://www.instagram.com/share/", .notASingleItem),
            ("https://www.instagram.com/share/p/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/p/", .notASingleItem),
            ("https://www.instagram.com/reels/audio/", .notASingleItem),
            ("https://www.instagram.com/share/reels/audio/1234567890/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/reels/audio/1234567890/", .notASingleItem),

            // A profile's tabs: its posts and its reels name the account's
            // own posts; every other tab is turned down.
            ("https://www.instagram.com/someone.invented/posts/", .profile(username: "someone.invented")),
            ("https://www.instagram.com/someone.invented/tagged", .notASingleItem),
            ("https://www.instagram.com/someone.invented/Posts/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/posts/extra/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/reels/audio/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/saved/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/saved/all-posts/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/highlights/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/followers/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/following/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/avatar/", .notASingleItem),
            ("https://www.instagram.com/someone.invented/info/", .notASingleItem),

            // Stories: only a numeric id names one.
            ("https://www.instagram.com/stories/someone.invented/latest/", .notASingleItem),
            ("https://www.instagram.com/stories/me/", .notASingleItem),
            ("https://www.instagram.com/stories/highlights/", .notASingleItem),
            ("https://www.instagram.com/stories/", .notASingleItem),
            ("https://www.instagram.com/stories/p/SYNpost0001_/", .notASingleItem),

            // Pages of the site.
            ("https://www.instagram.com/explore/locations/1234567890/invented-place/", .notASingleItem),
            ("https://www.instagram.com/explore/search/keyword/?q=invented", .notASingleItem),
            ("https://www.instagram.com/explore/p/SYNpost0001_/", .notASingleItem),
            ("https://www.instagram.com/accounts/edit/", .notASingleItem),
            ("https://www.instagram.com/accounts/p/SYNpost0001_/", .notASingleItem),
            ("https://www.instagram.com/direct/t/1234567890/", .notASingleItem),
            ("https://www.instagram.com/s/p/SYNpost0001_/", .notASingleItem),
            // Item kinds are lowercase; anything else is read as a username.
            ("https://www.instagram.com/P/SYNpost0001_/", .notASingleItem),
            ("https://www.instagram.com/Explore/", .notASingleItem),

            // A link that lost its "?": the code ends at the "&".
            ("https://www.instagram.com/p/SYNpost0001_&igsh=SYNtracking", .singleItem),
            ("https://www.instagram.com/reel/SYNreel0001_&igsh=SYNtracking", .singleItem),
            ("https://www.instagram.com/someone.invented/reel/SYNreel0001_&igsh=SYNtracking", .singleItem),
            ("https://www.instagram.com/p/&igsh=SYNtracking", .notASingleItem),
            ("https://www.instagram.com/reels/audio&igsh=SYNtracking", .notASingleItem),
            ("https://www.instagram.com/p/SYNpost0001_=SYNtracking", .notASingleItem),
            ("https://www.instagram.com/p/SYNpost0001_%20", .notASingleItem),
            ("https://www.instagram.com/someone.invented&igsh=SYNtracking", .notASingleItem),

            // The path is read as written: an escaped slash or letter is
            // not a slash or a letter to the tools.
            ("https://www.instagram.com/someone.invented/reels%2FSYNreel0001_", .notASingleItem),
            ("https://www.instagram.com/someone.invented%2Fp%2FSYNpost0001_", .notASingleItem),
            ("https://www.instagram.com/someone.invented/p%2FSYNpost0001_", .notASingleItem),
            ("https://www.instagram.com/%70/SYNpost0001_", .notASingleItem),
            ("https://www.instagram.com/p%2FSYNpost0001_/", .notASingleItem),
            ("https://www.instagram.com/stories/someone.invented%2F3456789012345678901", .notASingleItem),
            ("https://www.instagram.com/share%2FSYNshare01", .notASingleItem),

            // A story shared out of a highlight, with or without the
            // story's id in the query: the query is not read.
            (
                "https://www.instagram.com/s/aGlnaGxpZ2h0OjE3OTAwMDAwMDAwMDAwMDAw?story_media_id=3456789012345678901_1234567890",
                .notASingleItem
            ),

            // Hosts that serve media files: not page links.
            ("https://scontent.cdninstagram.com/v/t51.2885-15/synthetic_0001_n.jpg?stp=dst-jpg", .notInstagram),
            ("https://scontent-xyz1-1.cdninstagram.com/o1/v/t16/f2/m86/SYNTHETIC0001.mp4", .notInstagram),
            ("https://instagram.fxyz1-1.fna.fbcdn.net/v/t51.2885-15/synthetic_0001_n.jpg", .notInstagram),
            ("https://scontent.instagram.com/v/synthetic_0001_n.jpg", .notInstagram),
            // Other hosts of the domain.
            ("https://help.instagram.com/1234567890", .notInstagram),
            ("https://about.instagram.com/blog/", .notInstagram),
            // Look-alike hosts.
            ("https://notinstagram.com/someone.invented/", .notInstagram),
            ("https://www.instagram.com.example.org/someone.invented/", .notInstagram),
            ("https://www-instagram.com/someone.invented/", .notInstagram),
            ("https://www.instagram.com@example.com/someone.invented/", .notInstagram),
            ("https://example.com/www.instagram.com/someone.invented/", .notInstagram),
            // An Instagram link inside another site's query.
            ("https://example.com/?u=https://www.instagram.com/someone.invented/", .notInstagram),
            ("https://example.com/?u=https%3A%2F%2Fwww.instagram.com%2Fsomeone.invented%2F", .notInstagram),
            ("https://l.example.com/redirect?to=https://instagr.am/someone.invented/", .notInstagram),
            // Other sites.
            ("https://www.threads.com/@someone.invented", .notInstagram),
            ("https://x.com/someone/status/1", .notInstagram),
            ("https://www.youtube.com/watch?v=SYNTHETIC01", .notInstagram),
            // Not a web link.
            ("ftp://www.instagram.com/someone.invented/", .notInstagram),
            ("www.instagram.com/someone.invented/", .notInstagram),
            ("instagram://user?username=someone.invented", .notInstagram),
            ("", .notInstagram),
        ]
        for c in cases {
            XCTAssertEqual(InstagramLink.shape(of: c.link), c.expected, c.link)
        }
    }

    /// The profile turns down exactly the links judged not a single item:
    /// what is not an Instagram page link is left to run as it always has,
    /// whichever profile it is routed to, and so is a profile link, which
    /// runs as its own download.
    func testOnlyLinksThatAreNotASingleItemAreTurnedDown() {
        let instagram = SiteRegistry.instagram
        let turnedDown = [
            "https://www.instagram.com/someone.invented/tagged/",
            "https://www.instagram.com/someone.invented/saved/",
            "https://www.instagram.com/stories/someone.invented/",
            "https://www.instagram.com/explore/tags/invented/",
            // Routed to another profile by the substring matching, and
            // turned down all the same.
            "https://WWW.INSTAGRAM.COM/someone.invented/tagged/",
            "https://www.instagram.com/invented.x.com/tagged/",
            "https://www.instagram.com/invented.youtu.be/tagged/",
        ]
        for link in turnedDown {
            XCTAssertEqual(instagram.refusalMessage(for: link), InstagramLink.notASingleItemMessage, link)
            XCTAssertEqual(SiteRegistry.refusalMessage(for: link), InstagramLink.notASingleItemMessage, link)
        }
        XCTAssertEqual(SiteRegistry.profile(for: "https://WWW.INSTAGRAM.COM/someone.invented/tagged/").id, "other")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.instagram.com/invented.x.com/tagged/").id, "twitter")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.instagram.com/invented.youtu.be/tagged/").id, "youtube")
        let left = [
            "https://www.instagram.com/p/SYNpost0001_/",
            "https://www.instagram.com/stories/someone.invented/3456789012345678901/",
            "https://www.instagram.com/someone.invented/",
            "https://www.instagram.com/someone.invented/posts/",
            "https://www.instagram.com/someone.invented/reels/",
            "https://WWW.INSTAGRAM.COM/someone.invented/",
            "https://www.instagram.com/invented.x.com/",
            "https://scontent.cdninstagram.com/v/t51.2885-15/synthetic_0001_n.jpg",
            "https://notinstagram.com/someone.invented/",
            "https://example.com/?u=https://www.instagram.com/someone.invented/",
        ]
        for link in left {
            XCTAssertNil(instagram.refusalMessage(for: link), link)
            XCTAssertNil(SiteRegistry.refusalMessage(for: link), link)
        }
        // Account links of every other site run as they always have.
        let others = [
            "https://x.com/someone", "https://www.youtube.com/@someone/videos", "https://www.reddit.com/user/someone/",
            "https://www.threads.com/@someone.invented", "https://example.com/someone/",
        ]
        for link in others {
            XCTAssertNil(SiteRegistry.refusalMessage(for: link), link)
        }
    }

    // MARK: - Profiles

    /// A username is what Instagram would accept as one, and never a page
    /// of the site in its place, whatever its letter case.
    func testProfileUsernames() {
        let cases: [(link: String, expected: String?)] = [
            ("https://www.instagram.com/someone_invented/", "someone_invented"),
            ("https://www.instagram.com/Someone.Invented/", "someone.invented"),
            ("https://www.instagram.com/a/", "a"),
            ("https://www.instagram.com/invented_2026.x/posts/", "invented_2026.x"),
            ("https://www.instagram.com/\(String(repeating: "a", count: 30))/", String(repeating: "a", count: 30)),
            // Not a username Instagram gives out.
            ("https://www.instagram.com/\(String(repeating: "a", count: 31))/", nil),
            ("https://www.instagram.com/.someone/", nil),
            ("https://www.instagram.com/someone./", nil),
            ("https://www.instagram.com/some..one/", nil),
            ("https://www.instagram.com/some-one/", nil),
            ("https://www.instagram.com/some%2Eone/", nil),
            // Pages of the site, in any letter case.
            ("https://www.instagram.com/accounts/", nil),
            ("https://www.instagram.com/Accounts/login/", nil),
            ("https://www.instagram.com/accounts/login/", nil),
            ("https://www.instagram.com/accounts/edit/", nil),
            ("https://www.instagram.com/direct/", nil),
            ("https://www.instagram.com/direct/inbox/", nil),
            ("https://www.instagram.com/explore/", nil),
            ("https://www.instagram.com/EXPLORE/", nil),
            ("https://www.instagram.com/stories/", nil),
            ("https://www.instagram.com/reels/", nil),
            ("https://www.instagram.com/p/", nil),
            ("https://www.instagram.com/tv/", nil),
            ("https://www.instagram.com/share/", nil),
            ("https://www.instagram.com/s/", nil),
            ("https://www.instagram.com/about/", nil),
            ("https://www.instagram.com/legal/", nil),
            ("https://www.instagram.com/your_activity/", nil),
            ("https://www.instagram.com/", nil),
            // A post, a reel or a story is not a profile.
            ("https://www.instagram.com/someone.invented/p/SYNpost0001_/", nil),
            ("https://www.instagram.com/someone.invented/reels/SYNreel0001_/", nil),
            ("https://www.instagram.com/stories/someone.invented/3456789012345678901/", nil),
            // Not Instagram.
            ("https://notinstagram.com/someone.invented/", nil),
            ("https://www.threads.com/@someone.invented", nil),
        ]
        for c in cases {
            XCTAssertEqual(InstagramLink.profileUsername(of: c.link), c.expected, c.link)
        }
        for reserved in InstagramLink.reservedFirstSegments {
            XCTAssertNil(InstagramLink.profileUsername(of: "https://www.instagram.com/\(reserved)/"), reserved)
            XCTAssertNil(InstagramLink.profileUsername(of: "https://www.instagram.com/\(reserved.uppercased())/posts/"), reserved)
        }
    }

    /// Every spelling of one profile is kept as the same link.
    func testProfileLinksAreKeptInOneSpelling() {
        let spellings = [
            "https://www.instagram.com/someone.invented/",
            "https://www.instagram.com/someone.invented",
            "https://www.instagram.com/someone.invented/posts/",
            "https://www.instagram.com/someone.invented/reels",
            "https://WWW.INSTAGRAM.COM/Someone.Invented/",
            "http://instagram.com/someone.invented/?igsh=SYNtracking",
            "https://m.instagram.com/someone.invented/#top",
            "https://instagr.am/someone.invented/",
        ]
        for link in spellings {
            XCTAssertEqual(InstagramLink.canonicalProfileLink(for: link), "https://www.instagram.com/someone.invented/", link)
            XCTAssertEqual(DownloadManager.storedLink(link), "https://www.instagram.com/someone.invented/", link)
            XCTAssertTrue(DownloadManager.isSameDownload(link, "https://www.instagram.com/someone.invented/reels/"), link)
        }
        XCTAssertFalse(
            DownloadManager.isSameDownload("https://www.instagram.com/someone.invented/", "https://www.instagram.com/another.invented/"))
        XCTAssertNil(InstagramLink.canonicalProfileLink(for: "https://www.instagram.com/someone.invented/tagged/"))
        XCTAssertNil(InstagramLink.canonicalProfileLink(for: "https://www.instagram.com/p/SYNpost0001_/"))
        // Other links are kept as before.
        XCTAssertEqual(
            DownloadManager.storedLink("https://www.instagram.com/p/SYNpost0001_/?igsh=SYNtracking"),
            "https://www.instagram.com/p/SYNpost0001_/")
    }

    func testProfilePostLimit() {
        XCTAssertEqual(InstagramProfilePosts.defaultLimit, 100)
        XCTAssertEqual(InstagramProfilePosts.limitRange, 1...1000)
        XCTAssertEqual(InstagramProfilePosts.clampedLimit(0), 1)
        XCTAssertEqual(InstagramProfilePosts.clampedLimit(-5), 1)
        XCTAssertEqual(InstagramProfilePosts.clampedLimit(1), 1)
        XCTAssertEqual(InstagramProfilePosts.clampedLimit(250), 250)
        XCTAssertEqual(InstagramProfilePosts.clampedLimit(1000), 1000)
        XCTAssertEqual(InstagramProfilePosts.clampedLimit(5000), 1000)
        XCTAssertEqual(InstagramProfilePosts.title(username: "someone.invented", limit: 100), "someone.invented - newest 100 posts")
        XCTAssertEqual(InstagramProfilePosts.title(username: "someone.invented", limit: 1), "someone.invented - newest 1 post")
    }

    /// Routing is as it was: the guard judges links, it does not move them
    /// to another profile. (The Instagram profile matches by substring, so
    /// it has always been handed some links that are not Instagram's.)
    func testRoutingIsUnchanged() {
        let routed = [
            "https://www.instagram.com/someone.invented/": "instagram",
            "https://scontent.cdninstagram.com/v/t51.2885-15/synthetic_0001_n.jpg": "instagram",
            "https://notinstagram.com/someone.invented/": "instagram",
            "https://example.com/?u=https://www.instagram.com/someone.invented/": "instagram",
            "https://instagram.fxyz1-1.fna.fbcdn.net/v/t51.2885-15/synthetic_0001_n.jpg": "other",
            "https://example.com/?u=https%3A%2F%2Fwww.instagram.com%2Fsomeone.invented%2F": "other",
        ]
        for (link, id) in routed {
            XCTAssertEqual(SiteRegistry.profile(for: link).id, id, link)
        }
    }

    func testMessageLiteral() {
        XCTAssertEqual(
            InstagramLink.notASingleItemMessage,
            "This Instagram link isn't a single post, reel, story or profile — XDownloader doesn't download tagged or saved posts, highlights, hashtags or other pages of the site. Paste the link of a post, reel or story, or of the account's profile, instead."
        )
    }
}
