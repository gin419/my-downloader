import XCTest
@testable import XDownloader

/// `YtDlpService.buildArguments` assembles the full yt-dlp command line. It is the
/// most regression-prone pure surface in the app (format-selector matrix + the
/// cookie precedence + the site-gated subtitle flags).
@MainActor
final class YtDlpServiceArgsTests: XCTestCase {

    private let out = URL(fileURLWithPath: "/out")

    private func args(_ item: DownloadItem,
                      format: YouTubeFormat = .videoAndAudio,
                      subtitle: SubtitleLanguage = .none,
                      browser: CookieBrowser = .none,
                      file: String? = nil) -> [String] {
        YtDlpService.buildArguments(
            for: item, outputDirectory: out, format: format,
            videoQuality: .best, audioQuality: .best, subtitleLanguage: subtitle,
            embedSubtitles: false, cookieBrowser: browser, cookiesFile: file)
    }

    func testCookieFilePrependedAndOverridesBrowser() {
        let a = args(DownloadItem(url: "https://www.youtube.com/watch?v=x"), browser: .safari, file: "/c.txt")
        XCTAssertEqual(Array(a.prefix(2)), ["--cookies", "/c.txt"])
        XCTAssertFalse(a.contains("--cookies-from-browser"))
    }

    func testUrlIsLastArgument() {
        let item = DownloadItem(url: "https://www.youtube.com/watch?v=x")
        XCTAssertEqual(args(item).last, item.url)
    }

    func testVideoAndAudioRequestsMerge() {
        XCTAssertTrue(args(DownloadItem(url: "https://www.youtube.com/watch?v=x")).contains("--merge-output-format"))
    }

    func testAudioOnlyExtractsAndDoesNotMerge() {
        let a = args(DownloadItem(url: "https://www.youtube.com/watch?v=x"), format: .audioOnly)
        XCTAssertTrue(a.contains("--extract-audio"))
        XCTAssertTrue(a.contains("--audio-format"))
        XCTAssertFalse(a.contains("--merge-output-format"))
    }

    /// Subtitles are requested only for sites whose profile supports them (YouTube),
    /// never for Twitter even if a language is selected.
    func testSubtitlesGatedBySiteSupport() {
        let yt = args(DownloadItem(url: "https://www.youtube.com/watch?v=x"), subtitle: .english)
        XCTAssertTrue(yt.contains("--write-sub"))
        XCTAssertTrue(yt.contains("--sub-lang"))

        let tw = args(DownloadItem(url: "https://x.com/u/status/1"), subtitle: .english)
        XCTAssertFalse(tw.contains("--write-sub"))
    }
}
