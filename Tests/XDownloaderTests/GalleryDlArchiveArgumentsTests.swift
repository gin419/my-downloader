import XCTest

@testable import XDownloader

/// The app's own gallery-dl runs skip a post by the files in the
/// destination, never by a download archive set in the user's gallery-dl
/// config: that archive lists a post as done whether or not its file is in
/// the folder the run saves into. X Likes Sync keeps its own archive. Every
/// username, code and path here is invented.
@MainActor
final class GalleryDlArchiveArgumentsTests: XCTestCase {

    private let downloads = URL(fileURLWithPath: "/tmp/xdownloader-tests/downloads")
    private let links = [
        "https://x.com/someone_invented/status/1234567890123",
        "https://www.instagram.com/p/SYNpost0001_/",
        "https://www.reddit.com/r/invented/comments/abc123/a_title/",
        "https://example.invalid/gallery/1",
    ]

    /// The key has no path, so it sits above every level of a config file,
    /// and its value is false: the archive is never opened.
    func testTheArgumentSwitchesTheArchiveOffAtTheTopLevel() {
        XCTAssertEqual(GalleryDlService.ignoreDownloadArchiveArgs, ["-o", "archive=false"])
    }

    func testTheProfileRunIgnoresTheArchive() {
        for limit in [1, 100, 1000] {
            let args = GalleryDlService.profileArguments(
                username: "someone.invented", postLimit: limit, outputDirectory: downloads,
                cookieBrowser: .chrome, cookieBrowserProfile: nil, cookiesFile: nil)
            assertIgnoresTheArchive(args, "\(limit)")
        }
    }

    func testTheSinglePostFallbackIgnoresTheArchiveOnEverySite() {
        let modes: [GalleryDlService.FolderMode] = [
            .flat, .perPostIfMultiple, .into(downloads.appendingPathComponent("a folder"), ownPost: "num == 1"),
        ]
        for link in links {
            for mode in modes {
                let args = GalleryDlService.arguments(
                    for: link, outputDirectory: downloads, folderMode: mode,
                    cookieBrowser: .chrome, cookiesFile: nil)
                assertIgnoresTheArchive(args, link)
            }
            let embedded = GalleryDlService.arguments(
                for: link, outputDirectory: downloads, cookieBrowser: .none, cookiesFile: "/tmp/cookies.txt",
                extraArgs: GalleryDlService.embeddedPostFailFastArgs)
            assertIgnoresTheArchive(embedded, link)
        }
    }

    /// The photo pass is the fallback's command line plus the site's
    /// `imageSweepArgs`.
    func testThePhotoPassIgnoresTheArchive() {
        var swept = 0
        for link in links {
            guard let sweepArgs = SiteRegistry.profile(for: link).imageSweepArgs else { continue }
            swept += 1
            let args = GalleryDlService.arguments(
                for: link, outputDirectory: downloads, folderMode: .perPost(always: "num == 1"),
                cookieBrowser: .chrome, cookiesFile: nil, extraArgs: sweepArgs)
            assertIgnoresTheArchive(args, link)
            XCTAssertTrue(args.contains("videos=false"), link)
        }
        XCTAssertGreaterThanOrEqual(swept, 2)
    }

    /// No site's own arguments, and no photo pass, name an archive or set
    /// the key again after the app switched it off.
    func testNoSiteArgumentsBringAnArchiveBack() {
        for profile in SiteRegistry.all {
            let own = profile.galleryDlArgs + (profile.imageSweepArgs ?? [])
            XCTAssertFalse(own.contains("--download-archive"), profile.id)
            XCTAssertTrue(archiveOptions(own).isEmpty, profile.id)
        }
    }

    /// Likes Sync has its own archive beside the files it saves, and
    /// records skipped files in it: untouched.
    func testLikesSyncKeepsItsOwnArchive() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@invented_one"), rootDirectory: downloads)
        let args = LikesSyncArgumentBuilder.make(plan: plan, cookieBrowser: .chrome, cookiesFile: nil).args

        XCTAssertFalse(args.contains("archive=false"))
        XCTAssertEqual(archiveOptions(args), ["archive-event=after,skip"])
        let flag = try XCTUnwrap(args.firstIndex(of: "--download-archive"))
        XCTAssertEqual(args[flag + 1], plan.archivePath.path)
        XCTAssertTrue(args.contains("--config-ignore"))
    }

    // MARK: - Helpers

    private func assertIgnoresTheArchive(
        _ args: [String], _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(archiveOptions(args), ["archive=false"], message, file: file, line: line)
        XCTAssertFalse(args.contains("--download-archive"), message, file: file, line: line)
    }

    /// Every value given to "-o" whose key is, or ends in, an archive key.
    private func archiveOptions(_ args: [String]) -> [String] {
        zip(args, args.dropFirst()).filter { $0.0 == "-o" }.map(\.1).filter { value in
            let key = value.prefix { $0 != "=" }
            return key.split(separator: ".").last.map { $0.hasPrefix("archive") } ?? false
        }
    }
}
