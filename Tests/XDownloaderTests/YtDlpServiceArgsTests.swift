import XCTest

@testable import XDownloader

/// `YtDlpService.buildArguments` assembles the full yt-dlp command line. It is the
/// most regression-prone pure surface in the app (format-selector matrix + the
/// cookie precedence + the site-gated subtitle flags).
@MainActor
final class YtDlpServiceArgsTests: XCTestCase {

    private let out = URL(fileURLWithPath: "/out")

    private func args(
        _ item: DownloadItem,
        format: YouTubeFormat = .videoAndAudio,
        subtitle: SubtitleLanguage = .none,
        browser: CookieBrowser = .none,
        file: String? = nil
    ) -> [String] {
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

    /// Instagram is not a YouTube-selector site: `.singleFile` (the only format
    /// whose selector is site-gated) must use the generic combined-stream
    /// selector, and a selected subtitle language must be ignored. The output
    /// template must carry the playlist-index suffix — it is what distinguishes
    /// the instagram profile from the `other` catch-all at the args level, and
    /// without it every video of a carousel resolves to the same filename.
    func testInstagramUsesGenericSelectorAndNoSubtitles() {
        let ig = args(
            DownloadItem(url: "https://www.instagram.com/reel/Cxyz12345Ab/"),
            format: .singleFile, subtitle: .english)
        let selector = ig[ig.firstIndex(of: "--format")! + 1]
        XCTAssertTrue(selector.hasPrefix("bestvideo*[acodec!=none]"))
        XCTAssertFalse(ig.contains("--write-sub"))
        XCTAssertFalse(ig.contains("--sub-lang"))

        let output = ig[ig.firstIndex(of: "--output")! + 1]
        XCTAssertTrue(output.contains("%(playlist_index&"), "carousel de-collision suffix missing: \(output)")
    }

    /// yt-dlp's twitter extractor already builds %(title)s as "<user> - <text>",
    /// so the template must drop its own %(uploader)s prefix there — otherwise
    /// every filename and row title doubles the author ("NASA - NASA - …").
    /// Sites whose extractor keeps title and uploader separate keep the prefix.
    func testOutputTemplateStemPerSite() {
        let tw = args(DownloadItem(url: "https://x.com/u/status/1"))
        let twOutput = tw[tw.firstIndex(of: "--output")! + 1]
        XCTAssertTrue(twOutput.hasPrefix("/out/%(title)s"), twOutput)
        XCTAssertFalse(twOutput.contains("%(uploader)s"), twOutput)

        let yt = args(DownloadItem(url: "https://www.youtube.com/watch?v=x"))
        let ytOutput = yt[yt.firstIndex(of: "--output")! + 1]
        XCTAssertTrue(ytOutput.hasPrefix("/out/%(uploader)s - %(title)s"), ytOutput)
    }
}
