import XCTest

@testable import XDownloader

final class BrowserCookieProfileTests: XCTestCase {
    func testDiscoversExistingChromeProfilesAndShowsTheirNames() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let chrome = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome", isDirectory: true)
        try FileManager.default.createDirectory(
            at: chrome.appendingPathComponent("Default", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: chrome.appendingPathComponent("Profile 2", isDirectory: true),
            withIntermediateDirectories: true)

        let state: [String: Any] = [
            "profile": [
                "info_cache": [
                    "Default": ["name": "Personal"],
                    "Profile 2": ["name": "Work"],
                    "Profile 9": ["name": "Removed"],
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: state)
        try data.write(to: chrome.appendingPathComponent("Local State"))

        XCTAssertEqual(
            BrowserCookieProfileDiscovery.profiles(for: .chrome, homeDirectory: home),
            [
                BrowserCookieProfile(id: "Default", displayName: "Personal"),
                BrowserCookieProfile(id: "Profile 2", displayName: "Work"),
            ])
    }

    func testUnsupportedBrowserHasNoProfilePicker() {
        XCTAssertEqual(BrowserCookieProfileDiscovery.profiles(for: .safari), [])
        XCTAssertEqual(BrowserCookieProfileDiscovery.profiles(for: .firefox), [])
    }
}
