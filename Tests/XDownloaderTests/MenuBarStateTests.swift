import XCTest

@testable import XDownloader

@MainActor
final class MenuBarStateTests: XCTestCase {

    private func item(_ status: DownloadStatus, progress: Double = 0, speed: String? = nil) -> DownloadItem {
        let item = DownloadItem(url: "https://x.com/a/status/\(UUID().uuidString)")
        item.status = status
        item.progress = progress
        item.speed = speed
        return item
    }

    // MARK: - Speed parsing

    func testParseSpeedUnits() {
        XCTAssertEqual(MenuBarState.parseSpeed("3.21MiB/s")!, 3.21 * 1_048_576, accuracy: 1)
        XCTAssertEqual(MenuBarState.parseSpeed("512.00KiB/s")!, 512 * 1_024, accuracy: 1)
        XCTAssertEqual(MenuBarState.parseSpeed("1.2MB/s")!, 1_200_000, accuracy: 1)
        XCTAssertEqual(MenuBarState.parseSpeed("~2.5MiB/s")!, 2.5 * 1_048_576, accuracy: 1)
        XCTAssertNil(MenuBarState.parseSpeed("Unknown"))
        XCTAssertNil(MenuBarState.parseSpeed(""))
    }

    func testFormatSpeed() {
        XCTAssertEqual(MenuBarState.formatSpeed(bytesPerSecond: 4_200_000), "4.2 MB/s")
        XCTAssertEqual(MenuBarState.formatSpeed(bytesPerSecond: 740_000), "740 KB/s")
        // Unit rollover happens at the rounded value — never "1000 KB/s".
        XCTAssertEqual(MenuBarState.formatSpeed(bytesPerSecond: 999_700), "1.0 MB/s")
    }

    // MARK: - Counts and label

    func testCountsAndLabelExcludePaused() {
        let items = [
            item(.downloading, progress: 0.5, speed: "1.00MiB/s"),
            item(.fetching),
            item(.queued), item(.queued),
            item(.paused),
            item(.failed("boom")),
            item(.completed),
        ]
        let state = MenuBarState.compute(items: items, showsAttention: false, wasOverflowing: false)
        XCTAssertEqual(state.downloadingCount, 2)  // downloading + fetching
        XCTAssertEqual(state.queuedCount, 2)
        XCTAssertEqual(state.unfinishedCount, 4)
        XCTAssertEqual(state.countLabel, "4")
        XCTAssertEqual(state.pausedCount, 1)
        XCTAssertEqual(state.failedCount, 1)
        XCTAssertEqual(state.firstFailureMessage, "boom")
    }

    func testCountLabelIdleAndCap() {
        let idle = MenuBarState.compute(items: [item(.completed)], showsAttention: false, wasOverflowing: false)
        XCTAssertNil(idle.countLabel)

        let many = MenuBarState.compute(
            items: (0..<12).map { _ in item(.queued) }, showsAttention: false, wasOverflowing: false)
        XCTAssertEqual(many.countLabel, "9+")
    }

    // MARK: - Overflow hysteresis

    func testOverflowHysteresis() {
        func state(_ count: Int, wasOverflowing: Bool) -> MenuBarState {
            MenuBarState.compute(
                items: (0..<count).map { _ in item(.queued) },
                showsAttention: false, wasOverflowing: wasOverflowing)
        }
        // ≥6 collapses to 4 rows + "N more…"
        let six = state(6, wasOverflowing: false)
        XCTAssertTrue(six.isOverflowing)
        XCTAssertEqual(six.rows.count, 4)
        XCTAssertEqual(six.overflowCount, 2)
        // exactly 5 holds the previous mode — no flapping at the boundary
        XCTAssertTrue(state(5, wasOverflowing: true).isOverflowing)
        XCTAssertFalse(state(5, wasOverflowing: false).isOverflowing)
        XCTAssertEqual(state(5, wasOverflowing: false).rows.count, 5)
        // ≤4 always expands
        let four = state(4, wasOverflowing: true)
        XCTAssertFalse(four.isOverflowing)
        XCTAssertEqual(four.rows.count, 4)
        XCTAssertEqual(four.overflowCount, 0)
    }

    // MARK: - Row details

    func testFetchingNeverShowsPercentAndZeroProgressHasNoPercent() {
        let items = [
            item(.fetching),
            item(.downloading, progress: 0),  // gallery-dl/fxtwitter: no progress data
            item(.downloading, progress: 0.64),
        ]
        let state = MenuBarState.compute(items: items, showsAttention: false, wasOverflowing: false)
        XCTAssertEqual(state.rows[0].detail, .fetching)
        XCTAssertEqual(state.rows[1].detail, .downloading(percent: nil))
        XCTAssertEqual(state.rows[2].detail, .downloading(percent: 64))
    }

    func testAggregateSpeedSkipsUnparseable() {
        let items = [
            item(.downloading, progress: 0.2, speed: "1.00MiB/s"),
            item(.downloading, progress: 0.4, speed: "Unknown"),
            item(.downloading, progress: 0.6, speed: "1.00MiB/s"),
        ]
        let state = MenuBarState.compute(items: items, showsAttention: false, wasOverflowing: false)
        XCTAssertEqual(state.aggregateSpeed, "2.1 MB/s")

        let silent = MenuBarState.compute(
            items: [item(.downloading, progress: 0.2, speed: "Unknown")],
            showsAttention: false, wasOverflowing: false)
        XCTAssertNil(silent.aggregateSpeed)
    }

    func testAttentionPassthrough() {
        let state = MenuBarState.compute(items: [], showsAttention: true, wasOverflowing: false)
        XCTAssertTrue(state.showsAttention)
    }

    func testLikesSyncCountsAsOneActiveTaskAndFailureSummary() {
        let running = MenuBarState.compute(
            items: [], likesStatus: .running, likesHandle: "@gin",
            showsAttention: false, wasOverflowing: false)
        XCTAssertEqual(running.downloadingCount, 1)
        XCTAssertEqual(running.unfinishedCount, 1)
        XCTAssertEqual(running.rows.first?.title, "X Likes Sync · @gin")
        XCTAssertEqual(running.rows.first?.detail, .fetching)

        let partial = MenuBarState.compute(
            items: [], likesStatus: .partial, likesHandle: "@gin",
            showsAttention: true, wasOverflowing: false)
        XCTAssertEqual(partial.failedCount, 1)
        XCTAssertEqual(partial.firstFailureMessage, "X Likes sync needs attention")
        XCTAssertTrue(partial.showsAttention)
    }
}
