import XCTest

@testable import XDownloader

/// The fetching row's wait note: during `.fetching` with a Phase 2 backoff
/// eta stored, the status line says WHY the row is waiting instead of
/// looking hung — and only then.
final class FetchingWaitNoteTests: XCTestCase {

    func testFetchingRowExplainsTheWait() {
        XCTAssertEqual(
            FetchingWaitNote.statusLine(status: .fetching, eta: "14 minutes (rate limited)"),
            "Fetching… · rate limited — resuming in 14 minutes")
    }

    func testSecondsBackoffReadsTheSame() {
        XCTAssertEqual(
            FetchingWaitNote.statusLine(status: .fetching, eta: "60 seconds (rate limited)"),
            "Fetching… · rate limited — resuming in 60 seconds")
    }

    func testEtaWithoutTheMarkerStillReads() {
        XCTAssertEqual(
            FetchingWaitNote.statusLine(status: .fetching, eta: "2 minutes"),
            "Fetching… · rate limited — resuming in 2 minutes")
    }

    func testNoEtaNoNote() {
        XCTAssertNil(FetchingWaitNote.statusLine(status: .fetching, eta: nil))
    }

    func testOnlyFetchingRowsGetTheNote() {
        // A downloading row's eta is a real ETA — the progress section already
        // renders it; the wait note must not double up.
        XCTAssertNil(FetchingWaitNote.statusLine(status: .downloading, eta: "14 minutes (rate limited)"))
        XCTAssertNil(FetchingWaitNote.statusLine(status: .queued, eta: "14 minutes (rate limited)"))
    }
}
