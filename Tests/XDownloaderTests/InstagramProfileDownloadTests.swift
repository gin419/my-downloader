import Combine
import XCTest

@testable import XDownloader

/// An Instagram profile link through DownloadManager itself: the account's
/// newest posts, capped by the number in Settings, in one gallery-dl run —
/// yt-dlp never starts — and one profile at a time across the app, while a
/// single post pasted beside it goes ahead. The yt-dlp and gallery-dl the
/// manager is given are scripts that record their arguments and when they
/// began and ended; gallery-dl holds until the test lets it go, then saves
/// one synthetic file the way it reports one. Nothing here touches the
/// network, a browser or a cookie. Every username and code is invented.
@MainActor
final class InstagramProfileDownloadTests: XCTestCase {

    private let firstProfile = "https://www.instagram.com/someone_invented/"
    private let secondProfile = "https://www.instagram.com/another_invented/"
    private let post = "https://www.instagram.com/p/SYNpost0009_/"

    private var root: URL!
    private var downloads: URL!
    private var history: HistoryStore!
    /// "begin <account>", "end <account>" and "overlap <account>" lines, as
    /// gallery-dl runs.
    private var galleryDlLog: URL!
    /// Each start's arguments, one per line, runs apart by a "--" line.
    private var galleryDlArguments: URL!
    /// The process gallery-dl last ran as.
    private var galleryDlProcessID: URL!
    /// gallery-dl holds until this file exists.
    private var release: URL!
    /// Exists only if the manager started yt-dlp; one line per start.
    private var ytDlpMark: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("InstagramProfileDownloadTests-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        history = HistoryStore(directory: root.appendingPathComponent("stores"))
        galleryDlLog = root.appendingPathComponent("gallery-dl-log")
        galleryDlArguments = root.appendingPathComponent("gallery-dl-arguments")
        galleryDlProcessID = root.appendingPathComponent("gallery-dl-process")
        release = root.appendingPathComponent("release")
        ytDlpMark = root.appendingPathComponent("yt-dlp-ran")
    }

    override func tearDownWithError() throws {
        // A held gallery-dl ends by itself once its folder is gone.
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The run

    func testProfileLinkStartsGalleryDlWithTheCapAndNeverYtDlp() async throws {
        letGo()
        let manager = try makeManager()
        manager.cookieBrowser = .chrome
        manager.cookieBrowserProfile = ""
        manager.instagramProfilePostLimit = 7

        let result = manager.capture(text: "https://WWW.INSTAGRAM.COM/Someone_Invented/reels/?igsh=SYNtracking", source: .field)

        XCTAssertEqual(result.queued, 1)
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.url, firstProfile)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.title, "someone_invented - newest 7 posts")
        XCTAssertEqual(item.imageCount, 1)
        XCTAssertEqual(item.progress, 1)
        XCTAssertEqual(try starts(of: ytDlpMark), 0)
        let runs = try galleryDlRuns()
        XCTAssertEqual(runs.count, 1)
        let expected = GalleryDlService.profileArguments(
            username: "someone_invented", postLimit: 7, outputDirectory: downloads,
            cookieBrowser: .chrome, cookieBrowserProfile: "", cookiesFile: nil)
        XCTAssertEqual(runs.first, expected)
        XCTAssertTrue(expected.contains("max-posts=7"))
        XCTAssertEqual(Array(expected.prefix(2)), ["--cookies-from-browser", "chrome"])
        XCTAssertEqual(expected.last, "https://www.instagram.com/someone_invented/posts/")
        // A lone image keeps the name gallery-dl gave it, so the next paste
        // finds it and skips it.
        XCTAssertEqual(try contents(of: downloads), ["someone_invented - synthetic [SYNpost0001_] #1.jpg"])
        let entry = try XCTUnwrap(history.mostRecentCompleted(for: firstProfile))
        XCTAssertEqual(entry.site, "instagram")
        XCTAssertEqual(entry.title, "someone_invented - newest 7 posts")
    }

    /// The number is the one Settings held when the row started.
    func testTheCapIsReadWhenTheRowStarts() async throws {
        let manager = try makeManager()
        manager.instagramProfilePostLimit = 250
        manager.capture(text: firstProfile, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("gallery-dl started") { self.begun() == 1 }

        manager.instagramProfilePostLimit = 3
        letGo()

        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.title, "someone_invented - newest 250 posts")
        XCTAssertTrue(try XCTUnwrap(galleryDlRuns().first).contains("max-posts=250"))
    }

    /// A pasted profile is not held against its history: pasting it again
    /// is how what it posted since is fetched.
    func testPastingAProfileAgainAfterItFinishedIsNotAskedAbout() async throws {
        letGo()
        let manager = try makeManager()
        manager.capture(text: firstProfile, source: .field)
        let first = try XCTUnwrap(manager.items.first)
        try await waitUntil("the first download finished") { self.history.count() == 1 }
        manager.removeItem(first)

        let again = manager.capture(text: firstProfile, source: .field)

        XCTAssertEqual(again.queued, 1)
        XCTAssertEqual(again.toConfirm, 0)
        XCTAssertNil(manager.pendingDuplicates)
        try await waitUntil("the second download finished") { self.history.count() == 2 }
        // The file of the first run was skipped, not fetched again.
        XCTAssertEqual(try contents(of: downloads), ["someone_invented - synthetic [SYNpost0001_] #1.jpg"])
        XCTAssertEqual(try XCTUnwrap(manager.items.first).status, .completed)
    }

    /// Pasting a profile whose row is still listed as Done runs that row
    /// again: that is how what it posted since is fetched.
    func testPastingADoneProfileAgainRunsItAgain() async throws {
        letGo()
        let manager = try makeManager()
        manager.capture(text: firstProfile, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the first download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)

        let again = manager.capture(text: "https://instagram.com/Someone_Invented/posts/", source: .field)

        XCTAssertEqual(again.queued, 1)
        XCTAssertEqual(again.alreadyPresent, 0)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(item.status, .queued)
        // The same row runs again, so history keeps its one entry.
        try await waitUntil("the second download finished") { self.begun() == 2 && item.status == .completed }
        XCTAssertEqual(try galleryDlRuns().count, 2)
    }

    /// A profile row that is still running stays as it is when pasted again.
    func testPastingARunningProfileAgainPointsAtItsRow() async throws {
        let manager = try makeManager()
        manager.capture(text: firstProfile, source: .field)
        try await waitUntil("gallery-dl started") { self.begun() == 1 }

        let again = manager.capture(text: firstProfile, source: .field)

        XCTAssertEqual(again.queued, 0)
        XCTAssertEqual(again.alreadyPresent, 1)
        letGo()
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(begun(), 1)
    }

    /// A failed profile row walks an account with the Instagram login, so
    /// opening the app again leaves it failed. The same holds for a row
    /// 1.12.0 turned down as a profile link: after the upgrade it must not
    /// start a walk nobody pasted. A failed single post is re-queued, as
    /// every other failed row always has been.
    func testFailedProfileRowsAreNotRestartedWhenTheAppOpens() async throws {
        letGo()
        let queue = QueueStore(directory: root.appendingPathComponent("saved-queue"))
        let refusedIn1120 =
            "This Instagram link isn't a single post, reel or story — XDownloader doesn't download whole Instagram accounts. Open the post, reel or story on Instagram and paste its own link instead."
        let failed: [(String, String)] = [
            (firstProfile, GalleryDlService.noPostsMessage),
            ("https://www.instagram.com/another_invented/reels/", refusedIn1120),
            ("https://INSTAGR.AM/third_invented/", refusedIn1120),
            (post, "An earlier failure"),
        ]
        queue.save(
            failed.map { link, message in
                let item = DownloadItem(url: link)
                item.status = .failed(message)
                return item.toPersisted()
            })

        let manager = try makeManager(queue: queue)

        XCTAssertEqual(manager.items.count, 4)
        try await waitUntil("the single post ran again") { (try? self.starts(of: self.ytDlpMark)) == 1 }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(begun(), 0)
        for (link, message) in failed.dropLast() {
            XCTAssertEqual(try item(link, in: manager).status, .failed(message), link)
        }
        // Asked for, it runs.
        manager.retryItem(try item(firstProfile, in: manager))
        try await waitUntil("the retried profile finished") { self.begun() == 1 && self.history.count() == 2 }
    }

    func testAnAccountWithNoPostsFailsOnceAndIsNotRetried() async throws {
        letGo()
        let manager = try makeManager(galleryDlSaves: false)

        manager.capture(text: firstProfile, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the run ended") { self.history.count() == 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(item.status, .failed(GalleryDlService.noPostsMessage))
        XCTAssertFalse(item.autoRetryAttempted)
        XCTAssertEqual(begun(), 1)
        XCTAssertEqual(try starts(of: ytDlpMark), 0)
    }

    func testMissingGalleryDlIsNamed() async throws {
        let manager = try makeManager(galleryDlInstalled: false)

        manager.capture(text: firstProfile, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the run ended") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .failed(DownloadManager.instagramProfileNeedsGalleryDlMessage))
        XCTAssertEqual(try starts(of: ytDlpMark), 0)
    }

    // MARK: - Errors during the run

    /// A post that fails among others is no verdict on the run: the row
    /// never reads Failed, and a run that exits 0 is done.
    func testAnErrorLineMidRunLeavesTheRowAloneAndTheRunCompletes() async throws {
        letGo()
        let manager = try makeManager(
            galleryDlSays: savesPost("SYNpost0001_") + "\n" + Self.printsRawError + "\n" + savesPost("SYNpost0003_"))
        manager.capture(text: firstProfile, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        let statuses = record(item)

        try await waitUntil("the run ended") { self.history.count() == 1 }

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.imageCount, 2)
        XCTAssertEqual(statuses.values.filter(\.isFailed), [])
        XCTAssertEqual(statuses.values.last, .completed)
        XCTAssertTrue(statuses.values.contains(.downloading))
    }

    /// Exit non-zero after a file landed: the partial outcome, its cause
    /// named from the exit code, never the raw line, and no Failed before
    /// the end.
    func testAnErrorLineThenAFailedExitEndsInThePartialWording() async throws {
        letGo()
        let manager = try makeManager(
            galleryDlSays: savesPost("SYNpost0001_") + "\n" + Self.printsRawError, galleryDlExit: 4)
        manager.capture(text: firstProfile, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        let statuses = record(item)

        try await waitUntil("the run ended") { self.history.count() == 1 }

        let expected = GalleryDlService.partialFailureMessage(savedCount: 1, firstError: "a network/HTTP error")
        XCTAssertEqual(item.status, .failed(expected))
        XCTAssertEqual(
            expected, "Saved 1 file, but one or more downloads failed — a network/HTTP error. Retry fetches the rest.")
        XCTAssertEqual(statuses.values.filter(\.isFailed), [.failed(expected)])
        XCTAssertEqual(statuses.values.last, .failed(expected))
        XCTAssertFalse(statuses.values.contains { $0.failureMessage?.contains("[download]") == true })
    }

    /// Nothing saved: an error with app-native copy is the message, given
    /// only once the tool has exited.
    func testAKnownErrorWithNothingSavedIsItsOwnCopyAtTheEnd() async throws {
        letGo()
        let manager = try makeManager(
            galleryDlSays: "echo '[instagram][error] HTTP redirect to login page (https://www.instagram.com/accounts/login/)'",
            galleryDlExit: 4)
        manager.capture(text: firstProfile, source: .field)
        let item = try XCTUnwrap(manager.items.first)
        let statuses = record(item)

        try await waitUntil("the run ended") { self.history.count() == 1 }

        XCTAssertEqual(item.status, .failed(GalleryDlService.instagramLoginMessage))
        XCTAssertEqual(statuses.values.filter(\.isFailed), [.failed(GalleryDlService.instagramLoginMessage)])
    }

    /// Nothing saved and no copy for the error: the exit code's causes,
    /// not the raw line.
    func testAnUnknownErrorWithNothingSavedIsTheExitsCauses() async throws {
        letGo()
        let manager = try makeManager(galleryDlSays: Self.printsRawError, galleryDlExit: 4)
        manager.capture(text: firstProfile, source: .field)
        let item = try XCTUnwrap(manager.items.first)

        try await waitUntil("the run ended") { self.history.count() == 1 }

        XCTAssertEqual(item.status, .failed("gallery-dl failed: a network/HTTP error (code 4)"))
    }

    /// A second paste reports the first run's file as skipped. When the run
    /// then saves one new file and fails, "Saved" counts only the new one.
    func testThePartialCountLeavesOutFilesSavedBefore() async throws {
        letGo()
        let existing = downloads.appendingPathComponent("someone_invented - synthetic [SYNpost0001_] #1.jpg")
        try Data("synthetic".utf8).write(to: existing)
        let manager = try makeManager(
            galleryDlSays: "echo \"# \(existing.path)\"\n" + savesPost("SYNpost0002_") + "\n" + Self.printsRawError,
            galleryDlExit: 4)
        manager.capture(text: firstProfile, source: .field)
        let item = try XCTUnwrap(manager.items.first)

        try await waitUntil("the run ended") { self.history.count() == 1 }

        XCTAssertEqual(
            item.status,
            .failed("Saved 1 file, but one or more downloads failed — a network/HTTP error. Retry fetches the rest."))
    }

    /// A mapped error that is already a whole sentence ending in "then
    /// Retry." is closed once, without a second Retry.
    func testALoginRedirectAfterAFileIsOneSentence() async throws {
        letGo()
        let manager = try makeManager(
            galleryDlSays: savesPost("SYNpost0001_") + "\n"
                + "echo '[instagram][error] HTTP redirect to login page (https://www.instagram.com/accounts/login/)'",
            galleryDlExit: 4)
        manager.capture(text: firstProfile, source: .field)
        let item = try XCTUnwrap(manager.items.first)

        try await waitUntil("the run ended") { self.history.count() == 1 }

        XCTAssertEqual(
            item.status,
            .failed("Saved 1 file, but one or more downloads failed — \(GalleryDlService.instagramLoginMessage)"))
    }

    /// A renamed, deleted or mistyped account is named as such, not as a
    /// network error that never happened.
    func testAnAccountThatIsNotFoundIsNamed() async throws {
        letGo()
        let manager = try makeManager(
            galleryDlSays: "echo '[instagram][error] NotFoundError: Requested user could not be found'",
            galleryDlExit: 4)
        manager.capture(text: firstProfile, source: .field)
        let item = try XCTUnwrap(manager.items.first)

        try await waitUntil("the run ended") { self.history.count() == 1 }

        XCTAssertEqual(item.status, .failed(GalleryDlService.instagramAccountNotFoundMessage))
    }

    /// A private account the login doesn't follow gets the app's own copy,
    /// never gallery-dl's warning, whether the run exits 0 or not.
    func testAPrivateAccountGetsItsOwnCopy() async throws {
        letGo()
        let warning = "echo \"[instagram][warning] someone_invented's posts are private\""
        let quiet = try makeManager(galleryDlSays: warning)
        quiet.capture(text: firstProfile, source: .field)
        let first = try XCTUnwrap(quiet.items.first)
        try await waitUntil("the first run ended") { self.history.count() == 1 }
        XCTAssertEqual(first.status, .failed(GalleryDlService.instagramPrivateAccountMessage))

        let failing = try makeManager(galleryDlSays: warning, galleryDlExit: 4)
        failing.capture(text: secondProfile, source: .field)
        let second = try XCTUnwrap(failing.items.first)
        try await waitUntil("the second run ended") { self.history.count() == 2 }
        XCTAssertEqual(second.status, .failed(GalleryDlService.instagramPrivateAccountMessage))
    }

    /// A Done row counts only what this run saved, and Show in Finder points
    /// at something that is there: a new file, or the folder when every file
    /// was skipped and the reported one has since gone.
    func testTheDoneRowCountsOnlyNewFilesAndPointsAtAFileThatExists() async throws {
        letGo()
        let gone = downloads.appendingPathComponent("someone_invented - moved [SYNpost0001_] #1.jpg").path
        let skipsOnly = try makeManager(galleryDlSays: "echo \"# \(gone)\"")
        skipsOnly.capture(text: firstProfile, source: .field)
        let first = try XCTUnwrap(skipsOnly.items.first)
        try await waitUntil("the first run ended") { self.history.count() == 1 }
        XCTAssertEqual(first.status, .completed)
        XCTAssertNil(first.imageCount)
        XCTAssertEqual(first.outputPath, downloads.path)

        let mixed = try makeManager(galleryDlSays: "echo \"# \(gone)\"\n" + savesPost("SYNpost0002_"))
        mixed.capture(text: secondProfile, source: .field)
        let second = try XCTUnwrap(mixed.items.first)
        try await waitUntil("the second run ended") { self.history.count() == 2 }
        XCTAssertEqual(second.status, .completed)
        XCTAssertEqual(second.imageCount, 1)
        XCTAssertEqual(
            second.outputPath, downloads.appendingPathComponent("another_invented - synthetic [SYNpost0002_] #1.jpg").path)
    }

    /// Another site keeps showing the error as it arrives.
    func testParsingOutsideAProfileRunStillSetsTheError() {
        let item = DownloadItem(url: post)
        GalleryDlService.parseLine("[download][error] Failed to download SYNpost0009_ #1.mp4", item: item)
        XCTAssertEqual(item.status, .failed("[download][error] Failed to download SYNpost0009_ #1.mp4"))

        let profileItem = DownloadItem(url: firstProfile)
        GalleryDlService.parseLine(
            "[download][error] Failed to download SYNpost0009_ #1.mp4", item: profileItem, settlesErrorsAtExit: true)
        XCTAssertEqual(profileItem.status, .queued)
        XCTAssertNil(profileItem.firstToolError)
    }

    // MARK: - One profile at a time

    func testProfilesTakeTurnsWhileASinglePostGoesAhead() async throws {
        let manager = try makeManager()
        XCTAssertEqual(manager.maxConcurrent, 2)

        let result = manager.capture(text: "\(firstProfile)\n\(secondProfile)\n\(post)", source: .field)

        XCTAssertEqual(result.queued, 3)
        let first = try item(firstProfile, in: manager)
        let second = try item(secondProfile, in: manager)
        let single = try item(post, in: manager)
        try await waitUntil("the first profile reached gallery-dl") { self.begun() == 1 }
        // The post has the second slot, and finishes while the first
        // profile still runs.
        try await waitUntil("the post finished") { single.status == .completed }
        XCTAssertEqual(try starts(of: ytDlpMark), 1)
        XCTAssertEqual(second.status, .queued)
        XCTAssertEqual(begun(), 1)
        XCTAssertNotEqual(first.status, .completed)

        letGo()

        try await waitUntil("both profiles finished") { self.history.count() == 3 }
        XCTAssertEqual(first.status, .completed)
        XCTAssertEqual(second.status, .completed)
        XCTAssertEqual(
            try log(),
            ["begin someone_invented", "end someone_invented", "begin another_invented", "end another_invented"])
        XCTAssertEqual(
            try galleryDlRuns().map(\.last),
            [
                "https://www.instagram.com/someone_invented/posts/", "https://www.instagram.com/another_invented/posts/",
            ])
    }

    /// The limit holds whatever the concurrency setting.
    func testProfilesTakeTurnsAtAnyConcurrency() async throws {
        let manager = try makeManager()
        manager.maxConcurrent = 5
        let third = "https://www.instagram.com/third_invented/"

        manager.capture(text: "\(firstProfile)\n\(secondProfile)\n\(third)", source: .field)

        try await waitUntil("the first profile reached gallery-dl") { self.begun() == 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(begun(), 1)
        XCTAssertEqual(try item(secondProfile, in: manager).status, .queued)
        XCTAssertEqual(try item(third, in: manager).status, .queued)

        letGo()

        try await waitUntil("every profile finished") { self.history.count() == 3 }
        XCTAssertFalse(try log().contains { $0.hasPrefix("overlap") })
        XCTAssertEqual(begun(), 3)
    }

    func testRemovingAWaitingProfileNeverStartsTheTool() async throws {
        let manager = try makeManager()
        manager.capture(text: "\(firstProfile)\n\(secondProfile)", source: .field)
        let second = try item(secondProfile, in: manager)
        try await waitUntil("the first profile reached gallery-dl") { self.begun() == 1 }
        XCTAssertEqual(second.status, .queued)

        manager.removeItem(second)
        letGo()

        try await waitUntil("the first profile finished") { self.history.count() == 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(begun(), 1)
        XCTAssertEqual(try log(), ["begin someone_invented", "end someone_invented"])
        XCTAssertEqual(manager.items.map(\.url), [firstProfile])
        XCTAssertEqual(history.count(), 1)
    }

    /// The row's ✕ ends the running gallery-dl, and the next profile gets
    /// its turn.
    func testRemovingTheRunningProfileEndsGalleryDlAndPassesTheTurnOn() async throws {
        let manager = try makeManager()
        manager.capture(text: "\(firstProfile)\n\(secondProfile)", source: .field)
        let first = try item(firstProfile, in: manager)
        try await waitUntil("the first profile reached gallery-dl") { self.begun() == 1 }
        let processID = try XCTUnwrap(pid_t(String(contentsOf: galleryDlProcessID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        manager.removeItem(first)

        try await waitUntil("the second profile reached gallery-dl") { self.begun() == 2 }
        XCTAssertEqual(kill(processID, 0), -1, "the removed row's gallery-dl is still running")
        letGo()
        try await waitUntil("the second profile finished") { self.history.count() == 1 }
        XCTAssertEqual(try log(), ["begin someone_invented", "begin another_invented", "end another_invented"])
        XCTAssertEqual(manager.items.map(\.url), [secondProfile])
    }

    // MARK: - One row per profile

    func testTheSameProfileInTwoSpellingsIsOneRow() async throws {
        let manager = try makeManager()
        XCTAssertEqual(manager.capture(text: firstProfile, source: .field).queued, 1)
        try await waitUntil("the profile reached gallery-dl") { self.begun() == 1 }

        for spelling in [
            "https://instagram.com/Someone_Invented",
            "https://m.instagram.com/someone_invented/posts/?igsh=SYNtracking",
            "https://instagr.am/someone_invented/reels/",
        ] {
            let again = manager.capture(text: spelling, source: .field)
            XCTAssertEqual(again.queued, 0, spelling)
            XCTAssertEqual(again.alreadyPresent, 1, spelling)
        }
        // Pasted together, too.
        let together = manager.capture(text: "\(secondProfile) https://www.instagram.com/Another_Invented/posts", source: .field)
        XCTAssertEqual(together.queued, 1)

        XCTAssertEqual(manager.items.map(\.url), [secondProfile, firstProfile])
        letGo()
        try await waitUntil("both finished") { self.history.count() == 2 }
        XCTAssertEqual(begun(), 2)
    }

    // MARK: - The setting

    func testThePostLimitSetting() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "instagram-profile-\(UUID().uuidString)"))
        let manager = try makeManager(defaults: defaults)
        XCTAssertEqual(manager.instagramProfilePostLimit, 100)

        manager.instagramProfilePostLimit = 0
        XCTAssertEqual(manager.instagramProfilePostLimit, 1)
        manager.instagramProfilePostLimit = 5000
        XCTAssertEqual(manager.instagramProfilePostLimit, 1000)
        manager.instagramProfilePostLimit = 42
        manager.saveSettings()

        let reopened = DownloadManager(
            history: history,
            queueStore: QueueStore(directory: root.appendingPathComponent("queue-\(UUID().uuidString)")),
            settingsStore: SettingsStore(defaults: defaults),
            likesSyncStore: LikesSyncStore(directory: root.appendingPathComponent("stores")),
            galleryDlPathProvider: { nil },
            ytDlpPathProvider: { nil })
        XCTAssertEqual(reopened.instagramProfilePostLimit, 42)
    }

    // MARK: - Helpers

    /// Prints a per-file error as gallery-dl logs it; no copy maps it.
    private static let printsRawError =
        "echo '[download][error] Failed to download someone_invented - two [SYNpost0002_] #1.mp4'"

    /// Shell lines that save one synthetic image of `code` and report it.
    /// gallery-dl logs to stderr; stdout here keeps the lines in order.
    private func savesPost(_ code: String) -> String {
        """
        file="$dest/$account - synthetic [\(code)] #1.jpg"
        printf 'synthetic' > "$file"
        echo "$file"
        """
    }

    /// Every status the row passes through, from now on.
    private final class StatusLog {
        var values: [DownloadStatus] = []
        var subscription: AnyCancellable?
    }

    private func record(_ item: DownloadItem) -> StatusLog {
        let log = StatusLog()
        log.subscription = item.$status.sink { log.values.append($0) }
        return log
    }

    private func letGo() {
        FileManager.default.createFile(atPath: release.path, contents: Data())
    }

    private func item(_ link: String, in manager: DownloadManager) throws -> DownloadItem {
        try XCTUnwrap(manager.items.first { $0.url == link }, link)
    }

    private func log() throws -> [String] {
        guard FileManager.default.fileExists(atPath: galleryDlLog.path) else { return [] }
        return try String(contentsOf: galleryDlLog, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func begun() -> Int {
        ((try? log()) ?? []).filter { $0.hasPrefix("begin ") }.count
    }

    private func galleryDlRuns() throws -> [[String]] {
        let lines = try String(contentsOf: galleryDlArguments, encoding: .utf8).components(separatedBy: "\n")
        var runs: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line == "--" {
                runs.append(current)
                current = []
            } else if !line.isEmpty {
                current.append(line)
            }
        }
        return runs
    }

    private func starts(of mark: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: mark.path) else { return 0 }
        return try String(contentsOf: mark, encoding: .utf8).split(separator: "\n").count
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// A manager on temporary stores. Its gallery-dl, handed a profile's
    /// posts tab, records its arguments and its begin, holds until `release`
    /// exists (or the test's folder is gone), then — with `galleryDlSaves` —
    /// saves one image named the way the Instagram template names one,
    /// skipping it when it is already there, as gallery-dl does; handed
    /// anything else it is a single post's photo pass and finds nothing. Its
    /// yt-dlp saves one video.
    /// `galleryDlSays`, when given, replaces the one saved image: shell lines
    /// run once gallery-dl is let go, before it exits with `galleryDlExit`.
    private func makeManager(
        galleryDlSaves: Bool = true, galleryDlInstalled: Bool = true, defaults: UserDefaults? = nil,
        galleryDlSays: String? = nil, galleryDlExit: Int32 = 0, queue: QueueStore? = nil
    ) throws -> DownloadManager {
        let galleryDlScript = root.appendingPathComponent("gallery-dl")
        let ytDlpScript = root.appendingPathComponent("yt-dlp")
        let running = root.appendingPathComponent("gallery-dl-running")
        let saving =
            galleryDlSaves
            ? """
            file="$dest/$account - synthetic [SYNpost0001_] #1.jpg"
            if [ -f "$file" ]; then
                echo "# $file"
            else
                printf 'synthetic' > "$file"
                echo "$file"
            fi
            """
            : ""
        let galleryDl = """
            #!/bin/sh
            dest=""
            previous=""
            for argument in "$@"; do
                if [ "$previous" = "--dest" ]; then dest="$argument"; fi
                previous="$argument"
                last="$argument"
            done
            # A single post's photo pass after its video: nothing to find.
            case "$last" in
                */posts/) ;;
                *) exit 0 ;;
            esac
            printf '%s\\n' "$@" -- >> "\(galleryDlArguments.path)"
            echo $$ > "\(galleryDlProcessID.path)"
            account=$(printf '%s' "$last" | cut -d/ -f4)
            if ! mkdir "\(running.path)" 2>/dev/null; then echo "overlap $account" >> "\(galleryDlLog.path)"; fi
            trap 'rmdir "\(running.path)" 2>/dev/null; exit 143' TERM
            echo "begin $account" >> "\(galleryDlLog.path)"
            while [ ! -f "\(release.path)" ] && [ -d "\(root.path)" ]; do sleep 0.05; done
            \(galleryDlSays ?? saving)
            echo "end $account" >> "\(galleryDlLog.path)"
            rmdir "\(running.path)" 2>/dev/null
            exit \(galleryDlExit)

            """
        let videoPath = downloads.appendingPathComponent("synthetic.mp4").path
        let ytDlp = """
            #!/bin/sh
            echo started >> "\(ytDlpMark.path)"
            printf 'synthetic' > "\(videoPath)"
            echo "[download] Destination: \(videoPath)"
            echo "[download] 100% of 9.00B in 00:00"
            exit 0

            """
        try Data(galleryDl.utf8).write(to: galleryDlScript)
        try Data(ytDlp.utf8).write(to: ytDlpScript)
        for script in [galleryDlScript, ytDlpScript] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let manager = DownloadManager(
            history: history,
            queueStore: queue ?? QueueStore(directory: root.appendingPathComponent("queue-\(UUID().uuidString)")),
            settingsStore: SettingsStore(
                defaults: try defaults ?? XCTUnwrap(UserDefaults(suiteName: "instagram-profile-\(UUID().uuidString)"))),
            likesSyncStore: LikesSyncStore(directory: root.appendingPathComponent("stores")),
            galleryDlPathProvider: { galleryDlInstalled ? galleryDlScript.path : nil },
            ytDlpPathProvider: { ytDlpScript.path })
        manager.outputDirectory = downloads
        if queue == nil { XCTAssertEqual(manager.items.count, 0) }
        XCTAssertEqual(manager.instagramProfilePostLimit, InstagramProfilePosts.defaultLimit)
        return manager
    }

    private func waitUntil(
        _ what: String, seconds: TimeInterval = 10, line: UInt = #line, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting until \(what)", line: line)
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

extension DownloadStatus {
    fileprivate var isFailed: Bool { failureMessage != nil }

    fileprivate var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
