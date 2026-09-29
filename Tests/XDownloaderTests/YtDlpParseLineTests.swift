import XCTest

@testable import XDownloader

/// `YtDlpService.parseLine` media-path capture. The "has already been
/// downloaded" skip notice is the only output yt-dlp prints when the file
/// already exists on disk (exit 0, no Destination:/[Merger] lines), so it
/// must record the path or DownloadManager reads the run as an empty success.
@MainActor
final class YtDlpParseLineTests: XCTestCase {

    private func parse(_ line: String, into item: DownloadItem) {
        YtDlpService.parseLine(line, item: item) {
            XCTFail("terminate() must not fire for media-path lines")
        }
    }

    // MARK: - "has already been downloaded" skip notice

    func testAlreadyDownloadedVideoIsRecordedAsOutput() {
        let item = DownloadItem(url: "https://youtube.com/shorts/abc")
        parse("[download] /tmp/out/nihil - some title.mp4 has already been downloaded", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.title, "nihil - some title")
        XCTAssertEqual(item.mediaCategory, .video)
    }

    func testAlreadyDownloadedAndMergedSuffixIsIgnored() {
        // Older yt-dlp versions append " and merged" to the same notice.
        let item = DownloadItem(url: "https://youtube.com/shorts/abc")
        parse("[download] /tmp/out/nihil - some title.mp4 has already been downloaded and merged", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.title, "nihil - some title")
    }

    func testAlreadyDownloadedImageCountsAsImage() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse("[download] /tmp/out/user - pic.jpg has already been downloaded", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/user - pic.jpg")
        XCTAssertEqual(item.imageCount, 1)
        XCTAssertNil(item.videoCount)
        XCTAssertEqual(item.mediaCategory, .image)
    }

    func testAlreadyDownloadedPreMergeStreamStripsFormatCodeFromTitle() {
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] /tmp/out/nihil - clip.f299.mp4 has already been downloaded", into: item)

        XCTAssertEqual(item.videoPath, "/tmp/out/nihil - clip.f299.mp4")
        XCTAssertEqual(item.title, "nihil - clip")
    }

    func testAlreadyDownloadedFilenameWithPercentIsNotSwallowedByProgressBranch() {
        // The output template preserves literal '%' from titles; the skip branch
        // must win over the progress branch or the path is never recorded.
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] /tmp/out/nihil - 100% legit.mp4 has already been downloaded", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/nihil - 100% legit.mp4")
        XCTAssertEqual(item.videoPath, "/tmp/out/nihil - 100% legit.mp4")
        XCTAssertEqual(item.title, "nihil - 100% legit")
        XCTAssertNotEqual(item.status, .downloading)
        XCTAssertEqual(item.progress, 0)
    }

    func testAlreadyDownloadedFilenameContainingMarkerTextKeepsFullPath() {
        // Cut at the LAST marker occurrence: a title containing the marker text
        // must not truncate the recorded path.
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] /tmp/out/nihil - This has already been downloaded.mp4 has already been downloaded", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/nihil - This has already been downloaded.mp4")
        XCTAssertEqual(item.title, "nihil - This has already been downloaded")
    }

    func testAlreadyDownloadedMarkerTextInFilenameWithAndMergedSuffix() {
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] /tmp/out/nihil - This has already been downloaded.mp4 has already been downloaded and merged", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/nihil - This has already been downloaded.mp4")
    }

    // MARK: - Progress line (regression: skip branch is checked first)

    func testProgressLineStillParsesAsProgress() {
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download]  45.3% of  15.42MiB at  2.34MiB/s ETA 00:05", into: item)

        XCTAssertEqual(item.status, .downloading)
        XCTAssertEqual(item.progress, 0.453, accuracy: 0.0001)
        XCTAssertEqual(item.totalSize, "15.42MiB")
        XCTAssertNil(item.outputPath)
    }

    // MARK: - Destination line (regression: must behave exactly as before)

    func testDestinationLineRecordsVideo() {
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] Destination: /tmp/out/nihil - some title.mp4", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoPath, "/tmp/out/nihil - some title.mp4")
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.title, "nihil - some title")
        XCTAssertEqual(item.mediaCategory, .video)
    }

    func testDestinationLineWithMarkerTextInFilenameIsNotMisroutedToSkipBranch() {
        // A Destination: line never ends with the skip marker, so the tail match
        // on the skip branch must let it fall through to the Destination branch.
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] Destination: /tmp/out/user - This has already been downloaded.mp4", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/user - This has already been downloaded.mp4")
        XCTAssertEqual(item.title, "user - This has already been downloaded")
    }

    func testDestinationLineImageDoesNotOverwriteVideoOutputPath() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse("[download] Destination: /tmp/out/user - clip.mp4", into: item)
        parse("[download] Destination: /tmp/out/user - pic_2.jpg", into: item)

        XCTAssertEqual(item.outputPath, "/tmp/out/user - clip.mp4")
        XCTAssertEqual(item.imageCount, 1)
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.mediaCategory, .mixed)
    }

    // MARK: - Deliverable counts (not pre-merge streams)

    func testTwitterHlsVideoPlusAudioStreamsCountAsOneVideo() {
        // Real Twitter HLS shape: video-only + audio-only (both `.mp4`), then
        // [Merger]. The user receives one file — videoCount must be 1, not 2.
        let item = DownloadItem(url: "https://x.com/SadieEasto56792/status/2079099121148014808")
        parse(
            "[download] Destination: /tmp/out/Sadie Easton - https：／／t.co／myMDm17pBk.fhls-230.mp4",
            into: item)
        parse(
            "[download] Destination: /tmp/out/Sadie Easton - https：／／t.co／myMDm17pBk.fhls-audio-64000-Audio.mp4",
            into: item)
        XCTAssertNil(item.videoCount, "pre-merge streams must not count as deliverables")
        XCTAssertEqual(item.audioPath, "/tmp/out/Sadie Easton - https：／／t.co／myMDm17pBk.fhls-audio-64000-Audio.mp4")

        parse(
            #"[Merger] Merging formats into "/tmp/out/Sadie Easton - https：／／t.co／myMDm17pBk.mp4""#,
            into: item)

        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.outputPath, "/tmp/out/Sadie Easton - https：／／t.co／myMDm17pBk.mp4")
        XCTAssertEqual(item.videoPath, "/tmp/out/Sadie Easton - https：／／t.co／myMDm17pBk.mp4")
        XCTAssertEqual(item.title, "Sadie Easton - https：／／t.co／myMDm17pBk")
        XCTAssertEqual(item.mediaCategory, .video)
    }

    func testTwoMergedPlaylistVideosCountAsTwo() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse("[download] Destination: /tmp/out/user - post.f230.mp4", into: item)
        parse("[download] Destination: /tmp/out/user - post.f140.m4a", into: item)
        parse(#"[Merger] Merging formats into "/tmp/out/user - post [01].mp4""#, into: item)
        parse("[download] Destination: /tmp/out/user - post.f231.mp4", into: item)
        parse("[download] Destination: /tmp/out/user - post.f141.m4a", into: item)
        parse(#"[Merger] Merging formats into "/tmp/out/user - post [02].mp4""#, into: item)

        XCTAssertEqual(item.videoCount, 2)
        XCTAssertEqual(item.outputPath, "/tmp/out/user - post [02].mp4")
    }

    func testSingleFinalDestinationStillCountsAsOneVideo() {
        // Combined progressive download — no intermediate format id, no merger.
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse("[download] Destination: /tmp/out/user - clip.mp4", into: item)
        YtDlpService.ensureFinalMediaCounts(item)

        XCTAssertEqual(item.videoCount, 1)
    }

    func testEnsureFinalMediaCountsFillsZeroWhenOnlyIntermediateRemains() {
        // Single-format download that keeps `.f…` in the on-disk name and never
        // emits a Merger line — still one deliverable for the user.
        let item = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] Destination: /tmp/out/nihil - clip.f299.mp4", into: item)
        XCTAssertNil(item.videoCount)
        YtDlpService.ensureFinalMediaCounts(item)

        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.title, "nihil - clip")
    }

    func testIntermediateFormatPathDetection() {
        XCTAssertTrue(YtDlpService.isIntermediateFormatPath("/tmp/a.fhls-230.mp4"))
        XCTAssertTrue(YtDlpService.isIntermediateFormatPath("/tmp/a.fhls-audio-64000-Audio.mp4"))
        XCTAssertTrue(YtDlpService.isIntermediateFormatPath("/tmp/a.f136.mp4"))
        XCTAssertFalse(YtDlpService.isIntermediateFormatPath("/tmp/a.mp4"))
        XCTAssertFalse(YtDlpService.isIntermediateFormatPath("/tmp/a [01].mp4"))
    }

    /// A run that downloads a resolved address never puts the tool's own
    /// line on the row: the tool quotes the address it was given, and the
    /// row's message goes on to notifications and history.
    func testErrorLinesOfAResolvedAddressRunNeverReachTheRow() {
        let address = "https://cc3001.dmm.co.jp/pv/SYNTHETICtokenAAAA/test00123hhb.mp4"
        let cases: [(line: String, expected: String)] = [
            ("ERROR: Unsupported URL: \(address)", DmmPreviewResolver.changedFormatMessage),
            ("ERROR: [generic] Unable to download webpage: HTTP Error 403: Forbidden (\(address))", YtDlpService.http403WithoutCookiesMessage),
            ("ERROR: unable to download video data: HTTP Error 403: Forbidden", YtDlpService.http403WithoutCookiesMessage),
            ("ERROR: [generic] \(address): Requested format is not available", YtDlpService.resolvedAddressFailedMessage),
            ("ERROR: [generic] Unable to download webpage: \(address) subtitle timed out", YtDlpService.resolvedAddressFailedMessage),
            ("ERROR: Postprocessing: ffmpeg not found. Please install or provide the path", YtDlpService.ffmpegMissingMessage),
        ]
        for c in cases {
            let item = DownloadItem(url: "https://video.dmm.co.jp/cinema/content/?id=test00123")
            item.resolvedAddress = address
            parse(c.line, into: item)
            XCTAssertEqual(item.status, .failed(c.expected), c.line)
            guard case .failed(let message) = item.status else { continue }
            XCTAssertFalse(message.contains("cc3001"), message)
            XCTAssertFalse(message.contains("SYNTHETICtoken"), message)
            XCTAssertFalse(message.lowercased().contains("cookie"), message)
        }
        XCTAssertEqual(
            YtDlpService.resolvedAddressFailedMessage,
            "The preview clip couldn't be downloaded — Retry; if it persists, update XDownloader.")

        // Every other link keeps the tool's line, as it always has.
        let direct = DownloadItem(url: address)
        parse("ERROR: Unsupported URL: \(address)", into: direct)
        XCTAssertEqual(direct.status, .failed("ERROR: Unsupported URL: \(address)"))
    }

    /// The output template keeps a literal '%' from a title. Such a
    /// Destination line must record its path, not parse as progress — the
    /// run would end with no file known and read as an "empty success".
    func testDestinationLineWithPercentInFilenameRecordsThePath() {
        let item = DownloadItem(url: "https://example.com/p")
        parse("[download] Destination: /tmp/out/maker - 50% more [test00123].mp4", into: item)
        XCTAssertEqual(item.outputPath, "/tmp/out/maker - 50% more [test00123].mp4")
        XCTAssertEqual(item.videoPath, "/tmp/out/maker - 50% more [test00123].mp4")
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertEqual(item.progress, 0)

        parse("[download]  45.3% of  15.42MiB at  2.34MiB/s ETA 00:05", into: item)
        XCTAssertEqual(item.progress, 0.453, accuracy: 0.0001)
        XCTAssertEqual(item.outputPath, "/tmp/out/maker - 50% more [test00123].mp4")
    }

    // MARK: - A list's own folder

    /// The list-folder steps report what they parsed, quoting the list's
    /// title. None of that is an error, progress or a file: a title that
    /// reads like an error, or holds a "%", leaves the row as it was.
    func testListFolderLinesNeverFailTheRow() {
        let item = DownloadItem(url: "https://x.com/a/status/1")
        let before = item.status
        for line in [
            "[MetadataParser] Parsed xdl_folder from '%(playlist_count,n_entries|)s#%(playlist_title,playlist_id).160B"
                + " [%(playlist_id).64B]': 'someone - ERROR: 50% off [1]'",
            "[MetadataParser] Changed xdl_folder to: someone - Error: 50% off ＄HOME [1]",
            "[MetadataParser] Could not interpret '%(playlist_count,n_entries|)s#…' as '(?s)^(?:[2-9]|[1-9][0-9]+)#…'",
            "[MetadataParser] Video does not have a xdl_folder",
        ] {
            parse(line, into: item)
            XCTAssertEqual(item.status, before, line)
        }
        XCTAssertEqual(item.progress, 0)
        XCTAssertNil(item.outputPath)
        XCTAssertNil(item.title)
        XCTAssertNil(item.lastToolWarning)
    }

    /// A single video's template has an empty folder field, so the tool
    /// reports "<root>//<name>". Every path is recorded as the single path
    /// it names: the same string a single video has always been recorded
    /// as, in history and in the next run's comparisons.
    func testTheEmptyFolderFieldsDoubledSeparatorIsNeverRecorded() {
        let video = DownloadItem(url: "https://x.com/a/status/1")
        parse("[download] Destination: /tmp/out//user - clip.mp4", into: video)
        XCTAssertEqual(video.outputPath, "/tmp/out/user - clip.mp4")
        XCTAssertEqual(video.videoPath, "/tmp/out/user - clip.mp4")
        XCTAssertEqual(video.title, "user - clip")

        let skipped = DownloadItem(url: "https://x.com/a/status/1")
        parse("[download] /tmp/out//user - clip.mp4 has already been downloaded", into: skipped)
        XCTAssertEqual(skipped.outputPath, "/tmp/out/user - clip.mp4")
        XCTAssertEqual(skipped.videoPath, "/tmp/out/user - clip.mp4")

        let merged = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[download] Destination: /tmp/out//nihil - clip.f299.mp4", into: merged)
        parse("[download] Destination: /tmp/out//nihil - clip.f140.m4a", into: merged)
        parse(#"[Merger] Merging formats into "/tmp/out//nihil - clip.mp4""#, into: merged)
        XCTAssertEqual(merged.outputPath, "/tmp/out/nihil - clip.mp4")
        XCTAssertEqual(merged.videoPath, "/tmp/out/nihil - clip.mp4")
        XCTAssertEqual(merged.audioPath, "/tmp/out/nihil - clip.f140.m4a")
        XCTAssertEqual(merged.videoCount, 1)

        let audio = DownloadItem(url: "https://youtube.com/watch?v=abc")
        parse("[ExtractAudio] Destination: /tmp/out//nihil - song.mp3", into: audio)
        XCTAssertEqual(audio.outputPath, "/tmp/out/nihil - song.mp3")
        XCTAssertEqual(audio.audioPath, "/tmp/out/nihil - song.mp3")

        let percent = DownloadItem(url: "https://example.com/p")
        parse("[download] Destination: /tmp/out//maker - 50% more.mp4", into: percent)
        XCTAssertEqual(percent.outputPath, "/tmp/out/maker - 50% more.mp4")
    }

    /// A list's files lie in its folder, whose name holds the list's title:
    /// a "%" there must not turn a Destination line or a skip notice into
    /// progress, or the run ends with no file known.
    func testAPercentSignInAListsFolderStillRecordsItsFiles() {
        let folder = "/tmp/out/someone - 50% off [1]"
        let item = DownloadItem(url: "https://x.com/a/status/1")
        parse("[download] Destination: \(folder)/someone - 50% off #1 [01].mp4", into: item)
        parse("[download] \(folder)/someone - 50% off #2 [02].mp4 has already been downloaded", into: item)

        XCTAssertEqual(item.videoCount, 2)
        XCTAssertEqual(item.outputPath, "\(folder)/someone - 50% off #2 [02].mp4")
        XCTAssertEqual(item.title, "someone - 50% off #1")
        XCTAssertEqual(item.progress, 0)
        XCTAssertTrue(item.videoDownloadedThisRun)
    }
}
