import XCTest

@testable import XDownloader

/// The fxtwitter per-file decision logic, extracted pure: disk-error
/// classification from CocoaError codes, the zero-saved replacement decision,
/// and the partial/zero-saved message composition. The loop used to swallow
/// per-file failures (`try? … else continue`, a bare `catch` around
/// moveItem): a twimg 404, a dropped transfer, or a full destination volume
/// silently shrank the file count under a green "Done" — and zero files saved
/// restored the tweet-blaming "No media found…" message even when the real
/// cause was the local disk.
@MainActor
final class FxTwitterPartialResultTests: XCTestCase {

    // MARK: - Disk-error classification

    func testFullOrUnwritableVolumeErrorsClassifyAsDisk() {
        XCTAssertTrue(FxTwitterService.isDiskWriteError(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(FxTwitterService.isDiskWriteError(CocoaError(.fileWriteNoPermission)))
    }

    func testOtherErrorsDoNotClassifyAsDisk() {
        XCTAssertFalse(FxTwitterService.isDiskWriteError(CocoaError(.fileNoSuchFile)))
        XCTAssertFalse(FxTwitterService.isDiskWriteError(URLError(.timedOut)))
    }

    // MARK: - Zero-saved decision

    func testZeroSavedWithDiskMoveErrorNamesTheDiskNotTheTweet() {
        for code: CocoaError.Code in [.fileWriteOutOfSpace, .fileWriteNoPermission] {
            XCTAssertEqual(
                FxTwitterService.zeroSavedFailureMessage(lastFailure: .move(CocoaError(code))),
                FxTwitterService.diskUnwritableMessage)
        }
        XCTAssertEqual(
            FxTwitterService.diskUnwritableMessage,
            "The download folder's disk is full or not writable — free space or fix permissions, then Retry.")
    }

    func testZeroSavedForNonDiskReasonsKeepsThePriorMessage() {
        // nil → restore the prior (more informative) gallery-dl failure.
        XCTAssertNil(FxTwitterService.zeroSavedFailureMessage(lastFailure: nil))
        XCTAssertNil(FxTwitterService.zeroSavedFailureMessage(lastFailure: .httpStatus(404)))
        XCTAssertNil(
            FxTwitterService.zeroSavedFailureMessage(lastFailure: .transport(URLError(.timedOut))))
        XCTAssertNil(
            FxTwitterService.zeroSavedFailureMessage(lastFailure: .move(CocoaError(.fileNoSuchFile))))
    }

    // MARK: - Partial message composition

    func testPartialMessageNamesCountsAndHTTPStatus() {
        XCTAssertEqual(
            FxTwitterService.partialFailureMessage(saved: 3, attempted: 4, lastFailure: .httpStatus(404)),
            "Downloaded 3 of 4 files — the server returned HTTP 404. Retry fetches the rest.")
    }

    func testPartialMessageNamesTransportCauses() {
        let cases: [(URLError.Code, String)] = [
            (.timedOut, "the connection timed out"),
            (.notConnectedToInternet, "the network is offline"),
            (.networkConnectionLost, "the connection was lost mid-transfer"),
        ]
        for (code, reason) in cases {
            XCTAssertEqual(
                FxTwitterService.partialFailureMessage(
                    saved: 1, attempted: 2, lastFailure: .transport(URLError(code))),
                "Downloaded 1 of 2 files — \(reason). Retry fetches the rest.")
        }
    }

    func testPartialMessageFallsBackToGenericNetworkWording() {
        XCTAssertEqual(
            FxTwitterService.shortReason(for: .transport(URLError(.cannotConnectToHost))),
            "a network error interrupted the transfer")
        XCTAssertEqual(
            FxTwitterService.shortReason(for: .transport(CocoaError(.fileReadUnknown))),
            "a network error interrupted the transfer")
    }

    func testPartialMessageNamesDiskAndNonDiskMoveFailures() {
        XCTAssertEqual(
            FxTwitterService.partialFailureMessage(
                saved: 2, attempted: 4, lastFailure: .move(CocoaError(.fileWriteOutOfSpace))),
            "Downloaded 2 of 4 files — the download folder's disk is full or not writable. "
                + "Retry fetches the rest.")
        XCTAssertEqual(
            FxTwitterService.shortReason(for: .move(CocoaError(.fileNoSuchFile))),
            "the file couldn't be saved to the download folder")
    }
}
