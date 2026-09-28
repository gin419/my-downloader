import XCTest

@testable import XDownloader

/// The gallery-dl command line for an Instagram profile's newest posts, and
/// how the row's progress reads the files it reports. Every username, code
/// and path here is invented.
@MainActor
final class InstagramProfileArgumentsTests: XCTestCase {

    private let downloads = URL(fileURLWithPath: "/tmp/xdownloader-tests/downloads")

    func testProfileCommandLine() {
        let args = GalleryDlService.profileArguments(
            username: "someone.invented", postLimit: 37, outputDirectory: downloads,
            cookieBrowser: .chrome, cookieBrowserProfile: "Profile 2", cookiesFile: nil)

        XCTAssertEqual(
            args,
            [
                "--cookies-from-browser", "chrome:Profile 2",
                "--dest", downloads.path,
                "-D", ".",
                "--retries", "10",
                "-o", "downloader.http.timeout=60",
                "-f", "{username} - {description|''!s:.100} [{post_shortcode}] #{num}.{extension}",
                "-o", "max-posts=37",
                "-o", "videos=merged",
                "--no-mtime",
                "https://www.instagram.com/someone.invented/posts/",
            ])
    }

    /// The posts tab, on the one host gallery-dl's extractor reads, is the
    /// last argument: never the profile itself, the reels tab or the link
    /// as pasted.
    func testTheURLIsThePostsTab() {
        let args = profileArguments(postLimit: 100)
        XCTAssertEqual(args.last, "https://www.instagram.com/someone.invented/posts/")
        XCTAssertEqual(GalleryDlService.profilePostsURL(username: "a_b.c"), "https://www.instagram.com/a_b.c/posts/")
    }

    /// The cap is the number of posts from Settings, as `max-posts`; the
    /// file range, which counts files, is not used.
    func testThePostCapIsTheSettingInPosts() {
        for limit in [1, 100, 1000] {
            let args = profileArguments(postLimit: limit)
            XCTAssertEqual(
                optionValues(args), ["downloader.http.timeout=60", "max-posts=\(limit)", "videos=merged"], "\(limit)")
            XCTAssertFalse(args.contains("--range"))
            XCTAssertFalse(args.contains("--post-range"))
        }
    }

    /// Each video is its ready-made file: gallery-dl never hands one to its
    /// yt-dlp downloader, which Homebrew's gallery-dl cannot import.
    func testVideosAreTheReadyMadeFiles() {
        let args = profileArguments(postLimit: 100)
        XCTAssertEqual(optionValues(args).filter { $0.hasPrefix("videos=") }, ["videos=merged"])
    }

    /// The single-post fallback and its photo sweep keep their own video
    /// options: none for the fallback, "videos=false" for the sweep.
    func testASinglePostKeepsItsOwnVideoOptions() throws {
        let post = "https://www.instagram.com/p/SYNpost0001_/"
        let fallback = GalleryDlService.arguments(
            for: post, outputDirectory: downloads, cookieBrowser: .chrome, cookiesFile: nil)
        XCTAssertEqual(optionValues(fallback).filter { $0.hasPrefix("videos=") }, [])
        let sweep = GalleryDlService.arguments(
            for: post, outputDirectory: downloads, cookieBrowser: .chrome, cookiesFile: nil,
            extraArgs: try XCTUnwrap(SiteRegistry.instagram.imageSweepArgs))
        XCTAssertEqual(optionValues(sweep).filter { $0.hasPrefix("videos=") }, ["videos=false"])
    }

    /// The Instagram file-name template the site profile declares, the same
    /// one a single post is saved under, so both find each other's files.
    func testTheFileNameTemplateIsInstagrams() throws {
        let args = profileArguments(postLimit: 100)
        let index = try XCTUnwrap(args.firstIndex(of: "-f"))
        XCTAssertEqual(Array(args[index...index + 1]), SiteRegistry.instagram.galleryDlArgs)
    }

    /// The cookie arguments are the app's own, for each kind of source.
    func testCookieArgumentsAreTheAppsOwn() {
        let file = "/tmp/xdownloader-tests/cookies.txt"
        let cases: [(browser: CookieBrowser, profile: String?, file: String?)] = [
            (.chrome, nil, nil), (.chrome, "Default", nil), (.safari, nil, nil), (.chrome, "Default", file),
        ]
        for c in cases {
            let args = GalleryDlService.profileArguments(
                username: "someone.invented", postLimit: 100, outputDirectory: downloads,
                cookieBrowser: c.browser, cookieBrowserProfile: c.profile, cookiesFile: c.file)
            let cookies = CookieArgs.make(browser: c.browser, profile: c.profile, file: c.file)
            XCTAssertFalse(cookies.isEmpty)
            XCTAssertEqual(Array(args.prefix(cookies.count)), cookies, "\(c)")
        }
    }

    /// gallery-dl's own pause between Instagram requests is left alone:
    /// nothing sets a sleep, a request interval or a rate.
    func testNothingShortensThePacing() {
        let args = profileArguments(postLimit: 1000)
        for arg in args {
            XCTAssertFalse(arg.hasPrefix("--sleep"), arg)
            XCTAssertFalse(arg.hasPrefix("--limit-rate"), arg)
            XCTAssertNotEqual(arg, "-r", arg)
        }
        for value in optionValues(args) {
            XCTAssertFalse(value.contains("sleep"), value)
            XCTAssertFalse(value.contains("interval"), value)
            XCTAssertFalse(value.contains("rate"), value)
        }
    }

    // MARK: - Progress

    func testPostCodeInReportedFiles() {
        let dir = "/tmp/xdownloader-tests/downloads"
        let cases: [(line: String, code: String?)] = [
            ("\(dir)/someone.invented - a caption [SYNpost0001_] #1.jpg", "SYNpost0001_"),
            ("\(dir)/someone.invented - a caption [SYNpost0001_] #12.mp4", "SYNpost0001_"),
            ("# \(dir)/someone.invented - [SYN-post002] #3.webp", "SYN-post002"),
            ("\(dir)/someone.invented - [not] a [code] here [SYNpost0003] #1.JPG", "SYNpost0003"),
            // Not a reported file.
            ("\(dir)/someone.invented - a caption [SYNpost0001_] #1.part", nil),
            ("\(dir)/someone.invented - a caption [SYNpost0001_].jpg", nil),
            ("[instagram][info] Use '-o cursor=SYNcursor' to continue downloading from the current position", nil),
            ("[warning] \(dir)/x [SYNpost0001_] #1.jpg", nil),
            ("", nil),
        ]
        for c in cases {
            XCTAssertEqual(GalleryDlService.postCode(inPathLine: c.line), c.code, c.line)
        }
    }

    /// The bar moves by posts reached out of the cap: a carousel's second
    /// file moves it no further, and a file already on disk counts too.
    func testProgressCountsPostsOutOfTheCap() {
        let item = DownloadItem(url: "https://www.instagram.com/someone.invented/")
        let progress = GalleryDlService.ProfileProgress(postLimit: 4)
        let dir = "/tmp/xdownloader-tests/downloads"

        progress.record("\(dir)/someone.invented - one [SYNpost0001_] #1.jpg", item: item)
        XCTAssertEqual(item.progress, 0.25)
        progress.record("\(dir)/someone.invented - one [SYNpost0001_] #2.jpg", item: item)
        XCTAssertEqual(item.progress, 0.25)
        progress.record("# \(dir)/someone.invented - two [SYNpost0002_] #1.mp4", item: item)
        XCTAssertEqual(item.progress, 0.5)
        progress.record("[instagram][info] something else", item: item)
        XCTAssertEqual(item.progress, 0.5)
        for code in ["SYNpost0003_", "SYNpost0004_", "SYNpost0005_"] {
            progress.record("\(dir)/someone.invented - [\(code)] #1.jpg", item: item)
        }
        XCTAssertEqual(item.progress, 1)
    }

    // MARK: - Helpers

    private func profileArguments(postLimit: Int) -> [String] {
        GalleryDlService.profileArguments(
            username: "someone.invented", postLimit: postLimit, outputDirectory: downloads,
            cookieBrowser: .chrome, cookieBrowserProfile: nil, cookiesFile: nil)
    }

    /// Every value given to "-o".
    private func optionValues(_ args: [String]) -> [String] {
        zip(args, args.dropFirst()).filter { $0.0 == "-o" }.map(\.1)
    }
}
