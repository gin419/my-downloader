import XCTest

@testable import XDownloader

/// The path wrapper links live under, spelled once for every test that
/// builds one.
enum DmmTestLinks {
    static let wrapper = "/age_check/=/"
}

/// `DmmPreviewResolver`'s link rules: which links name a work page, the
/// content id read from them, the one form a link is kept in, and the
/// wrapper link unwrapped to the page inside it. Every id here is
/// invented.
@MainActor
final class DmmLinkParsingTests: XCTestCase {

    private typealias Link = DmmPreviewResolver.WorkLink

    // MARK: - Work pages

    func testParseLinkTable() {
        let cases: [(link: String, expected: Link?)] = [
            ("https://video.dmm.co.jp/cinema/content/?id=test00123", Link(section: "cinema", contentID: "test00123")),
            ("https://video.dmm.co.jp/anime/content/?id=test123", Link(section: "anime", contentID: "test123")),
            ("https://video.dmm.co.jp/cinema/content?id=test00123", Link(section: "cinema", contentID: "test00123")),
            ("https://VIDEO.DMM.CO.JP/cinema/content/?id=test00123", Link(section: "cinema", contentID: "test00123")),
            ("https://video.dmm.co.jp/CINEMA/Content/?id=test00123", Link(section: "cinema", contentID: "test00123")),
            ("https://video.dmm.co.jp/cinema/content/?id=TEST00123", Link(section: "cinema", contentID: "test00123")),
            ("http://video.dmm.co.jp/cinema/content/?id=test00123", Link(section: "cinema", contentID: "test00123")),
            ("https://video.dmm.co.jp/cinema/content/?id=h_1234test00045", Link(section: "cinema", contentID: "h_1234test00045")),
            ("https://video.dmm.co.jp/cinema/content/?id=1test00123", Link(section: "cinema", contentID: "1test00123")),
            // Whatever else the query holds is not read.
            ("https://video.dmm.co.jp/cinema/content/?utm_source=x&id=test00123&ref=y", Link(section: "cinema", contentID: "test00123")),
            ("https://video.dmm.co.jp/cinema/content/?id=test00123#reviews", Link(section: "cinema", contentID: "test00123")),
            ("  https://video.dmm.co.jp/cinema/content/?id=test00123\n", Link(section: "cinema", contentID: "test00123")),
            // The site, but not a work page.
            ("https://video.dmm.co.jp/", nil),
            ("https://video.dmm.co.jp/cinema/", nil),
            ("https://video.dmm.co.jp/cinema/list/?sort=date", nil),
            ("https://video.dmm.co.jp/cinema/list/?id=test00123", nil),
            ("https://video.dmm.co.jp/content/?id=test00123", nil),
            ("https://video.dmm.co.jp/cinema/content/extra/?id=test00123", nil),
            // A missing or malformed id.
            ("https://video.dmm.co.jp/cinema/content/", nil),
            ("https://video.dmm.co.jp/cinema/content/?id=", nil),
            ("https://video.dmm.co.jp/cinema/content/?cid=test00123", nil),
            ("https://video.dmm.co.jp/cinema/content/?ID=test00123", nil),
            ("https://video.dmm.co.jp/cinema/content/?id=ab", nil),
            ("https://video.dmm.co.jp/cinema/content/?id=" + String(repeating: "a", count: 41), nil),
            ("https://video.dmm.co.jp/cinema/content/?id=test-00123", nil),
            ("https://video.dmm.co.jp/cinema/content/?id=test%2F00123", nil),
            ("https://video.dmm.co.jp/cinema/content/?id=test%2000123", nil),
            ("https://video.dmm.co.jp/cinema/content/?id=..%2Ftest00123", nil),
            // Direct preview file links: the generic path's, never this one's.
            ("https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4", nil),
            ("https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123_mhb_w.mp4", nil),
            ("https://cc3001.dmm.co.jp/pv/SYNTHETICtokenBBBB/playlist.m3u8", nil),
            ("https://cc3001.dmm.co.jp/cinema/content/?id=test00123", nil),
            // Other hosts of the domain.
            ("https://www.dmm.co.jp/cinema/content/?id=test00123", nil),
            ("https://dmm.co.jp/cinema/content/?id=test00123", nil),
            ("https://tv.dmm.co.jp/cinema/content/?id=test00123", nil),
            ("https://pics.dmm.co.jp/cinema/content/?id=test00123", nil),
            ("https://api.video.dmm.co.jp/cinema/content/?id=test00123", nil),
            ("https://video.dmm.com/cinema/content/?id=test00123", nil),
            // The wrapper link is unwrapped at capture, not parsed.
            ("https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fcinema%2Fcontent%2F%3Fid%3Dtest00123", nil),
            // Look-alike domains.
            ("https://video.dmm.co.jp.example.com/cinema/content/?id=test00123", nil),
            ("https://notvideo.dmm.co.jp/cinema/content/?id=test00123", nil),
            ("https://video.dmm.co.jp@example.com/cinema/content/?id=test00123", nil),
            ("https://example.com/video.dmm.co.jp/cinema/content/?id=test00123", nil),
            // A page link inside another site's query.
            ("https://example.com/?next=https://video.dmm.co.jp/cinema/content/?id=test00123", nil),
            ("https://example.com/?next=https%3A%2F%2Fvideo.dmm.co.jp%2Fcinema%2Fcontent%2F%3Fid%3Dtest00123", nil),
            // Not a web link.
            ("ftp://video.dmm.co.jp/cinema/content/?id=test00123", nil),
            ("video.dmm.co.jp/cinema/content/?id=test00123", nil),
            ("file:///tmp/example/cinema/content/?id=test00123", nil),
            ("", nil),
        ]
        for c in cases {
            XCTAssertEqual(DmmPreviewResolver.parseLink(c.link), c.expected, c.link)
        }
    }

    /// No list of sections is kept: the section is never sent anywhere and
    /// the id alone names the work, so any name of the section's shape
    /// parses.
    func testAnySectionOfTheExpectedShapeParses() {
        for section in ["cinema", "anime", "vr", "a", "s1", "new-section", "new_section", String(repeating: "a", count: 20)] {
            XCTAssertEqual(
                DmmPreviewResolver.parseLink("https://video.dmm.co.jp/\(section)/content/?id=test00123"),
                Link(section: section, contentID: "test00123"), section)
        }
        for section in ["", "1st", "-a", "_a", "a.b", "a%20b", String(repeating: "a", count: 21)] {
            XCTAssertNil(DmmPreviewResolver.parseLink("https://video.dmm.co.jp/\(section)/content/?id=test00123"), section)
        }
    }

    func testTheFirstIdParameterIsTheOneRead() {
        XCTAssertEqual(
            DmmPreviewResolver.parseLink("https://video.dmm.co.jp/cinema/content/?id=test00123&id=other00456"),
            Link(section: "cinema", contentID: "test00123"))
    }

    func testSiteHostIsAnExactHostNeverASubstring() {
        let site = [
            "https://video.dmm.co.jp/cinema/content/?id=test00123",
            "https://VIDEO.DMM.CO.JP/",
            "http://video.dmm.co.jp/cinema/list/?sort=date",
        ]
        for link in site { XCTAssertTrue(DmmPreviewResolver.isSiteHost(link), link) }
        let others = [
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenBBBB/playlist.m3u8",
            "https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fcinema%2Fcontent%2F%3Fid%3Dtest00123",
            "https://www.dmm.co.jp/",
            "https://tv.dmm.co.jp/",
            "https://pics.dmm.co.jp/example/test00123.jpg",
            "https://api.video.dmm.co.jp/",
            "https://www.dmm.com/",
            "https://video.dmm.co.jp.example.com/cinema/content/?id=test00123",
            "https://notvideo.dmm.co.jp/cinema/content/?id=test00123",
            "https://video.dmm.co.jp@example.com/cinema/content/?id=test00123",
            "https://example.com/?next=https://video.dmm.co.jp/cinema/content/?id=test00123",
            "video.dmm.co.jp/cinema/content/?id=test00123",
            "",
        ]
        for link in others { XCTAssertFalse(DmmPreviewResolver.isSiteHost(link), link) }
    }

    // MARK: - Canonical form

    func testCanonicalURLDropsEverythingButSectionAndId() throws {
        let cases: [(link: String, canonical: String)] = [
            ("http://VIDEO.DMM.CO.JP/CINEMA/content?id=TEST00123&utm_source=x#reviews", "https://video.dmm.co.jp/cinema/content/?id=test00123"),
            ("https://video.dmm.co.jp/anime/content/?ref=y&id=test123", "https://video.dmm.co.jp/anime/content/?id=test123"),
            ("https://video.dmm.co.jp/cinema/content/?id=test00123", "https://video.dmm.co.jp/cinema/content/?id=test00123"),
        ]
        for c in cases {
            let link = try XCTUnwrap(DmmPreviewResolver.parseLink(c.link), c.link)
            let canonical = try XCTUnwrap(DmmPreviewResolver.canonicalURL(for: link))
            XCTAssertEqual(canonical.absoluteString, c.canonical)
            // The canonical form names the same work.
            XCTAssertEqual(DmmPreviewResolver.parseLink(canonical.absoluteString), link)
        }
    }

    // MARK: - Wrapper links

    func testWrapperLinkUnwrapsToTheCanonicalPageLink() {
        let cases: [(link: String, expected: String?)] = [
            (
                "https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fcinema%2Fcontent%2F%3Fid%3Dtest00123",
                "https://video.dmm.co.jp/cinema/content/?id=test00123"
            ),
            (
                "https://www.dmm.co.jp\(DmmTestLinks.wrapper)declared=yes/?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fanime%2Fcontent%3Fid%3DTEST00123",
                "https://video.dmm.co.jp/anime/content/?id=test00123"
            ),
            (
                "http://WWW.DMM.CO.JP\(DmmTestLinks.wrapper)?a=1&rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fvr%2Fcontent%2F%3Fid%3Dtest00123%26ref%3Dx",
                "https://video.dmm.co.jp/vr/content/?id=test00123"
            ),
            // Wraps something that is no work page.
            ("https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2F", nil),
            ("https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fcinema%2Flist%2F%3Fsort%3Ddate", nil),
            ("https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fcc3001.dmm.co.jp%2Fpv%2FSYNTHETICtokenAAAA%2Ftest00123hhb.mp4", nil),
            ("https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fexample.com%2Fcinema%2Fcontent%2F%3Fid%3Dtest00123", nil),
            ("https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=", nil),
            ("https://www.dmm.co.jp\(DmmTestLinks.wrapper)", nil),
            // Not a wrapper link.
            ("https://www.dmm.co.jp/other/?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fcinema%2Fcontent%2F%3Fid%3Dtest00123", nil),
            ("https://example.com\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fcinema%2Fcontent%2F%3Fid%3Dtest00123", nil),
            ("https://www.dmm.co.jp.example.com\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fvr%2Fcontent%2F%3Fid%3Dtest00123", nil),
            // A page link is already what it should be.
            ("https://video.dmm.co.jp/cinema/content/?id=test00123", nil),
            ("", nil),
        ]
        for c in cases {
            XCTAssertEqual(DmmPreviewResolver.unwrapWrapperLink(c.link), c.expected, c.link)
        }
    }
}
