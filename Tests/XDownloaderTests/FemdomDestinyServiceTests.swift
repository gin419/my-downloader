import XCTest

@testable import XDownloader

/// femdomdestiny.com posts are read from their page. The fixtures below are
/// trimmed copies of real post markup — minified, so most attribute values
/// are unquoted — with the sidebar left in to prove it is ignored. They live
/// here rather than in Fixtures/, whose .html files belong to the Threads
/// manifest.
final class FemdomDestinyServiceTests: XCTestCase {

    private let page = URL(string: "https://femdomdestiny.com/example-post/")!

    // MARK: - Links and routing

    func testPostSlug() {
        XCTAssertEqual(FemdomDestinyService.postSlug(of: "https://femdomdestiny.com/piss-drinker-slave/"), "piss-drinker-slave")
        XCTAssertEqual(FemdomDestinyService.postSlug(of: "https://www.femdomdestiny.com/femdom-joi"), "femdom-joi")
        XCTAssertEqual(FemdomDestinyService.postSlug(of: "http://FemdomDestiny.com/femdom-joi/?utm_source=x#top"), "femdom-joi")
        XCTAssertNil(FemdomDestinyService.postSlug(of: "https://femdomdestiny.com/"))
        XCTAssertNil(FemdomDestinyService.postSlug(of: "https://femdomdestiny.com/category/femdom/"))
        XCTAssertNil(FemdomDestinyService.postSlug(of: "https://femdomdestiny.com/tag/pissing/"))
        XCTAssertNil(FemdomDestinyService.postSlug(of: "https://femdomdestiny.com/page/2/"))
        XCTAssertNil(FemdomDestinyService.postSlug(of: "https://femdomdestiny.com/wp-content/uploads/2026/10/a.mp4"))
        XCTAssertNil(FemdomDestinyService.postSlug(of: "https://notfemdomdestiny.com/femdom-joi/"))
        XCTAssertNil(FemdomDestinyService.postSlug(of: "https://example.com/?u=https://femdomdestiny.com/femdom-joi/"))
    }

    func testRoutingByExactHost() {
        XCTAssertEqual(SiteRegistry.profile(for: "https://femdomdestiny.com/piss-drinker-slave/").id, "femdomdestiny")
        XCTAssertEqual(SiteRegistry.profile(for: "https://www.femdomdestiny.com/femdom-joi/").id, "femdomdestiny")
        // A listing still routes here, so the row explains itself instead of
        // the generic extractor's "Unsupported URL".
        XCTAssertEqual(SiteRegistry.profile(for: "https://femdomdestiny.com/category/femdom/").id, "femdomdestiny")
        // The site's own files keep downloading the way they always have.
        XCTAssertEqual(SiteRegistry.profile(for: "https://femdomdestiny.com/wp-content/uploads/2026/10/a.mp4").id, "other")
        XCTAssertEqual(SiteRegistry.profile(for: "https://example.com/?u=https://femdomdestiny.com/femdom-joi/").id, "other")
    }

    func testProfileSkipsYtDlpAndSendsNoLogin() {
        let profile = SiteRegistry.femdomDestiny
        XCTAssertFalse(profile.usesYtDlp)
        XCTAssertFalse(profile.receivesBrowserCookies)
        XCTAssertEqual(profile.fallbacks, [.femdomDestiny])
        XCTAssertFalse(SiteProfile.Fallback.femdomDestiny.needsExternalTool)
    }

    @MainActor
    func testStoredLinkIsCanonical() {
        XCTAssertEqual(
            DownloadManager.storedLink("http://www.femdomdestiny.com/piss-drinker-slave?utm_source=feed"),
            "https://femdomdestiny.com/piss-drinker-slave/")
    }

    // MARK: - Gallery post

    func testGalleryPostDownloadsFullSizePicturesAndSkipsBanner() throws {
        let post = try resolved(galleryPage)
        XCTAssertEqual(post.title, "Piss Drinker Slave")
        XCTAssertEqual(post.media.map(\.kind), [.picture, .picture, .picture])
        XCTAssertEqual(
            post.media.map { $0.addresses.map(\.absoluteString) },
            [
                ["https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/piss-drinking-slave-1.jpg"],
                ["https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/piss-drinking-slave-10.jpg"],
                ["https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/piss-drinking-slave-2.jpg"],
            ])
    }

    // MARK: - Video posts

    func testVideoTagsWithUnquotedAttributes() throws {
        let post = try resolved(videoPage)
        XCTAssertEqual(post.title, "Femdom JOI: Detailed Jerk Off Instructions")
        XCTAssertEqual(
            post.media.map { $0.addresses.map(\.absoluteString) },
            [
                ["https://femdomdestiny.com/wp-content/uploads/2026/10/fishnets-joi.mp4"],
                ["https://femdomdestiny.com/wp-content/uploads/2026/10/stroking-instructions.mp4"],
                ["https://femdomdestiny.com/wp-content/uploads/2026/10/sexy-joi.webm"],
            ])
        XCTAssertEqual(post.media.map(\.kind), [.video, .video, .video])
    }

    func testFlowplayerVideoIsReadFromItsJSONAndThePosterIsSkipped() throws {
        let post = try resolved(flowplayerPage)
        XCTAssertEqual(
            post.media.map { $0.addresses.map(\.absoluteString) },
            [["https://femdomdestiny.com/wp-content/uploads/2017/07/ava-black-ballbusting.mp4"]])
        XCTAssertEqual(post.title, "Ebony Ballbusting Torture")
    }

    // MARK: - Pictures in the text

    func testTextPicturesAtFullSizeWithoutBannersLogosOrRelatedPosts() throws {
        let post = try resolved(textPicturesPage)
        XCTAssertEqual(
            post.media.map { $0.addresses.map(\.absoluteString) },
            [
                // srcset's widest entry, then its unsuffixed original first.
                [
                    "https://femdomdestiny.com/wp-content/uploads/2025/04/scene.webp",
                    "https://femdomdestiny.com/wp-content/uploads/2025/04/scene-1024x683.webp",
                ],
                // Linked to its own full-size file: that file first.
                [
                    "https://femdomdestiny.com/wp-content/uploads/2025/04/closeup.jpg",
                    "https://femdomdestiny.com/wp-content/uploads/2025/04/closeup-300x200.jpg",
                ],
                // Lazy-loaded: the real address, not the placeholder.
                ["https://femdomdestiny.com/wp-content/uploads/2025/04/lazy.png"],
            ])
    }

    // MARK: - Nothing to download

    func testPostWithOnlyTextAndAPodcastHasNoMedia() {
        XCTAssertEqual(
            FemdomDestinyService.resolve(html: textOnlyPage, pageURL: page), .failure(.noMedia))
        XCTAssertEqual(FemdomDestinyService.message(for: .noMedia), "This page has no pictures or videos to download.")
    }

    func testPageWithoutArticle() {
        XCTAssertEqual(
            FemdomDestinyService.resolve(html: "<html><body><p>Error</p></body></html>", pageURL: page),
            .failure(.noArticle))
    }

    // MARK: - Helpers

    func testSizeSuffixAndSrcset() {
        XCTAssertEqual(
            FemdomDestinyService.withoutSizeSuffix(URL(string: "https://femdomdestiny.com/wp-content/uploads/a/b-300x60.jpg")!)?
                .absoluteString,
            "https://femdomdestiny.com/wp-content/uploads/a/b.jpg")
        XCTAssertNil(FemdomDestinyService.withoutSizeSuffix(URL(string: "https://femdomdestiny.com/x/b-2.jpg")!))
        XCTAssertEqual(FemdomDestinyService.largestSrcsetEntry("a.jpg 300w, c.jpg 1500w, b.jpg 1024w"), "c.jpg")
        XCTAssertEqual(
            FemdomDestinyService.siteFile(URL(string: "http://www.femdomdestiny.com/wp-content/a.jpg?x86621&t=1")!).absoluteString,
            "https://femdomdestiny.com/wp-content/a.jpg")
    }

    func testEntitiesAndUnquotedAttributes() {
        let attributes = FemdomDestinyService.attributes(
            in: #" class="a b" src=http://x.test/a.jpg?x=1&amp;y=2 data-item={&quot;k&quot;:&quot;v&quot;} title='It&#8217;s'"#)
        XCTAssertEqual(attributes["class"], "a b")
        XCTAssertEqual(attributes["src"], "http://x.test/a.jpg?x=1&y=2")
        XCTAssertEqual(attributes["data-item"], #"{"k":"v"}"#)
        XCTAssertEqual(attributes["title"], "It\u{2019}s")
    }

    func testOneFileIsNamedAfterThePostAndSeveralKeepTheSiteNames() {
        let one = [FemdomDestinyService.Media(kind: .video, addresses: [URL(string: "https://femdomdestiny.com/v/a.mp4")!])]
        XCTAssertEqual(FemdomDestinyService.baseNames(for: one, stem: "Femdom Destiny - A [a]"), ["Femdom Destiny - A [a]"])
        let several = ["x/one.jpg", "y/one.jpg", "z/two.mp4"].map {
            FemdomDestinyService.Media(kind: .picture, addresses: [URL(string: "https://femdomdestiny.com/\($0)")!])
        }
        XCTAssertEqual(FemdomDestinyService.baseNames(for: several, stem: "S"), ["one", "one (2)", "two"])
    }

    private func resolved(_ html: String) throws -> FemdomDestinyService.Post {
        switch FemdomDestinyService.resolve(html: html, pageURL: page) {
        case .success(let post): return post
        case .failure(let failure):
            XCTFail("expected media, got \(failure)")
            throw failure
        }
    }

    // MARK: - Fixtures

    private let sidebar = """
        <aside class=sidebar><img src=https://femdomdestiny.com/wp-content/uploads/2026/09/fetish-webcams.webp alt=ad>
        <video src=https://femdomdestiny.com/wp-content/uploads/2026/10/sidebar.mp4></video></aside>
        <footer><img class=custom-logo src=https://femdomdestiny.com/wp-content/uploads/2026/06/logo.webp></footer>
        """

    private var galleryPage: String {
        """
        <html><head><meta property="og:title" content="Piss Drinker Slave - Femdom Destiny"></head><body>
        <header><img class=header-image src=https://femdomdestiny.com/wp-content/uploads/2026/06/logo.webp></header>
        <article
        id=post-7497 class="post-7497 post type-post">
        <h1 class="entry-title" itemprop="headline">Piss Drinker Slave</h1>
        <div class=entry-content>
        <p><a
        href="http://refer.ccbill.com/cgi-bin/clicks.cgi?CA=925280-0000&amp;PA=1455243&amp;HTML=http://russian-mistress.com/cb/" target=_blank rel=nofollow><img
        decoding=async class="aligncenter size-full wp-image-3179" src=http://www.femdomdestiny.com/wp-content/uploads/2012/03/russian-mistress.jpg?x86621 alt=russian-mistress width=468 height=93 srcset="https://femdomdestiny.com/wp-content/uploads/2012/03/russian-mistress.jpg 468w, https://femdomdestiny.com/wp-content/uploads/2012/03/russian-mistress-300x60.jpg 300w"></a></p>
        <div class=ngg-galleryoverview>
        <a
        href=https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/piss-drinking-slave-1.jpg?x86621
        title
        data-src="https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/piss-drinking-slave-1.jpg?x86621&amp;t=1538214670"
        data-thumbnail="https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/thumbs/thumbs_piss-drinking-slave-1.jpg?x86621&amp;t=1538214670"><img
        class=ngg-gallery-thumbnail-img title=piss-drinking-slave-1 alt=piss-drinking-slave-1
        src="https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/thumbs/thumbs_piss-drinking-slave-1.jpg?x86621&amp;t=1538214670"
        width=140 height=107 style=max-width:100%;></a>
        <a
        href=https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/piss-drinking-slave-10.jpg?x86621
        title><img
        class=ngg-gallery-thumbnail-img src="https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/thumbs/thumbs_piss-drinking-slave-10.jpg?x86621&amp;t=1538214671"></a>
        <a
        href=https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/piss-drinking-slave-2.jpg?x86621
        title><img
        class=ngg-gallery-thumbnail-img src="https://femdomdestiny.com/wp-content/gallery/russianmistress-pisser/thumbs/thumbs_piss-drinking-slave-2.jpg?x86621&amp;t=1538214675"></a>
        </div>
        <p><a
        href="http://refer.ccbill.com/cgi-bin/clicks.cgi?CA=925280-0000&amp;PA=1455243&amp;HTML=http://russian-mistress.com/cb/" target=_blank rel=nofollow>CLICK HERE FOR MORE HUMILIATION</a></p>
        </div>
        <footer class=entry-meta><a
        href=https://femdomdestiny.com/tag/pissing/ rel=tag>pissing</a></footer>
        </article>
        \(sidebar)
        </body></html>
        """
    }

    private var videoPage: String {
        """
        <html><body><article id=post-1 class="post type-post">
        <h1 class="entry-title" itemprop="headline">Femdom JOI: Detailed Jerk Off Instructions</h1>
        <div class=entry-content><p>Intro text with a <a href=https://femdomdestiny.com/findom/>link to another post</a>.</p>
        <video
        controls preload=none poster=https://femdomdestiny.com/wp-content/uploads/2020/04/fish.webp src=https://femdomdestiny.com/wp-content/uploads/2026/10/fishnets-joi.mp4></video>
        <video
        controls preload=none poster=https://femdomdestiny.com/wp-content/uploads/2020/04/green2.webp src=https://femdomdestiny.com/wp-content/uploads/2026/10/stroking-instructions.mp4></video>
        <video controls preload=none poster=https://femdomdestiny.com/wp-content/uploads/2020/04/lipstick.webp><source src=https://femdomdestiny.com/wp-content/uploads/2026/10/sexy-joi.webm type=video/webm><source
        src=http://www.femdomdestiny.com/wp-content/uploads/2026/10/fishnets-joi.mp4?x86621 type=video/mp4></video>
        <iframe loading=lazy src="https://open.spotify.com/embed/show/1V7AoWbBRNxqMOAFCKzm2Q" width=100%></iframe>
        </div></article>
        \(sidebar)
        </body></html>
        """
    }

    private var flowplayerPage: String {
        """
        <html><body><article id=post-2 class="post type-post">
        <h1 class="entry-title" itemprop="headline">Ebony Ballbusting Torture</h1>
        <div class=entry-content><h2 style="text-align: center;">Ebony ballbusting video:</h2><div id=wpfp_1197f9bb82940fbf83b4f96f3092eb60 data-item={&quot;sources&quot;:[{&quot;src&quot;:&quot;http:\\/\\/www.femdomdestiny.com\\/wp-content\\/uploads\\/2017\\/07\\/ava-black-ballbusting.mp4&quot;,&quot;type&quot;:&quot;video\\/mp4&quot;}],&quot;splash&quot;:&quot;http:\\/\\/www.femdomdestiny.com\\/wp-content\\/uploads\\/2017\\/07\\/black-mistress-ballbusting.jpg&quot;} class="flowplayer no-brand is-splash" data-ratio=0.5621 itemprop=video><div class=fp-ratio style="padding-top: 56.21%"></div> <img decoding=async class=fp-splash alt=video src=http://www.femdomdestiny.com/wp-content/uploads/2017/07/black-mistress-ballbusting.jpg?x86621><div class=fp-ui><noscript>Please enable JavaScript</noscript></div></div>
        </div></article>
        \(sidebar)
        </body></html>
        """
    }

    private var textPicturesPage: String {
        """
        <html><body><article id=post-3 class="post type-post">
        <h1 class="entry-title">Pictures</h1>
        <div class=entry-content>
        <figure class="wp-block-image size-large"><img decoding=async width=1024 height=683 src=https://femdomdestiny.com/wp-content/uploads/2025/04/scene-1024x683.webp alt class=wp-image-9 srcset="https://femdomdestiny.com/wp-content/uploads/2025/04/scene-300x200.webp 300w, https://femdomdestiny.com/wp-content/uploads/2025/04/scene-1024x683.webp 1024w, https://femdomdestiny.com/wp-content/uploads/2025/04/scene-768x512.webp 768w" sizes="(max-width: 1024px) 100vw, 1024px"></figure>
        <p><a href=https://femdomdestiny.com/wp-content/uploads/2025/04/closeup.jpg><img class=wp-image-10 src=https://femdomdestiny.com/wp-content/uploads/2025/04/closeup-300x200.jpg></a></p>
        <p><a href=https://femdomdestiny.com/medical-female-domination/><img class=wp-image-11 src=https://femdomdestiny.com/wp-content/uploads/2025/04/medical-female-domination.webp alt="related post"></a></p>
        <p><a href=https://partner.example/join target=_blank><img class=wp-image-12 src=https://femdomdestiny.com/wp-content/uploads/2025/04/banner.gif></a></p>
        <p><img class="lazyload wp-image-13" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" data-lazy-src=https://femdomdestiny.com/wp-content/uploads/2025/04/lazy.png></p>
        <p><img class=emoji src=https://s.w.org/images/core/emoji/15.0.3/svg/2764.svg></p>
        <p><img src=https://femdomdestiny.com/wp-content/uploads/2026/06/logo.webp></p>
        </div></article>
        \(sidebar)
        </body></html>
        """
    }

    private var textOnlyPage: String {
        """
        <html><body><article id=post-4 class="post type-post">
        <h1 class="entry-title">Findom</h1>
        <div class=entry-content><p>Text only, with a <a href=https://femdomdestiny.com/femdom-joi/>link</a>.</p>
        <iframe loading=lazy style="border-radius: 12px;" src="https://open.spotify.com/embed/show/1V7AoWbBRNxqMOAFCKzm2Q?utm_source=generator&amp;si=0442d90aa3f54623" width=100% height=352></iframe>
        </div></article>
        \(sidebar)
        </body></html>
        """
    }
}
