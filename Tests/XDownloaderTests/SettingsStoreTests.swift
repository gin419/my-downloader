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
            cookieBrowser: .safari, cookieBrowserProfile: "", cookiesFilePath: nil,
            cookiesFileBookmarkData: nil,
            twitterHandle: "",
            showDownloadDate: false, youtubeFormat: .videoAndAudio, videoQuality: .best,
            audioQuality: .best, subtitleLanguage: .none, embedSubtitles: true,
            maxConcurrent: 2, instagramProfilePostLimit: InstagramProfilePosts.defaultLimit, openPreference: .video,
            saveHistoryEnabled: true, showMenuBarExtra: true)
    }

    func testSaveLoadRoundtrip() {
        let store = freshStore()
        var saved = sampleFallback()
        saved.cookieBrowser = .chrome
        saved.cookieBrowserProfile = "Profile 2"
        saved.youtubeFormat = .audioOnly
        saved.maxConcurrent = 4
        saved.embedSubtitles = false
        saved.saveHistoryEnabled = false
        saved.showMenuBarExtra = false
        saved.cookiesFilePath = "/c.txt"
        saved.cookiesFileBookmarkData = Data([9])
        saved.twitterHandle = "example_user"
        saved.instagramProfilePostLimit = 250
        store.save(saved)

        let loaded = store.load(fallback: sampleFallback())
        XCTAssertEqual(loaded.cookieBrowser, .chrome)
        XCTAssertEqual(loaded.cookieBrowserProfile, "Profile 2")
        XCTAssertEqual(loaded.youtubeFormat, .audioOnly)
        XCTAssertEqual(loaded.maxConcurrent, 4)
        XCTAssertFalse(loaded.embedSubtitles)  // round-tripped false, not the `true` fallback
        XCTAssertFalse(loaded.saveHistoryEnabled)
        XCTAssertFalse(loaded.showMenuBarExtra)
        XCTAssertEqual(loaded.cookiesFilePath, "/c.txt")
        XCTAssertEqual(loaded.cookiesFileBookmarkData, Data([9]))
        XCTAssertEqual(loaded.twitterHandle, "example_user")
        XCTAssertEqual(loaded.instagramProfilePostLimit, 250)
    }

    func testEmptyDefaultsUseFallback() {
        let loaded = freshStore().load(fallback: sampleFallback())
        XCTAssertEqual(loaded.cookieBrowser, .safari)
        XCTAssertEqual(loaded.maxConcurrent, 2)
        XCTAssertTrue(loaded.embedSubtitles)
        XCTAssertEqual(loaded.instagramProfilePostLimit, 100)
    }

    /// A stored number outside the range — a hand-edited defaults file — is
    /// brought inside it.
    func testInstagramProfilePostLimitIsKeptInRange() throws {
        for (stored, expected) in [(0, 1), (-3, 1), (1, 1), (1000, 1000), (5000, 1000)] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
            defaults.set(stored, forKey: "instagramProfilePostLimit")
            let loaded = SettingsStore(defaults: defaults).load(fallback: sampleFallback())
            XCTAssertEqual(loaded.instagramProfilePostLimit, expected, "\(stored)")
        }
    }
}
