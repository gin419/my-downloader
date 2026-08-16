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
