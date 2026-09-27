import XCTest

@testable import XDownloader

/// `DownloadManager.stripTrackingParams` removes `utm_*` and a fixed set of
/// share/referral params before a URL is downloaded, while preserving the rest.
@MainActor
final class URLTrackingParamsTests: XCTestCase {

    func testStripsTrackingButKeepsRealParams() {
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://x.com/a/b?utm_source=ig&si=abc&v=1"),
            "https://x.com/a/b?v=1")
    }

    func testDropsQueryEntirelyWhenAllStripped() {
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://x.com/a?utm_medium=x&fbclid=y"),
            "https://x.com/a")
    }

    func testStripsShareParam() {
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://youtu.be/abc?si=track"),
            "https://youtu.be/abc")
    }

    func testStripsXShareLinkParams() {
        // x.com share links carry ?s=46&t=… — both must go or the same post
        // never dedups against its bare URL.
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://x.com/a/status/1?s=46&t=AbC_dEf"),
            "https://x.com/a/status/1")
    }

    func testStripsInstagramShareLinkParam() {
        // instagram.com share links carry ?igsh=… — strip it so the same post
        // dedups against its bare URL.
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://www.instagram.com/p/Daoe_4TTVY0/?igsh=NTc4MTIwNjQ2YQ%3D%3D"),
            "https://www.instagram.com/p/Daoe_4TTVY0/")
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://www.instagram.com/p/Daoe_4TTVY0/?igsh=abc&img_index=2"),
            "https://www.instagram.com/p/Daoe_4TTVY0/?img_index=2")
    }

    func testStripsLegacyInstagramShareLinkParam() {
        // Older Instagram app versions emit ?igshid=… — those links are still
        // everywhere and must dedup against the bare URL and the ?igsh= form.
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://www.instagram.com/p/Daoe_4TTVY0/?igshid=MzRlODBiNWFlZA%3D%3D"),
            "https://www.instagram.com/p/Daoe_4TTVY0/")
    }

    func testStripsThreadsShareLinkParams() {
        // Threads share links carry ?xmt=…&slof=… — the post is named by its
        // path alone, so the shared link must dedup against the bare one.
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://www.threads.com/@user/post/CODE?xmt=AQF0abc&slof=1"),
            "https://www.threads.com/@user/post/CODE")
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://www.threads.net/@user/post/CODE?igshid=abc"),
            "https://www.threads.net/@user/post/CODE")
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://www.threads.com/@user/post/CODE?XMT=abc&keep=1"),
            "https://www.threads.com/@user/post/CODE?keep=1")
    }

    func testLeavesNonTrackingParamsUntouched() {
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://example.com/p?keep=1"),
            "https://example.com/p?keep=1")
    }

    func testParamMatchIsCaseInsensitive() {
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://x.com/a?UTM_Source=x&id=9"),
            "https://x.com/a?id=9")
    }

    func testWorkPageLinkKeepsItsIdParameter() {
        // The id IS the link: stripping must leave it and take the rest.
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://video.dmm.co.jp/cinema/content/?id=test00123&utm_source=share&ref=top"),
            "https://video.dmm.co.jp/cinema/content/?id=test00123")
        XCTAssertEqual(
            DownloadManager.stripTrackingParams("https://video.dmm.co.jp/cinema/content/?id=test00123"),
            "https://video.dmm.co.jp/cinema/content/?id=test00123")
    }

    func testOneWorkIsStoredUnderOneLinkWhateverWasPasted() {
        let canonical = "https://video.dmm.co.jp/cinema/content/?id=test00123"
        let same = [
            canonical,
            "https://video.dmm.co.jp/cinema/content?id=test00123",
            "http://video.dmm.co.jp/cinema/content/?id=test00123",
            "https://VIDEO.DMM.CO.JP/cinema/content/?id=TEST00123",
            "https://video.dmm.co.jp/cinema/content/?id=test00123&utm_source=share&i3_ref=list&dmmref=top",
            "https://video.dmm.co.jp/cinema/content/?utm_medium=x&id=test00123",
            // The wrapper link wraps the page it was on the way to.
            "https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fvideo.dmm.co.jp%2Fcinema%2Fcontent%2F%3Fid%3Dtest00123",
        ]
        for link in same {
            let stored = DownloadManager.storedLink(link)
            XCTAssertEqual(stored, canonical, link)
            XCTAssertEqual(SiteRegistry.profile(for: stored).id, "dmm", link)
            XCTAssertTrue(DownloadManager.isSameDownload(stored, canonical), link)
        }
        XCTAssertNotEqual(DownloadManager.storedLink("https://video.dmm.co.jp/cinema/content/?id=test00124"), canonical)
    }

    func testStoredLinkLeavesEveryOtherLinkToTheStripping() {
        let links = [
            "https://x.com/a/b?utm_source=ig&si=abc&v=1",
            "https://youtu.be/abc?si=track",
            "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK?xmt=AQF0abc",
            // Direct preview file links, as pasted.
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAAAAAAAAAAAAAAAAAA/test00123hhb.mp4",
            "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenBBBBBBBBBBBBBBBBBBBB/playlist.m3u8",
            // On the site, but no work page: kept, and turned down by name.
            "https://video.dmm.co.jp/cinema/list/?utm_source=share",
            // A wrapper link that wraps something else.
            "https://www.dmm.co.jp\(DmmTestLinks.wrapper)?rurl=https%3A%2F%2Fwww.dmm.co.jp%2Ftop%2F",
        ]
        for link in links {
            XCTAssertEqual(DownloadManager.storedLink(link), DownloadManager.stripTrackingParams(link), link)
        }
    }

    func testOneThreadsPostIsOneDownloadWhateverTheLinkForm() {
        // The list's duplicate check: one post has many spellings, and two
        // rows for it would save to the same file names at the same time.
        let post = "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK"
        let same = [
            post,
            "https://www.threads.net/@someone.invented/post/AbCdEfGhIjK",
            "https://threads.com/@someone.invented/post/AbCdEfGhIjK/media",
            "https://www.threads.com/t/AbCdEfGhIjK",
            // The username is not checked by the server.
            "https://www.threads.com/@someone.else/post/AbCdEfGhIjK",
        ]
        for link in same {
            XCTAssertTrue(DownloadManager.isSameDownload(post, link), link)
            XCTAssertTrue(DownloadManager.isSameDownload(link, post), link)
        }
        let different = [
            "https://www.threads.com/@someone.invented/post/AbCdEfGhIjL",
            // Codes are case-sensitive.
            "https://www.threads.com/@someone.invented/post/abcdefghijk",
            "https://www.threads.com/@someone.invented",
            "https://www.instagram.com/p/AbCdEfGhIjK/",
            "https://example.com/?u=https://www.threads.com/t/AbCdEfGhIjK",
        ]
        for link in different {
            XCTAssertFalse(DownloadManager.isSameDownload(post, link), link)
            XCTAssertFalse(DownloadManager.isSameDownload(link, post), link)
        }
        // Every other site: the same text, or not the same download.
        XCTAssertTrue(DownloadManager.isSameDownload("https://x.com/a/status/1", "https://x.com/a/status/1"))
        XCTAssertFalse(DownloadManager.isSameDownload("https://x.com/a/status/1", "https://twitter.com/a/status/1"))
        XCTAssertFalse(
            DownloadManager.isSameDownload("https://www.threads.com/@someone.invented", "https://www.threads.com/@someone.else"))
    }
}
