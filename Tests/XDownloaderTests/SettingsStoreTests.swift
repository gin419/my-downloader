import XCTest

@testable import XDownloader

@MainActor
final class SettingsStoreTests: XCTestCase {

    private func freshStore() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    }

    private func sampleFallback() -> AppSettings {
        AppSettings(
            outputDirectory: URL(fileURLWithPath: "/fallback"),
            cookieBrowser: .safari, cookiesFilePath: nil, cookiesFileBookmarkData: nil,
            showDownloadDate: false, youtubeFormat: .videoAndAudio, videoQuality: .best,
            audioQuality: .best, subtitleLanguage: .none, embedSubtitles: true,
            maxConcurrent: 2, openPreference: .video,
            saveHistoryEnabled: true)
    }

    func testSaveLoadRoundtrip() {
        let store = freshStore()
        var saved = sampleFallback()
        saved.cookieBrowser = .chrome
        saved.youtubeFormat = .audioOnly
        saved.maxConcurrent = 4
        saved.embedSubtitles = false
        saved.saveHistoryEnabled = false
        saved.cookiesFilePath = "/c.txt"
        saved.cookiesFileBookmarkData = Data([9])
        store.save(saved)

        let loaded = store.load(fallback: sampleFallback())
        XCTAssertEqual(loaded.cookieBrowser, .chrome)
        XCTAssertEqual(loaded.youtubeFormat, .audioOnly)
        XCTAssertEqual(loaded.maxConcurrent, 4)
        XCTAssertFalse(loaded.embedSubtitles)  // round-tripped false, not the `true` fallback
        XCTAssertFalse(loaded.saveHistoryEnabled)
        XCTAssertEqual(loaded.cookiesFilePath, "/c.txt")
        XCTAssertEqual(loaded.cookiesFileBookmarkData, Data([9]))
    }

    func testEmptyDefaultsUseFallback() {
        let loaded = freshStore().load(fallback: sampleFallback())
        XCTAssertEqual(loaded.cookieBrowser, .safari)
        XCTAssertEqual(loaded.maxConcurrent, 2)
        XCTAssertTrue(loaded.embedSubtitles)
    }
}
