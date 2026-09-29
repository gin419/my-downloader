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
        XCTAssertTrue(twOutput.hasPrefix("/out/%(xdl_folder|)s/%(title)s"), twOutput)
        XCTAssertFalse(twOutput.contains("%(uploader)s"), twOutput)

        let yt = args(DownloadItem(url: "https://www.youtube.com/watch?v=x"))
        let ytOutput = yt[yt.firstIndex(of: "--output")! + 1]
        XCTAssertTrue(ytOutput.hasPrefix("/out/%(xdl_folder|)s/%(uploader)s - %(title)s"), ytOutput)
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
        XCTAssertEqual(a[a.firstIndex(of: "--output")! + 1], "/out/%(xdl_folder|)s/%(uploader)s - %(title)s.%(ext)s")
        XCTAssertEqual(a.last, "https://example.com/p")
    }

    /// Regression guard for every link that resolves nothing — direct
    /// preview file links among them: the command line is, argument for
    /// argument, the one it was before there was anything to resolve, but
    /// for the list-folder steps and the folder field in the template.
    func testArgumentsWithoutAResolvedAddressAreUnchanged() {
        let generic =
            "bestvideo[vcodec^=avc][ext=mp4]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]"
            + "/bestvideo+bestaudio/bestvideo+bestaudio/bv*+ba/b"
        let single =
            "bestvideo*[acodec!=none][ext=mp4][protocol^=https]/bestvideo*[acodec!=none][ext=mp4]/best[acodec!=none]/bv*+ba/b"
        let tail = ["--socket-timeout", "10", "--progress", "--newline"]
        let listFolder = listFolderArguments
        let direct = "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAAAAAAAAAAAAAAAAAA/test00123hhb.mp4"
        let stream = "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenBBBBBBBBBBBBBBBBBBBB/playlist.m3u8"

        XCTAssertEqual(
            args(DownloadItem(url: direct), browser: .chrome),
            ["--cookies-from-browser", "chrome", "--format", generic, "--merge-output-format", "mp4"]
                + listFolder + ["--output", "/out/%(xdl_folder|)s/%(uploader)s - %(title)s.%(ext)s"] + tail + [direct])
        XCTAssertEqual(
            args(DownloadItem(url: stream), format: .singleFile, browser: .safari, file: "/c.txt"),
            ["--cookies", "/c.txt", "--format", single, "--merge-output-format", "mp4"]
                + listFolder + ["--output", "/out/%(xdl_folder|)s/%(uploader)s - %(title)s.%(ext)s"] + tail + [stream])
        XCTAssertEqual(
            args(DownloadItem(url: "https://x.com/u/status/1"), browser: .firefox),
            ["--cookies-from-browser", "firefox", "--format", generic, "--merge-output-format", "mp4"]
                + listFolder + ["--output", "/out/%(xdl_folder|)s/%(title)s%(playlist_index& [{0:02d}]|)s.%(ext)s"] + tail + [
                    "https://x.com/u/status/1"
                ])
        XCTAssertEqual(
            args(DownloadItem(url: "https://www.youtube.com/watch?v=x"), format: .audioOnly, subtitle: .english),
            ["--format", "bestaudio/best", "--extract-audio", "--audio-format", "mp3", "--audio-quality", AudioQuality.best.rawValue]
                + listFolder + ["--output", "/out/%(xdl_folder|)s/%(uploader)s - %(title)s.%(ext)s"] + tail + ["https://www.youtube.com/watch?v=x"])
    }

    // MARK: - A list's own folder

    /// The steps as the tool reads them, spelled out: a change to any of
    /// them changes where every list of videos is saved.
    private let listFolderArguments = [
        "--parse-metadata",
        "pre_process:%(playlist_count,n_entries|)s#%(playlist_title,playlist_id).160B [%(playlist_id).64B]"
            + ":(?s)^(?:[2-9]|[1-9][0-9]+)#(?P<xdl_folder>.+)",
        "--replace-in-metadata", "pre_process:xdl_folder", #"\x24"#, "＄",
    ]

    /// A link with no folder settled before the run may turn out to be a
    /// list: the steps that name the list's folder come right before the
    /// template, whose directory reads the folder field.
    func testALinkWithoutAFolderLetsAListTakeOne() {
        for link in [
            "https://x.com/u/status/1", "https://www.instagram.com/p/SYNcode0001/",
            "https://www.youtube.com/playlist?list=SYNlist", "https://example.com/p",
        ] {
            let a = args(DownloadItem(url: link))
            let output = a.firstIndex(of: "--output")!
            XCTAssertEqual(Array(a[(output - listFolderArguments.count)..<output]), listFolderArguments, link)
            XCTAssertEqual(YtDlpService.playlistFolderArguments, listFolderArguments)
            XCTAssertTrue(a[output + 1].hasPrefix("/out/%(xdl_folder|)s/"), a[output + 1])
            XCTAssertEqual(a.filter { $0 == "--parse-metadata" }.count, 1, link)
            XCTAssertFalse(a.contains { $0.contains("$") }, "the tool would expand it: \(a)")
        }
        let audio = args(DownloadItem(url: "https://www.youtube.com/watch?v=x"), format: .audioOnly)
        XCTAssertTrue(audio.contains("--parse-metadata"))
    }

    /// A folder settled before the run — a post's found on disk, a work
    /// page's — takes the files flat, as before lists had folders: no step
    /// names another folder, and a "%" in the folder's name stays a plain
    /// percent sign.
    func testAFolderSettledBeforeTheRunTakesTheFilesFlat() {
        let folder = out.appendingPathComponent("someone - 50% off [1]", isDirectory: true)
        let a = YtDlpService.buildArguments(
            for: DownloadItem(url: "https://x.com/u/status/1"), outputDirectory: out, folder: folder,
            format: .videoAndAudio, videoQuality: .best, audioQuality: .best, subtitleLanguage: .none,
            embedSubtitles: false, cookieBrowser: .none)
        XCTAssertFalse(a.contains("--parse-metadata"))
        XCTAssertFalse(a.contains("--replace-in-metadata"))
        XCTAssertFalse(a.contains { $0.contains("xdl_folder") })
        XCTAssertEqual(
            a[a.firstIndex(of: "--output")! + 1], "/out/someone - 50%% off [1]/%(title)s%(playlist_index& [{0:02d}]|)s.%(ext)s")
    }

    // MARK: - A post's found folder

    /// The step for a post whose folder is on disk, spelled out as the tool
    /// reads it: ".." for one video or a list of one, nothing for two or
    /// more, and no "$" of any kind.
    private let foundFolderArguments = [
        "--parse-metadata", #"pre_process:%(playlist_count,n_entries|)s#..:^[01]?#(?P<xdl_up>\.\.)"#,
    ]

    /// A post whose folder is on disk and holds no video of yt-dlp's: the
    /// found folder's name is literal text in the template — a "%" doubled,
    /// the ":" and "?" the tool would swap in a field's value kept — and
    /// the step that sends a single video back out of it replaces the one
    /// that would name a second folder.
    func testAFoundFolderWithoutAVideoTakesAListUnderItsOwnName() {
        let found = out.appendingPathComponent(#"someone - 50% off: why? "no" [1]"#, isDirectory: true)
        let a = YtDlpService.buildArguments(
            for: DownloadItem(url: "https://x.com/u/status/1"), outputDirectory: out, foundFolder: found,
            format: .videoAndAudio, videoQuality: .best, audioQuality: .best, subtitleLanguage: .none,
            embedSubtitles: false, cookieBrowser: .none)
        let output = a.firstIndex(of: "--output")!
        XCTAssertEqual(Array(a[(output - foundFolderArguments.count)..<output]), foundFolderArguments)
        XCTAssertEqual(YtDlpService.foundFolderArguments, foundFolderArguments)
        XCTAssertEqual(
            a[output + 1], #"/out/someone - 50%% off: why? "no" [1]/%(xdl_up|)s/%(title)s%(playlist_index& [{0:02d}]|)s.%(ext)s"#)
        XCTAssertEqual(a.filter { $0 == "--parse-metadata" }.count, 1)
        XCTAssertFalse(a.contains("--replace-in-metadata"))
        XCTAssertFalse(a.contains { $0.contains("xdl_folder") })
        XCTAssertFalse(a.contains { $0.contains("$") }, "the tool would expand it: \(a)")
    }

    /// A folder the files go into flat, or a resolved address, wins over a
    /// found folder: neither is ever walked as a list.
    func testAFoundFolderIsIgnoredWhenTheFilesGoFlat() {
        let found = out.appendingPathComponent("someone - found [1]", isDirectory: true)
        let flat = out.appendingPathComponent("someone - flat [1]", isDirectory: true)
        for (item, folder) in [(DownloadItem(url: "https://x.com/u/status/1"), flat), (resolvedItem(), nil)] {
            let a = YtDlpService.buildArguments(
                for: item, outputDirectory: out, folder: folder, foundFolder: found,
                format: .videoAndAudio, videoQuality: .best, audioQuality: .best, subtitleLanguage: .none,
                embedSubtitles: false, cookieBrowser: .none)
            XCTAssertFalse(a.contains("--parse-metadata"), "\(a)")
            XCTAssertFalse(a.contains { $0.contains("xdl_up") || $0.contains(found.lastPathComponent) }, "\(a)")
        }
    }

    /// A resolved address names one file and is never walked as a list, so
    /// it gets no folder step either, with or without a folder of its own.
    func testAResolvedAddressGetsNoListFolder() {
        for a in [args(resolvedItem()), args(resolvedItem(stem: "50% off [x]"))] {
            XCTAssertFalse(a.contains("--parse-metadata"), "\(a)")
            XCTAssertFalse(a.contains { $0.contains("xdl_folder") }, "\(a)")
        }
    }
}
