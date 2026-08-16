import XCTest

@testable import XDownloader

/// A multi-file post where one file errors: gallery-dl prints the specific
/// error, keeps going, and the NEXT successful file's path line flips the item
/// back to `.downloading` — erasing the specific cause. The run then ends with
/// a non-zero exit and the generic exit-bitmask message despite files on disk.
/// The specific first error must survive in `firstToolError` so the exit
/// handling can compose a truthful partial-failure message.
@MainActor
final class GalleryDlFirstErrorRecordTests: XCTestCase {

    private let raw404Line =
        "[twitter][error] HttpError: '404 Not Found' for 'https://pbs.twimg.com/media/second.jpg'"
    private let nsfwLine = "[twitter][error] AuthorizationError: NSFW Tweet"
    private let fileLine = "/tmp/out/gin - four photos [123] #3.jpg"

    func testErrorLineIsRecordedInFirstToolError() {
        let item = DownloadItem(url: "https://x.com/a/status/123")
        GalleryDlService.parseLine(raw404Line, item: item)

        XCTAssertEqual(item.status, .failed(raw404Line), "unmapped errors keep the verbatim line")
        XCTAssertEqual(item.firstToolError, raw404Line)
    }

    func testMappedErrorLineIsRecordedInItsMappedForm() {
        // The partial-failure message embeds the recorded error, so it must be
        // the same app-native copy the status would have carried.
        let item = DownloadItem(url: "https://x.com/a/status/123")
        GalleryDlService.parseLine(nsfwLine, item: item)

        XCTAssertEqual(item.firstToolError, GalleryDlService.nsfwTweetMessage)
    }

    func testInstagramLoginErrorIsRecordedInFirstToolError() {
        let item = DownloadItem(url: "https://www.instagram.com/p/Daoe_4TTVY0/")
        GalleryDlService.parseLine(
            "[instagram][error] HTTP redirect to login page (https://www.instagram.com/accounts/login/)",
            item: item)

        XCTAssertEqual(item.firstToolError, GalleryDlService.instagramLoginMessage)
    }

    func testLaterFileLineKeepsStatusFlipButFieldSurvives() {
        // The status flip is deliberate — the run IS downloading again — but
        // it must no longer be the only record of the error.
        let item = DownloadItem(url: "https://x.com/a/status/123")
        GalleryDlService.parseLine(raw404Line, item: item)
        GalleryDlService.parseLine(fileLine, item: item)

        XCTAssertEqual(item.status, .downloading)
        XCTAssertEqual(item.outputPath, fileLine)
        XCTAssertEqual(item.imageCount, 1)
        XCTAssertEqual(item.firstToolError, raw404Line, "the recorded error must survive the flip")
    }

    func testFirstErrorWinsOverLaterErrors() {
        // After a path line flips the status back to .downloading, a second
        // error re-fails the item — but the FIRST error stays the recorded one.
        let item = DownloadItem(url: "https://x.com/a/status/123")
        GalleryDlService.parseLine(raw404Line, item: item)
        GalleryDlService.parseLine(fileLine, item: item)
        GalleryDlService.parseLine(nsfwLine, item: item)

        XCTAssertEqual(item.firstToolError, raw404Line)
    }

    func testWarningAndWaitLinesAreNotRecordedAsErrors() {
        let item = DownloadItem(url: "https://x.com/a/status/123")
        GalleryDlService.parseLine("[twitter][warning] API errors (1/10)", item: item)
        GalleryDlService.parseLine(
            "[twitter][info] Waiting for 14 minutes until 12:34:56 (rate limit)", item: item)

        XCTAssertNil(item.firstToolError)
    }

    func testResetForReattemptClearsFirstToolError() {
        // Per-attempt parse state: a gallery-dl fallback or auto-retry within
        // one run must start with a clean slate.
        let item = DownloadItem(url: "https://x.com/a/status/123")
        GalleryDlService.parseLine(raw404Line, item: item)
        item.resetForReattempt()

        XCTAssertNil(item.firstToolError)
    }

    /// `imageCount`/`videoCount` include dedupe skips by design (they
    /// describe what's on disk) — `newToolFileCount` answers the different
    /// question "did THIS run land anything?" and must ignore "# " skip
    /// lines.
    func testNewToolFileCountIgnoresDedupeSkipLines() {
        let item = DownloadItem(url: "https://x.com/a/status/123")
        GalleryDlService.parseLine("# /tmp/out/gin - four photos [123] #1.jpg", item: item)
        XCTAssertEqual(item.imageCount, 1)
        XCTAssertEqual(item.newToolFileCount, 0)

        GalleryDlService.parseLine(fileLine, item: item)
        XCTAssertEqual(item.imageCount, 2)
        XCTAssertEqual(item.newToolFileCount, 1)

        item.resetForReattempt()
        XCTAssertEqual(item.newToolFileCount, 0)
    }
}

/// The truthful partial message a non-zero exit composes once files DID land
/// and an error was recorded: name the saved count and the first error
/// instead of the exit bitmask's generic guess.
@MainActor
final class GalleryDlPartialFailureMessageTests: XCTestCase {

    func testPartialMessageNamesSavedCountAndFirstError() {
        let error = "[twitter][error] HttpError: '404 Not Found' for 'https://pbs.twimg.com/media/x.jpg'"
        XCTAssertEqual(
            GalleryDlService.partialFailureMessage(savedCount: 3, firstError: error),
            "Saved 3 files, but one or more downloads failed — \(error). Retry fetches the rest.")
    }

    func testPartialMessageUsesSingularForOneFile() {
        XCTAssertEqual(
            GalleryDlService.partialFailureMessage(
                savedCount: 1, firstError: GalleryDlService.nsfwTweetMessage),
            "Saved 1 file, but one or more downloads failed — \(GalleryDlService.nsfwTweetMessage). "
                + "Retry fetches the rest.")
    }
}

/// GalleryDlService.run's exit handling end-to-end against a fake gallery-dl
/// (a /tmp shell script that replays captured output): a partial failure must
/// report the saved count and the FIRST error, a no-file failure keeps
/// today's messages, and the empty-success guard arms the structural
/// auto-retry flag.
@MainActor
final class GalleryDlRunExitTruthTests: XCTestCase {

    private var fixtureDir: URL!

    override func setUpWithError() throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gdl-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    }

    /// The script `cat`s its recorded output from a side file — no shell
    /// quoting of the replayed lines to get wrong.
    private func makeScript(lines: [String], exitCode: Int32) throws -> String {
        let script = fixtureDir.appendingPathComponent("fake-gallery-dl")
        let output = fixtureDir.appendingPathComponent("fake-gallery-dl.out")
        try (lines.map { $0 + "\n" }.joined()).write(to: output, atomically: true, encoding: .utf8)
        try "#!/bin/sh\ncat \"$0.out\"\nexit \(exitCode)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func run(lines: [String], exitCode: Int32) async throws -> DownloadItem {
        let item = DownloadItem(url: "https://x.com/a/status/123")
        let script = try makeScript(lines: lines, exitCode: exitCode)
        await GalleryDlService.run(
            item: item, executablePath: script, outputDirectory: fixtureDir,
            cookieBrowser: .none, register: { _ in }, unregister: {})
        return item
    }

    private let errorLine = "[twitter][error] HttpError: 404 Not Found for media 2"

    func testPartialFailureReportsSavedCountAndFirstError() async throws {
        // One file of a four-image tweet 404s, the rest download: the exit
        // bitmask's generic guess must not clobber the truth.
        let item = try await run(
            lines: [
                "\(fixtureDir.path)/gin - four photos [123] #1.jpg",
                errorLine,
                "\(fixtureDir.path)/gin - four photos [123] #3.jpg",
                "\(fixtureDir.path)/gin - four photos [123] #4.jpg",
            ],
            exitCode: 4)

        XCTAssertEqual(
            item.status,
            .failed(GalleryDlService.partialFailureMessage(savedCount: 3, firstError: errorLine)))
        XCTAssertEqual(item.imageCount, 3)
        XCTAssertFalse(item.emptySuccessFailure, "files landed — this must not arm the auto-retry")
    }

    func testNoFileFailureKeepsTheSpecificError() async throws {
        let item = try await run(lines: [errorLine], exitCode: 4)

        XCTAssertEqual(item.status, .failed(errorLine))
    }

    /// A retry where EVERY file dedupe-skips ("# /path") downloaded nothing:
    /// the mapped fatal error must stay the headline instead of being
    /// demoted into "Saved N files… Retry fetches the rest." — a retry
    /// cannot fetch what NSFW/auth blocks.
    func testAllSkipsWithMappedFatalErrorKeepsTheErrorHeadline() async throws {
        let item = try await run(
            lines: [
                "# \(fixtureDir.path)/gin - four photos [123] #1.jpg",
                "# \(fixtureDir.path)/gin - four photos [123] #2.jpg",
                "[twitter][error] AuthorizationError: NSFW Tweet",
            ],
            exitCode: 4)

        XCTAssertEqual(item.status, .failed(GalleryDlService.nsfwTweetMessage))
    }

    /// With at least one file genuinely landed THIS run, the partial message
    /// (which counts everything on disk, skips included) stays the truthful
    /// outcome.
    func testSkipsPlusNewFileStillComposesThePartialMessage() async throws {
        let item = try await run(
            lines: [
                "# \(fixtureDir.path)/gin - four photos [123] #1.jpg",
                errorLine,
                "\(fixtureDir.path)/gin - four photos [123] #3.jpg",
            ],
            exitCode: 4)

        XCTAssertEqual(
            item.status,
            .failed(GalleryDlService.partialFailureMessage(savedCount: 2, firstError: errorLine)))
    }

    func testNoFileFailureWithoutAnErrorLineKeepsTheBitmaskMessage() async throws {
        let item = try await run(lines: [], exitCode: 4)

        XCTAssertEqual(
            item.status, .failed(GalleryDlService.exitFailureMessage(code: 4, lastWarning: nil)))
    }

    func testEmptySuccessArmsTheStructuralFlag() async throws {
        // exit 0, no files: the guard composes the site-branched message AND
        // sets the flag the auto-retry gate consumes.
        let item = try await run(lines: [], exitCode: 0)

        XCTAssertEqual(item.status, .failed(GalleryDlService.noMediaTwitterMessage))
        XCTAssertTrue(item.emptySuccessFailure)
    }

    func testEmptySuccessWithWarningArmsTheFlagAndCitesTheWarning() async throws {
        let item = try await run(
            lines: ["[twitter][warning] this tweet is age-restricted"], exitCode: 0)

        XCTAssertEqual(
            item.status,
            .failed(GalleryDlService.noMediaWarningPrefix + "this tweet is age-restricted"))
        XCTAssertTrue(item.emptySuccessFailure)
    }
}
