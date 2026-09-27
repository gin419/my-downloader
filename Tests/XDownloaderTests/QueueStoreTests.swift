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

    /// A resolved address is looked up again on every run; neither it nor
    /// the file name that goes with it may reach the queue file.
    func testResolvedAddressAndStemAreNotPersisted() throws {
        let dir = tempDir()
        let item = DownloadItem(url: "https://video.dmm.co.jp/cinema/content/?id=test00123")
        item.title = "Synthetic Maker - Synthetic Sample Title"
        item.resolvedAddress = "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4"
        item.resolvedFileStem = "Synthetic Maker - Synthetic Sample Title [test00123]"

        let persisted = item.toPersisted()
        let encoded = String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SYNTHETICtoken"), encoded)
        XCTAssertFalse(encoded.contains("cc3001"), encoded)
        XCTAssertFalse(encoded.contains("[test00123]"), encoded)

        let store = QueueStore(directory: dir)
        store.save([persisted])
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            XCTAssertFalse(text.contains("SYNTHETICtoken"), file.lastPathComponent)
            XCTAssertFalse(text.contains("[test00123]"), file.lastPathComponent)
        }

        let restored = DownloadItem(persisted: try XCTUnwrap(store.load().first))
        XCTAssertEqual(restored.url, "https://video.dmm.co.jp/cinema/content/?id=test00123")
        XCTAssertNil(restored.resolvedAddress)
        XCTAssertNil(restored.resolvedFileStem)
    }
}
