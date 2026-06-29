import XCTest

@testable import XDownloader

/// `QueueStore` persists the download queue to JSON. Tests use an injected temp
/// directory so they never touch the real Application Support file.
@MainActor
final class QueueStoreTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qs-\(UUID().uuidString)")
    }

    func testLoadFromMissingFileReturnsEmpty() {
        XCTAssertTrue(QueueStore(directory: tempDir()).load().isEmpty)
    }

    func testSaveLoadRoundtrip() {
        let store = QueueStore(directory: tempDir())
        let item = DownloadItem(url: "https://x.com/u/status/123")
        item.title = "Uploader - Title"
        store.save([item.toPersisted()])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.url, "https://x.com/u/status/123")
        XCTAssertEqual(loaded.first?.title, "Uploader - Title")
    }

    func testPersistsAcrossInstances() {
        let dir = tempDir()
        QueueStore(directory: dir).save([DownloadItem(url: "https://youtu.be/x").toPersisted()])
        XCTAssertEqual(QueueStore(directory: dir).load().count, 1)
    }
}
