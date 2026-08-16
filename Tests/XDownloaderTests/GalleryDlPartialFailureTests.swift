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
