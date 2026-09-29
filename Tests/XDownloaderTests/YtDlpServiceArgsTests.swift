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

    // MARK: - Resolved address

    private let page = "https://video.dmm.co.jp/cinema/content/?id=test00123"
    private let address = "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAAAAAAAAAAAAAAAAAA/test00123hhb.mp4"

    private func resolvedItem(stem: String = "Synthetic Maker - Synthetic Sample Title [test00123]") -> DownloadItem {
        let item = DownloadItem(url: page)
        item.resolvedAddress = address
        item.resolvedFileStem = stem
        return item
    }

    func testResolvedAddressIsWhatTheToolDownloads() {
        let a = args(resolvedItem())
        XCTAssertEqual(a.last, address)
        XCTAssertFalse(a.contains(page), "the page link holds no media for the tool to read")
    }

    func testResolvedStemNamesTheFile() {
        let a = args(resolvedItem())
        XCTAssertEqual(a[a.firstIndex(of: "--output")! + 1], "/out/Synthetic Maker - Synthetic Sample Title [test00123].%(ext)s")
    }

    /// "%" opens a field in the output template; a title holding one must
    /// reach the file name as a plain percent sign.
    func testPercentSignInAResolvedStemIsEscaped() {
        let a = args(resolvedItem(stem: "Synthetic Maker - 100% Synthetic %(title)s [test00123]"))
        XCTAssertEqual(
            a[a.firstIndex(of: "--output")! + 1],
            "/out/Synthetic Maker - 100%% Synthetic %%(title)s [test00123].%(ext)s")
        XCTAssertEqual(YtDlpService.literalTemplateText("50% and 100%"), "50%% and 100%%")
        XCTAssertEqual(YtDlpService.literalTemplateText("no sign"), "no sign")
    }

    /// "$" opens an environment variable in the output template, and the
    /// tool expands it — slashes included — even when it is doubled. No
    /// spelling of it may reach the template.
    func testDollarSignInAResolvedStemNeverReachesTheTemplate() {
        let a = args(resolvedItem(stem: "Synthetic Maker - Sale $HOME ${USER} $$PATH 5$ [test00123]"))
        let template = a[a.firstIndex(of: "--output")! + 1]
        XCTAssertEqual(template, "/out/Synthetic Maker - Sale ＄HOME ＄{USER} ＄＄PATH 5＄ [test00123].%(ext)s")
        XCTAssertFalse(template.contains("$"), template)
        XCTAssertEqual(YtDlpService.literalTemplateText("$HOME 50%"), "＄HOME 50%%")
    }

    // MARK: - A row's own folder

    /// A work of two or more files hands the tool its own folder. The
    /// folder is named after the stem and is template text too: a "%" in it
    /// must stay a plain percent sign.
    func testPercentSignInTheFolderIsEscaped() {
        let folder = out.appendingPathComponent("50% off [x]", isDirectory: true)
        let a = YtDlpService.buildArguments(
            for: resolvedItem(stem: "50% off [x]"), outputDirectory: folder, format: .videoAndAudio,
            videoQuality: .best, audioQuality: .best, subtitleLanguage: .none,
            embedSubtitles: false, cookieBrowser: .none)
        XCTAssertEqual(a[a.firstIndex(of: "--output")! + 1], "/out/50%% off [x]/50%% off [x].%(ext)s")
        XCTAssertEqual(RowFolder.templateDirectory(folder), "/out/50%% off [x]")
        XCTAssertEqual(RowFolder.templateDirectory(out), "/out")
    }

    /// The folder the app names from a stem holding "$" is named the way
    /// the clip's own file is, so no "$" reaches the tool at all.
    func testDollarSignInTheStemNamesTheFolderWithoutIt() {
        let stem = "Synthetic Maker - Sale $HOME [test00123]"
        let folder = out.appendingPathComponent(RowFolder.appNamed(stem), isDirectory: true)
        let a = YtDlpService.buildArguments(
            for: resolvedItem(stem: stem), outputDirectory: folder, format: .videoAndAudio,
            videoQuality: .best, audioQuality: .best, subtitleLanguage: .none,
            embedSubtitles: false, cookieBrowser: .none)
        let template = a[a.firstIndex(of: "--output")! + 1]
        XCTAssertEqual(
            template, "/out/Synthetic Maker - Sale ＄HOME [test00123]/Synthetic Maker - Sale ＄HOME [test00123].%(ext)s")
        XCTAssertFalse(template.contains("$"), template)
    }

    /// The resolved address names one file; a list in its place is not
    /// walked. Links that resolve nothing get no such argument (see
    /// testArgumentsWithoutAResolvedAddressAreUnchanged).
    func testResolvedAddressIsDownloadedAsOneFile() {
        let a = args(resolvedItem())
        XCTAssertEqual(Array(a.suffix(2)), ["--no-playlist", address])
        XCTAssertFalse(args(DownloadItem(url: page)).contains("--no-playlist"))
    }

    func testNoCookieArgumentsForASiteThatIsNeverSentCookies() {
        for a in [
            args(resolvedItem(), browser: .chrome),
            args(resolvedItem(), browser: .safari, file: "/c.txt"),
            // Before anything is resolved, too.
            args(DownloadItem(url: page), browser: .chrome, file: "/c.txt"),
        ] {
            XCTAssertFalse(a.contains("--cookies"), "\(a)")
            XCTAssertFalse(a.contains("--cookies-from-browser"), "\(a)")
            XCTAssertFalse(a.contains("/c.txt"), "\(a)")
            XCTAssertEqual(a.first, "--format")
        }
    }

    /// A stem travels with its address. Without one the name is the
    /// extractor's, as for every other link.
    func testStemWithoutAnAddressIsNotUsed() {
        let item = DownloadItem(url: "https://example.com/p")
        item.resolvedFileStem = "Synthetic Maker - Synthetic Sample Title [test00123]"
        let a = args(item)
        XCTAssertEqual(a[a.firstIndex(of: "--output")! + 1], "/out/%(uploader)s - %(title)s.%(ext)s")
        XCTAssertEqual(a.last, "https://example.com/p")
    }

    /// Regression guard for every link that resolves nothing — direct
    /// preview file links among them: the command line is, argument for
    /// argument, the one it was before there was anything to resolve.
    func testArgumentsWithoutAResolvedAddressAreUnchanged() {
        let generic =
            "bestvideo[vcodec^=avc][ext=mp4]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]"
            + "/bestvideo+bestaudio/bestvideo+bestaudio/bv*+ba/b"
        let single =
            "bestvideo*[acodec!=none][ext=mp4][protocol^=https]/bestvideo*[acodec!=none][ext=mp4]/best[acodec!=none]/bv*+ba/b"
        let tail = ["--socket-timeout", "10", "--progress", "--newline"]
        let direct = "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAAAAAAAAAAAAAAAAAA/test00123hhb.mp4"
        let stream = "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenBBBBBBBBBBBBBBBBBBBB/playlist.m3u8"

        XCTAssertEqual(
            args(DownloadItem(url: direct), browser: .chrome),
            ["--cookies-from-browser", "chrome", "--format", generic, "--merge-output-format", "mp4"]
                + ["--output", "/out/%(uploader)s - %(title)s.%(ext)s"] + tail + [direct])
        XCTAssertEqual(
            args(DownloadItem(url: stream), format: .singleFile, browser: .safari, file: "/c.txt"),
            ["--cookies", "/c.txt", "--format", single, "--merge-output-format", "mp4"]
                + ["--output", "/out/%(uploader)s - %(title)s.%(ext)s"] + tail + [stream])
        XCTAssertEqual(
            args(DownloadItem(url: "https://x.com/u/status/1"), browser: .firefox),
            ["--cookies-from-browser", "firefox", "--format", generic, "--merge-output-format", "mp4"]
                + ["--output", "/out/%(title)s%(playlist_index& [{0:02d}]|)s.%(ext)s"] + tail + ["https://x.com/u/status/1"])
        XCTAssertEqual(
            args(DownloadItem(url: "https://www.youtube.com/watch?v=x"), format: .audioOnly, subtitle: .english),
            ["--format", "bestaudio/best", "--extract-audio", "--audio-format", "mp3", "--audio-quality", AudioQuality.best.rawValue]
                + ["--output", "/out/%(uploader)s - %(title)s.%(ext)s"] + tail + ["https://www.youtube.com/watch?v=x"])
    }
}
