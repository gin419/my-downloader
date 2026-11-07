import XCTest

@testable import XDownloader

final class LikesSyncArgumentsTests: XCTestCase {
    func testPlanUsesPerHandleOutputAndArchivePaths() throws {
        let root = URL(fileURLWithPath: "/tmp/downloads")
        let plan = LikesSyncPlanner.plan(for: try LikesSyncHandle("@Gin"), rootDirectory: root)

        XCTAssertEqual(plan.outputDirectory.path, "/tmp/downloads/Twitter Likes/@gin")
        XCTAssertEqual(plan.archivePath.path, "/tmp/downloads/Twitter Likes/@gin/gallery-dl-archive.sqlite3")
        XCTAssertEqual(plan.url.absoluteString, "https://x.com/gin/likes")
    }

    func testArgumentsUseCookieFilePriorityAndLikesOptions() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@Gin"),
            rootDirectory: URL(fileURLWithPath: "/tmp/downloads")
        )
        let args = LikesSyncArgumentBuilder.make(
            plan: plan,
            cookieBrowser: .safari,
            cookiesFile: "/tmp/cookies.txt"
        ).args

        XCTAssertEqual(Array(args.prefix(2)), ["--cookies", "/tmp/cookies.txt"])
        XCTAssertFalse(args.contains("safari"))
        XCTAssertTrue(containsPair(args, "--dest", "/tmp/downloads/Twitter Likes/@gin"))
        XCTAssertTrue(containsPair(args, "--download-archive", "/tmp/downloads/Twitter Likes/@gin/gallery-dl-archive.sqlite3"))
        XCTAssertTrue(containsPair(args, "-D", "."))
        XCTAssertTrue(containsPair(args, "-o", "extractor.twitter.quoted=true"))
        XCTAssertTrue(containsPair(args, "-o", "extractor.twitter.retweets=true"))
        XCTAssertTrue(containsPair(args, "-o", "extractor.twitter.cards=false"))
        XCTAssertTrue(containsPair(args, "-o", "extractor.twitter.text-tweets=true"))
        XCTAssertTrue(containsPair(args, "-o", "archive-event=after,skip"))

        // PrintAction consumes the "<event>:" selector, so the event name is
        // re-embedded INSIDE the surviving format string — the emitted line
        // is "likes-sync\t<event>:{json}".
        for event in LikesSyncArgumentBuilder.eventNames {
            XCTAssertTrue(containsPair(args, "--Print", "\(event):likes-sync\t\(event):{_json}"))
        }
        XCTAssertEqual(args.last, "https://x.com/gin/likes")
    }

    /// The default trusts the archive: a file it lists is skipped even when
    /// it is gone from the folder.
    func testByDefaultTheArchiveDecidesWhatIsSkipped() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@Gin"),
            rootDirectory: URL(fileURLWithPath: "/tmp/downloads")
        )
        let implicit = LikesSyncArgumentBuilder.make(plan: plan, cookieBrowser: .chrome, cookiesFile: nil).args
        let explicit = LikesSyncArgumentBuilder.make(
            plan: plan, cookieBrowser: .chrome, cookiesFile: nil, redownloadMissing: false
        ).args

        XCTAssertEqual(implicit, explicit)
        XCTAssertTrue(containsPair(implicit, "--download-archive", plan.archivePath.path))
        XCTAssertTrue(containsPair(implicit, "-o", "archive-event=after,skip"))
    }

    /// With "download again files missing from the folder" on, no archive is
    /// named: gallery-dl skips a file already at its path and downloads a
    /// missing one. Everything else — destination, flat folder, file name,
    /// skip events — stays as it is.
    func testRedownloadMissingLeavesTheArchiveOut() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@Gin"),
            rootDirectory: URL(fileURLWithPath: "/tmp/downloads")
        )
        let normal = LikesSyncArgumentBuilder.make(plan: plan, cookieBrowser: .chrome, cookiesFile: nil).args
        let args = LikesSyncArgumentBuilder.make(
            plan: plan, cookieBrowser: .chrome, cookiesFile: nil, redownloadMissing: true
        ).args

        XCTAssertFalse(args.contains("--download-archive"))
        XCTAssertFalse(args.contains(plan.archivePath.path))
        XCTAssertFalse(args.contains { $0.hasPrefix("archive") })
        // A user's gallery-dl config can't bring an archive back.
        XCTAssertTrue(args.contains("--config-ignore"))
        // Nothing but the two archive options differs from the default.
        var expected = normal
        for (key, value) in [
            ("--download-archive", plan.archivePath.path), ("-o", "archive-event=after,skip"),
        ] {
            let index = try XCTUnwrap(
                expected.indices.first {
                    $0 + 1 < expected.count && expected[$0] == key && expected[$0 + 1] == value
                })
            expected.removeSubrange(index...index + 1)
        }
        XCTAssertEqual(args, expected)
        XCTAssertTrue(containsPair(args, "--dest", "/tmp/downloads/Twitter Likes/@gin"))
        XCTAssertTrue(containsPair(args, "-D", "."))
        XCTAssertTrue(
            containsPair(args, "-f", "{author[nick]} - {content!s:.100} [{tweet_id}] #{num}.{extension}"))
        XCTAssertTrue(containsPair(args, "--Print", "skip:likes-sync\tskip:{_json}"))
        XCTAssertEqual(args.last, "https://x.com/gin/likes")
    }

    /// Retrying failed Likes runs the same way as a full sync.
    func testRedownloadMissingAppliesToRetriedLinks() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@Gin"),
            rootDirectory: URL(fileURLWithPath: "/tmp/downloads")
        )
        let link = "https://x.com/someone/status/123"
        let args = LikesSyncArgumentBuilder.make(
            plan: plan, cookieBrowser: .chrome, cookiesFile: nil, inputURLs: [link],
            redownloadMissing: true
        ).args

        XCTAssertFalse(args.contains("--download-archive"))
        XCTAssertEqual(args.last, link)
    }

    func testArgumentsFallBackToCookieBrowserWithoutFile() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@Gin"),
            rootDirectory: URL(fileURLWithPath: "/tmp/downloads")
        )
        let args = LikesSyncArgumentBuilder.make(plan: plan, cookieBrowser: .chrome, cookiesFile: nil).args
        XCTAssertEqual(Array(args.prefix(2)), ["--cookies-from-browser", "chrome"])
    }

    func testArgumentsUseTheSelectedBrowserProfile() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@Gin"),
            rootDirectory: URL(fileURLWithPath: "/tmp/downloads")
        )
        let args = LikesSyncArgumentBuilder.make(
            plan: plan,
            cookieBrowser: .chrome,
            cookieBrowserProfile: "Default",
            cookiesFile: nil
        ).args
        XCTAssertEqual(Array(args.prefix(2)), ["--cookies-from-browser", "chrome:Default"])
    }

    func testFullScanHasNoAbortOption() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@Gin"),
            rootDirectory: URL(fileURLWithPath: "/tmp/downloads")
        )
        let args = LikesSyncArgumentBuilder.make(plan: plan, cookieBrowser: .safari, cookiesFile: nil).args
        XCTAssertFalse(args.contains("-A"))
        XCTAssertFalse(args.contains { $0.hasPrefix("skip=") })
    }

    /// Automatic sync's incremental scan: gallery-dl stops after N
    /// consecutive already-saved files. Still the whole Likes URL, still the
    /// per-account archive (which is what makes files count as skipped).
    func testIncrementalScanAbortsAfterConsecutiveSkips() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@Gin"),
            rootDirectory: URL(fileURLWithPath: "/tmp/downloads")
        )
        let args = LikesSyncArgumentBuilder.make(
            plan: plan, cookieBrowser: .safari, cookiesFile: nil,
            abortAfterConsecutiveSkips: LikesAutoSyncSchedule.abortAfterConsecutiveSkips
        ).args
        XCTAssertTrue(containsPair(args, "-A", "30"))
        XCTAssertTrue(containsPair(args, "--download-archive", plan.archivePath.path))
        XCTAssertEqual(args.last, "https://x.com/gin/likes")
    }

    func testNonPositiveAbortCountIsIgnored() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@Gin"),
            rootDirectory: URL(fileURLWithPath: "/tmp/downloads")
        )
        let args = LikesSyncArgumentBuilder.make(
            plan: plan, cookieBrowser: .safari, cookiesFile: nil, abortAfterConsecutiveSkips: 0
        ).args
        XCTAssertFalse(args.contains("-A"))
    }

    /// Both options together: no archive, and still the abort. gallery-dl
    /// counts a file already at its path as a skip just like an archived one
    /// (job.py `handle_url` → `handle_skip`), so the incremental scan still
    /// stops after N files in a row that are in the folder.
    func testRedownloadMissingKeepsTheIncrementalAbort() throws {
        let plan = LikesSyncPlanner.plan(
            for: try LikesSyncHandle("@Gin"),
            rootDirectory: URL(fileURLWithPath: "/tmp/downloads")
        )
        let args = LikesSyncArgumentBuilder.make(
            plan: plan, cookieBrowser: .safari, cookiesFile: nil,
            redownloadMissing: true,
            abortAfterConsecutiveSkips: LikesAutoSyncSchedule.abortAfterConsecutiveSkips
        ).args
        XCTAssertTrue(containsPair(args, "-A", "30"))
        XCTAssertFalse(args.contains("--download-archive"))
        XCTAssertFalse(args.contains { $0.hasPrefix("archive") })
        XCTAssertTrue(containsPair(args, "--Print", "skip:likes-sync\tskip:{_json}"))
        XCTAssertEqual(args.last, "https://x.com/gin/likes")
    }

    func testVerificationIsBoundedAndNeverDownloads() throws {
        let args = LikesSyncArgumentBuilder.makeVerification(
            handle: try LikesSyncHandle("@gin"), cookieBrowser: .safari, cookiesFile: nil
        ).args
        XCTAssertTrue(args.contains("--simulate"))
        XCTAssertTrue(containsPair(args, "--range", "1"))
        XCTAssertTrue(containsPair(args, "--print", "post:likes-verify\t{tweet_id}"))
        XCTAssertFalse(args.contains("--Print"))
    }

    private func containsPair(_ args: [String], _ key: String, _ value: String) -> Bool {
        args.indices.contains { index in
            index + 1 < args.count && args[index] == key && args[index + 1] == value
        }
    }
}
