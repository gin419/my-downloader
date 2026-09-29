import XCTest

@testable import XDownloader

/// An X post's folder through DownloadManager itself: a folder an earlier
/// run made for the post is found by the id its name ends in and takes the
/// post's files — yt-dlp's only when a video is in it; a folder whose name
/// holds a "$" is never handed to a tool; a mixed post's video, saved loose
/// by yt-dlp before its photos went into the post's folder, follows them in
/// — only when yt-dlp saved it in this very run, it is the post's only one,
/// and never over a file already there — and any other loose video keeps
/// its photos loose beside it; a post of several videos gets the folder
/// yt-dlp names for them, which its photos and the fallback join and which
/// is removed again when a failed run leaves it empty, or the post's folder
/// already on disk, never a second one; a YouTube list's folder is found by
/// the list's id; and a post pasted again fetches nothing it already has.
/// The yt-dlp and
/// gallery-dl the manager is given are scripts that record their arguments
/// and save or skip files the way the tools report them, so nothing here
/// touches the network, a browser or a cookie. Every name and id is
/// invented.
@MainActor
final class PostFolderManagerTests: XCTestCase {

    private let id = "1234567890123"
    private var link: String { "https://x.com/someone/status/\(id)" }
    /// The photos' stem as gallery-dl names them, and so their folder.
    private var stem: String { "someone - mixed [\(id)]" }
    /// The video's name as yt-dlp names it.
    private let videoName = "someone - mixed.mp4"

    private var root: URL!
    private var downloads: URL!
    private var history: HistoryStore!
    /// Each start's arguments, one per line, runs apart by a "--" line.
    private var ytDlpArguments: URL!
    private var galleryDlArguments: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PostFolderManagerTests-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        history = HistoryStore(directory: root.appendingPathComponent("stores"))
        ytDlpArguments = root.appendingPathComponent("yt-dlp-arguments")
        galleryDlArguments = root.appendingPathComponent("gallery-dl-arguments")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - A mixed post

    func testTheVideoFollowsItsPhotosIntoThePostsFolder() async throws {
        let queue = root.appendingPathComponent("queue", isDirectory: true)
        let manager = try makeManager(ytDlp: savesVideo, galleryDl: photoPass(photos: 2), queue: queue)

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        let moved = folder.appendingPathComponent(videoName).path
        XCTAssertEqual(try contents(of: downloads), [stem])
        XCTAssertEqual(try contents(of: folder), ["\(stem) #1.jpg", "\(stem) #2.jpg", videoName])
        XCTAssertEqual(item.videoPath, moved)
        XCTAssertEqual(item.outputPath, moved)
        XCTAssertEqual(item.imageCount, 2)
        XCTAssertEqual(item.videoCount, 1)
        // The photo pass named the pasted post, so its photos got their
        // folder though the pass counts them alone.
        let sweep = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertEqual(value(after: "--dest", in: sweep), downloads.path)
        XCTAssertTrue(
            sweep.contains { $0.hasPrefix(#"directory={"tweet_id == \#(id)": "#) }, sweep.joined(separator: " "))
        let entry = try XCTUnwrap(history.mostRecentCompleted(for: link))
        XCTAssertEqual(entry.outputPath, moved)
        XCTAssertEqual(entry.fileSizeBytes, 5)
        // The Done row comes back at the next launch as it was, pointing
        // into the folder, and is not queued again.
        let relaunched = try makeManager(ytDlp: savesVideo, galleryDl: photoPass(photos: 2), queue: queue)
        let restored = try XCTUnwrap(relaunched.items.first)
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.outputPath, moved)
        XCTAssertEqual(try runs(ytDlpArguments).count, 1)
        // Pasted into a list without the row, the duplicate warning finds
        // the saved file inside the folder.
        let elsewhere = try makeManager(ytDlp: savesVideo, galleryDl: photoPass(photos: 2))
        elsewhere.capture(text: link, source: .field)
        XCTAssertEqual(elsewhere.pendingDuplicates?.single?.priorFileExists, true)
        XCTAssertEqual(elsewhere.pendingDuplicates?.single?.priorEntry.outputPath, moved)

        // Pasted again: every tool is handed the post's folder, finds its
        // files there, and nothing is fetched or moved.
        // A Retry is taken once the first run has let go of the row.
        try await waitUntil("the retry was taken") {
            manager.retryItem(item)
            return item.status != .completed
        }
        try await waitUntil("the second run finished") {
            ((try? self.runs(self.ytDlpArguments).count) ?? 0) == 2 && item.status == .completed
        }
        XCTAssertEqual(item.status, .completed)
        let ytDlp = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(folder.path + "/"), true)
        let secondSweep = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertEqual(value(after: "--dest", in: secondSweep), downloads.path)
        XCTAssertTrue(secondSweep.contains { $0.hasPrefix(#"directory={"tweet_id == \#(id)": ["\#(stem)"]"#) })
        XCTAssertEqual(try contents(of: downloads), [stem])
        XCTAssertEqual(try contents(of: folder), ["\(stem) #1.jpg", "\(stem) #2.jpg", videoName])
        XCTAssertEqual(item.outputPath, moved)
        XCTAssertEqual(try String(contentsOf: fetchLog, encoding: .utf8).split(separator: "\n").count, 3)
    }

    func testWithoutPhotosTheVideoStaysLooseAndNoFolderIsMade() async throws {
        let manager = try makeManager(ytDlp: savesVideo, galleryDl: photoPass(photos: 0))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try contents(of: downloads), [videoName])
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent(videoName).path)
    }

    /// A video saved before posts had folders stays where it is: yt-dlp
    /// only reported it as already there. Its photos stay loose beside it,
    /// so the post is not split between a folder and the download folder.
    func testAVideoAlreadyOnDiskIsNeverMoved() async throws {
        let loose = downloads.appendingPathComponent(videoName)
        try Data("earlier".utf8).write(to: loose)
        let manager = try makeManager(ytDlp: savesVideo, galleryDl: photoPass(photos: 2))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try contents(of: downloads), ["\(stem) #1.jpg", "\(stem) #2.jpg", videoName])
        XCTAssertEqual(try Data(contentsOf: loose), Data("earlier".utf8))
        XCTAssertEqual(item.outputPath, loose.path)
        let sweep = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertEqual(value(after: "--dest", in: sweep), downloads.path)
        XCTAssertFalse(sweep.contains { $0.hasPrefix("directory=") })
    }

    /// A post of several videos gets the folder yt-dlp names for them,
    /// "<title> [<id>]", and its photos join them there. Pasted again, the
    /// folder is found by the id, handed to yt-dlp and the photo pass flat,
    /// and nothing is fetched.
    func testSeveralVideosGetTheirOwnFolderWithTheirPhotosAndARerunFetchesNothing() async throws {
        let manager = try makeManager(ytDlp: savesTwoVideos, galleryDl: photoPass(photos: 2))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.videoCount, 2)
        let folder = downloads.appendingPathComponent(listFolder, isDirectory: true)
        let everything = ["someone - mixed #1 [01].mp4", "someone - mixed #2 [02].mp4", "\(stem) #1.jpg", "\(stem) #2.jpg"]
        XCTAssertEqual(try contents(of: downloads), [listFolder])
        XCTAssertEqual(try contents(of: folder), everything)
        XCTAssertEqual(item.outputPath, folder.appendingPathComponent("someone - mixed #2 [02].mp4").path)
        let firstRun = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertTrue(firstRun.contains("--parse-metadata"))
        let sweep = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertEqual(value(after: "--dest", in: sweep), downloads.path)
        XCTAssertTrue(sweep.contains { $0.hasPrefix(#"directory={"tweet_id == \#(id)": ["\#(listFolder)"]"#) })
        XCTAssertEqual(try fetched().count, 4)
        XCTAssertEqual(history.mostRecentCompleted(for: link)?.outputPath, item.outputPath)

        try await waitUntil("the retry was taken") {
            manager.retryItem(item)
            return item.status != .completed
        }
        try await waitUntil("the second run finished") {
            ((try? self.runs(self.ytDlpArguments).count) ?? 0) == 2 && item.status == .completed
        }
        let ytDlp = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(folder.path + "/"), true)
        XCTAssertFalse(ytDlp.contains("--parse-metadata"))
        XCTAssertEqual(try contents(of: downloads), [listFolder])
        XCTAssertEqual(try contents(of: folder), everything)
        XCTAssertEqual(try fetched().count, 4, "nothing was fetched again")
        XCTAssertEqual(item.outputPath, folder.appendingPathComponent("someone - mixed #2 [02].mp4").path)
    }

    /// Several videos saved loose before lists had folders are never
    /// moved: they stay as they are, and yt-dlp, which looks for them only
    /// in the list's folder now, fetches the post again into it.
    func testSeveralVideosSavedLooseBeforeListsHadFoldersAreNeverMoved() async throws {
        let loose = ["someone - mixed #1 [01].mp4", "someone - mixed #2 [02].mp4"]
        for name in loose { try Data("earlier".utf8).write(to: downloads.appendingPathComponent(name)) }
        let manager = try makeManager(ytDlp: savesTwoVideos, galleryDl: photoPass(photos: 0))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try contents(of: downloads), loose + [listFolder])
        for name in loose {
            XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent(name)), Data("earlier".utf8))
        }
        XCTAssertEqual(try contents(of: downloads.appendingPathComponent(listFolder)), loose)
    }

    /// yt-dlp saved one video of the post into its folder and then failed:
    /// the fallback writes into that folder too, so the post is not split
    /// between two folders of the same id.
    func testAListThatFailedPartWaySendsTheFallbackIntoItsFolder() async throws {
        let manager = try makeManager(ytDlp: savesOneVideoThenFails, galleryDl: postRun(stem: listFolder))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let galleryDl = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertEqual(value(after: "--dest", in: galleryDl), downloads.path)
        XCTAssertTrue(galleryDl.contains { $0.hasPrefix(#"directory={"tweet_id == \#(id)": ["\#(listFolder)"]"#) })
        XCTAssertEqual(try contents(of: downloads), [listFolder])
        XCTAssertEqual(
            try contents(of: downloads.appendingPathComponent(listFolder)),
            ["someone - mixed #1 [01].mp4", "\(listFolder) #1.jpg", "\(listFolder) #2.jpg"])
    }

    /// A folder yt-dlp made for the post's videos and left empty — every
    /// video failed before a byte arrived — is removed when the row ends,
    /// so no later run finds it and writes into it. A folder of the post
    /// that was there before the run stays, empty or not.
    func testAListFolderLeftEmptyByTheRunIsRemoved() async throws {
        let earlier = downloads.appendingPathComponent("someone - $HOME [\(id)]", isDirectory: true)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        let manager = try makeManager(
            ytDlp: makesTheListFolderThenFails, galleryDl: postRun(stem: "someone - two photos [\(id)]"))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        try await waitUntil("the row let go") { !FileManager.default.fileExists(atPath: self.downloads.appendingPathComponent(self.listFolder).path) }
        XCTAssertEqual(try contents(of: downloads), [earlier.lastPathComponent, "someone - two photos [\(id)]"])
        XCTAssertEqual(try contents(of: earlier), [])
    }

    /// A post split before this fix — its video loose, its photos in the
    /// post's folder — pasted again: yt-dlp looks where the video is, the
    /// photo pass where the photos are, and nothing is fetched or moved.
    func testASplitPostPastedAgainFetchesNothing() async throws {
        let loose = downloads.appendingPathComponent(videoName)
        try Data("earlier".utf8).write(to: loose)
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 1...2 {
            try Data("photo".utf8).write(to: folder.appendingPathComponent("\(stem) #\(n).jpg"))
        }
        let manager = try makeManager(ytDlp: savesVideo, galleryDl: photoPass(photos: 2))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let ytDlp = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(downloads.path + "/"), true)
        let sweep = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertEqual(value(after: "--dest", in: sweep), downloads.path)
        XCTAssertTrue(sweep.contains { $0.hasPrefix(#"directory={"tweet_id == \#(id)": ["\#(stem)"]"#) })
        XCTAssertEqual(try fetched(), [], "nothing was fetched")
        XCTAssertEqual(try contents(of: downloads), [stem, videoName])
        XCTAssertEqual(try contents(of: folder), ["\(stem) #1.jpg", "\(stem) #2.jpg"])
        XCTAssertEqual(try Data(contentsOf: loose), Data("earlier".utf8))
        XCTAssertEqual(item.outputPath, loose.path)
    }

    /// A folder found with the post's photos and no video: yt-dlp saves the
    /// video loose, where it looks for it, and the video then follows the
    /// photos into the folder, as on a first run.
    func testAVideoSavedBesideAFoundFolderFollowsItsPhotosIn() async throws {
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 1...2 {
            try Data("photo".utf8).write(to: folder.appendingPathComponent("\(stem) #\(n).jpg"))
        }
        let manager = try makeManager(ytDlp: savesVideo, galleryDl: photoPass(photos: 2))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try fetched().count, 1, "only the video was fetched")
        XCTAssertEqual(try contents(of: downloads), [stem])
        XCTAssertEqual(try contents(of: folder), ["\(stem) #1.jpg", "\(stem) #2.jpg", videoName])
        XCTAssertEqual(item.outputPath, folder.appendingPathComponent(videoName).path)
    }

    /// A file of the video's name already in the folder is never replaced:
    /// the video stays loose and the row points at it.
    func testANameTakenInTheFolderLeavesTheVideoLoose() async throws {
        let manager = try makeManager(
            ytDlp: savesVideo,
            galleryDl: photoPass(photos: 2, then: #"printf 'other' > "$folder/\#(videoName)""#))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        let loose = downloads.appendingPathComponent(videoName)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(videoName)), Data("other".utf8))
        XCTAssertEqual(try Data(contentsOf: loose), Data("video".utf8))
        XCTAssertEqual(item.outputPath, loose.path)
        XCTAssertEqual(item.videoPath, loose.path)
    }

    /// A folder holding the post's video as gallery-dl numbered it — saved
    /// by the fallback after a partial yt-dlp run — is not yt-dlp's: yt-dlp
    /// keeps to the download folder, where its own copy lies, and pasted
    /// again the post fetches nothing.
    func testAGalleryDlVideoInTheFolderKeepsYtDlpWithItsLooseVideo() async throws {
        let loose = downloads.appendingPathComponent(videoName)
        try Data("earlier".utf8).write(to: loose)
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["\(stem) #1.jpg", "\(stem) #2.jpg", "\(stem) #3.mp4"] {
            try Data("earlier".utf8).write(to: folder.appendingPathComponent(name))
        }
        let manager = try makeManager(ytDlp: savesVideo, galleryDl: photoPass(photos: 2))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        // The folder is named in the template only for a list of two or
        // more; a single video steps back out of it to the download folder.
        let ytDlp = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(folder.path + "/%(xdl_up|)s/"), true)
        XCTAssertTrue(ytDlp.contains("--parse-metadata"))
        XCTAssertFalse(ytDlp.contains { $0.contains("xdl_folder") })
        XCTAssertEqual(try fetched(), [], "nothing was fetched")
        XCTAssertEqual(try contents(of: downloads), [stem, videoName])
        XCTAssertEqual(try contents(of: folder), ["\(stem) #1.jpg", "\(stem) #2.jpg", "\(stem) #3.mp4"])
        XCTAssertEqual(try Data(contentsOf: loose), Data("earlier".utf8))
        XCTAssertEqual(item.outputPath, loose.path)
    }

    /// A folder the fallback made for a post of several videos, holding
    /// only gallery-dl's numbered files: yt-dlp, finding the post to be a
    /// list, saves the videos into that folder rather than naming a second
    /// one of the same id, and the photo pass looks there too. Pasted
    /// again, yt-dlp is handed the folder, finds its videos, and nothing is
    /// fetched.
    func testAListGoesIntoTheFolderGalleryDlMadeAndARerunFetchesNothing() async throws {
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let earlier = ["\(stem) #1.jpg", "\(stem) #2.mp4", "\(stem) #3.mp4"]
        for name in earlier { try Data("earlier".utf8).write(to: folder.appendingPathComponent(name)) }
        let manager = try makeManager(ytDlp: savesTwoVideos, galleryDl: photoPass(photos: 1))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let videos = ["someone - mixed #1 [01].mp4", "someone - mixed #2 [02].mp4"]
        XCTAssertEqual(try contents(of: downloads), [stem], "one folder for the post")
        XCTAssertEqual(try contents(of: folder), (earlier + videos).sorted())
        for name in earlier {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), Data("earlier".utf8))
        }
        // yt-dlp's own copies of the videos, as before this change; the
        // photo was already there.
        XCTAssertEqual(try fetched().count, 2)
        XCTAssertEqual(item.outputPath, folder.appendingPathComponent(videos[1]).path)
        let firstRun = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: firstRun)?.hasPrefix(folder.path + "/%(xdl_up|)s/"), true)
        XCTAssertFalse(firstRun.contains { $0.contains("xdl_folder") })
        let sweep = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertTrue(sweep.contains { $0.hasPrefix(#"directory={"tweet_id == \#(id)": ["\#(stem)"]"#) })

        try await waitUntil("the retry was taken") {
            manager.retryItem(item)
            return item.status != .completed
        }
        try await waitUntil("the second run finished") {
            ((try? self.runs(self.ytDlpArguments).count) ?? 0) == 2 && item.status == .completed
        }
        let ytDlp = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(folder.path + "/%(title)s"), true)
        XCTAssertFalse(ytDlp.contains("--parse-metadata"))
        XCTAssertEqual(try contents(of: downloads), [stem])
        XCTAssertEqual(try contents(of: folder), (earlier + videos).sorted())
        XCTAssertEqual(try fetched().count, 2, "nothing was fetched again")
    }

    /// A found folder that is a link is handed to yt-dlp flat: the step
    /// back out of it would lead to the folder the link points into, not
    /// the download folder. Nothing lands outside the found folder.
    func testAFoundFolderThatIsALinkIsHandedFlat() async throws {
        let target = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: target.appendingPathComponent("\(stem) #1.jpg"))
        let linked = downloads.appendingPathComponent(stem)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        let manager = try makeManager(ytDlp: savesVideo, galleryDl: photoPass(photos: 1))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let ytDlp = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(linked.path + "/%(title)s"), true)
        XCTAssertFalse(ytDlp.contains("--parse-metadata"))
        XCTAssertEqual(try contents(of: target), ["\(stem) #1.jpg", videoName])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(videoName).path))
        XCTAssertEqual(try contents(of: downloads), [stem])
    }

    /// A YouTube list renamed since its first run: its folder is found by
    /// the list's id, which the link carries, and handed to yt-dlp flat,
    /// which finds every video there and fetches nothing — not a second
    /// folder under the new title.
    func testARenamedYouTubeListIsFoundByItsIDAndFetchesNothing() async throws {
        let listID = "PLsynthetic01"
        let folder = downloads.appendingPathComponent("Old Mix [\(listID)]", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clips = ["Chan - Clip 1.mp4", "Chan - Clip 2.mp4"]
        for name in clips { try Data("earlier".utf8).write(to: folder.appendingPathComponent(name)) }
        let youTubeList = """
            list=$(list_dir "Renamed Mix [\(listID)]")
            for n in 1 2; do
                file="$list/Chan - Clip $n.mp4"
                if [ -f "$file" ]; then
                    echo "[download] $file has already been downloaded"
                else
                    mkdir -p "$list"
                    printf 'video' > "$file"
                    echo "$file" >> "\(fetchLog.path)"
                    echo "[download] Destination: $file"
                    echo "[download] 100% of 5.00B in 00:00"
                fi
            done
            exit 0

            """
        let manager = try makeManager(ytDlp: youTubeList, galleryDl: photoPass(photos: 0))
        let playlist = "https://www.youtube.com/playlist?list=\(listID)"

        manager.capture(text: playlist, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let ytDlp = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(folder.path + "/%(uploader)s"), true)
        XCTAssertFalse(ytDlp.contains("--parse-metadata"))
        XCTAssertEqual(try fetched(), [], "nothing was fetched")
        XCTAssertEqual(try contents(of: downloads), [folder.lastPathComponent])
        XCTAssertEqual(try contents(of: folder), clips)
        XCTAssertEqual(item.outputPath, folder.appendingPathComponent(clips[1]).path)
    }

    /// Only a video named as yt-dlp names its own makes a folder yt-dlp's:
    /// gallery-dl's and the fxtwitter rescue's numbered videos do not, nor
    /// do photos.
    func testOnlyAVideoOfYtDlpsOwnMakesAFolderItsOwn() throws {
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(DownloadManager.holdsAVideo(folder))
        for name in ["\(stem) #1.jpg", "\(stem) #2.mp4", "\(stem) #10.MOV"] {
            try Data("earlier".utf8).write(to: folder.appendingPathComponent(name))
        }
        XCTAssertFalse(DownloadManager.holdsAVideo(folder))
        try Data("video".utf8).write(to: folder.appendingPathComponent(videoName))
        XCTAssertTrue(DownloadManager.holdsAVideo(folder))

        let numbered = downloads.appendingPathComponent("numbered [\(id)]", isDirectory: true)
        try FileManager.default.createDirectory(at: numbered, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: numbered.appendingPathComponent("someone - mixed [01].mp4"))
        XCTAssertTrue(DownloadManager.holdsAVideo(numbered))
    }

    // MARK: - A photo post's found folder

    /// A found folder holding photos only takes gallery-dl's files for the
    /// post; yt-dlp keeps to the download folder, where a video of the post
    /// would be.
    func testAFoundFolderTakesThePostsFilesFromGalleryDl() async throws {
        let folder = downloads.appendingPathComponent("someone - two photos [\(id)]", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 1...2 {
            try Data("photo".utf8).write(to: folder.appendingPathComponent("someone - two photos [\(id)] #\(n).jpg"))
        }
        let manager = try makeManager(ytDlp: findsNoVideo, galleryDl: postRun(stem: "someone - two photos [\(id)]"))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let ytDlp = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(downloads.path + "/"), true)
        let galleryDl = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertEqual(value(after: "--dest", in: galleryDl), downloads.path)
        XCTAssertTrue(
            galleryDl.contains { $0.hasPrefix(#"directory={"tweet_id == \#(id)": ["someone - two photos [\#(id)]"]"#) })
        XCTAssertEqual(try contents(of: downloads), [folder.lastPathComponent])
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(item.outputPath)).deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(try contents(of: folder).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fetchLog.path), "nothing was fetched")
    }

    /// A found folder whose name holds a "$" is never handed to a tool,
    /// which would expand it; the tools pick their own folder.
    func testAFolderWhoseNameHoldsADollarSignIsNeverHandedToATool() async throws {
        let odd = downloads.appendingPathComponent("someone - $HOME [\(id)]", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: odd.appendingPathComponent("kept.jpg"))
        let manager = try makeManager(ytDlp: findsNoVideo, galleryDl: postRun(stem: "someone - one photo [\(id)]", photos: 1))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let ytDlp = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(downloads.path + "/"), true)
        XCTAssertFalse(ytDlp.contains { $0.contains("$") })
        let galleryDl = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertEqual(value(after: "--dest", in: galleryDl), downloads.path)
        XCTAssertTrue(galleryDl.contains { $0.hasPrefix(#"directory={"count > 1": "#) })
        XCTAssertFalse(galleryDl.contains { $0.contains("$") })
        XCTAssertEqual(try contents(of: odd), ["kept.jpg"])
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent("someone - one photo [\(id)].jpg").path)
    }

    /// A found folder whose name holds a tab is not the folder gallery-dl
    /// would write to — it drops the tab — so it is never handed to a tool
    /// either; the tools pick their own folder, and the found one is left
    /// as it was.
    func testAFolderWhoseNameHoldsATabIsNeverHandedToATool() async throws {
        let odd = downloads.appendingPathComponent("someone - tab\there [\(id)]", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: odd.appendingPathComponent("kept.jpg"))
        let manager = try makeManager(ytDlp: findsNoVideo, galleryDl: postRun(stem: "someone - one photo [\(id)]", photos: 1))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let ytDlp = try XCTUnwrap(try runs(ytDlpArguments).last)
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(downloads.path + "/"), true)
        XCTAssertFalse(ytDlp.contains { $0.contains("\t") })
        let galleryDl = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertTrue(galleryDl.contains { $0.hasPrefix(#"directory={"count > 1": "#) })
        XCTAssertFalse(galleryDl.contains { $0.contains("\t") || $0.contains(#"\t"#) })
        XCTAssertEqual(try contents(of: odd), ["kept.jpg"])
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent("someone - one photo [\(id)].jpg").path)
    }

    // MARK: - Tools

    /// One line per file a fake tool wrote.
    private var fetchLog: URL { root.appendingPathComponent("fetched") }

    /// yt-dlp saving the post's one video where its template says, or
    /// reporting it already there, as yt-dlp does.
    private var savesVideo: String {
        """
        file="$dir/\(videoName)"
        if [ -f "$file" ]; then
            echo "[download] $file has already been downloaded"
        else
            printf 'video' > "$file"
            echo "$file" >> "\(fetchLog.path)"
            echo "[download] Destination: $file"
            echo "[download] 100% of 5.00B in 00:00"
        fi
        exit 0

        """
    }

    /// The folder yt-dlp names for the post's videos, "<list title> [<id>]"
    /// — spelled apart from gallery-dl's `stem`, as the tools spell it.
    private var listFolder: String { "someone - two videos [\(id)]" }

    /// yt-dlp's report of the list's folder, quoting a title that reads
    /// like an error and holds a "%".
    private var listFolderReport: String {
        #"echo "[MetadataParser] Parsed xdl_folder from '%(playlist_count,n_entries|)s#…': 'someone - Error: 50% [\#(id)]'""#
    }

    /// yt-dlp saving a post's two videos into the list's folder, named as
    /// the X template names them, or reporting them already there.
    private var savesTwoVideos: String {
        """
        list=$(list_dir "\(listFolder)")
        for n in 1 2; do
            \(listFolderReport)
            file="$list/someone - mixed #$n [0$n].mp4"
            if [ -f "$file" ]; then
                echo "[download] $file has already been downloaded"
            else
                mkdir -p "$list"
                printf 'video' > "$file"
                echo "$file" >> "\(fetchLog.path)"
                echo "[download] Destination: $file"
                echo "[download] 100% of 5.00B in 00:00"
            fi
        done
        exit 0

        """
    }

    /// yt-dlp saving the first of the post's two videos into the list's
    /// folder, then failing on the second.
    private var savesOneVideoThenFails: String {
        """
        list=$(list_dir "\(listFolder)")
        \(listFolderReport)
        mkdir -p "$list"
        file="$list/someone - mixed #1 [01].mp4"
        printf 'video' > "$file"
        echo "[download] Destination: $file"
        echo "[download] 100% of 5.00B in 00:00"
        \(listFolderReport)
        echo "ERROR: [twitter] \(id): unable to download video data: HTTP Error 404: Not Found"
        exit 1

        """
    }

    /// yt-dlp making the list's folder, as it does before the first byte,
    /// then failing on every video.
    private var makesTheListFolderThenFails: String {
        """
        list=$(list_dir "\(listFolder)")
        \(listFolderReport)
        mkdir -p "$list"
        echo "ERROR: [twitter] \(id): unable to download video data: HTTP Error 404: Not Found"
        exit 1

        """
    }

    private func fetched() throws -> [String] {
        guard FileManager.default.fileExists(atPath: fetchLog.path) else { return [] }
        return try String(contentsOf: fetchLog, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// yt-dlp on a photo post.
    private var findsNoVideo: String {
        """
        echo "ERROR: [twitter] \(id): No video could be found in this tweet"
        exit 1

        """
    }

    /// gallery-dl's photo pass after the video: `photos` photos of the
    /// pasted post, into its folder when the pass names the post (as the
    /// "directory" option asks: the folder it names, or the post's `stem`
    /// for a name gallery-dl would fill in), flat into the destination
    /// otherwise, each saved or reported as already there; then `then`.
    private func photoPass(photos: Int, then: String = "") -> String {
        """
        if [ "$sweep" = yes ]; then
            folder="$dest"
            case "$directory" in *tweet_id*)
                name=$(printf '%s' "$directory" | sed -n 's/.*"tweet_id == [0-9]*": \\["\\([^"]*\\)"\\].*/\\1/p')
                case "$name" in *"{"*) name="\(stem)" ;; esac
                folder="$dest/$name" ;;
            esac
            n=1
            while [ $n -le \(photos) ]; do
                file="$folder/\(stem) #$n.jpg"
                if [ -f "$file" ]; then
                    echo "# $file"
                else
                    mkdir -p "$folder"
                    printf 'photo' > "$file"
                    echo "$file" >> "\(fetchLog.path)"
                    echo "$file"
                fi
                n=$((n + 1))
            done
            \(then)
        fi
        exit 0

        """
    }

    /// gallery-dl's run on a photo post: `photos` photos placed as the
    /// "directory" option asks — into the folder it names for the post, or
    /// into a folder of the stem for two or more when it asks by count — or
    /// flat into the destination, each saved or reported as already there.
    private func postRun(stem: String, photos: Int = 2) -> String {
        """
        folder="$dest"
        case "$directory" in
            *'"tweet_id == \(id)": ["\(stem)"]'*) folder="$dest/\(stem)" ;;
            *'"count > 1"'*) if [ \(photos) -gt 1 ]; then folder="$dest/\(stem)"; fi ;;
        esac
        n=1
        while [ $n -le \(photos) ]; do
            file="$folder/\(stem) #$n.jpg"
            if [ -f "$file" ]; then
                echo "# $file"
            else
                mkdir -p "$folder"
                printf 'photo' > "$file"
                echo "$file" >> "\(fetchLog.path)"
                echo "$file"
            fi
            n=$((n + 1))
        done
        exit 0

        """
    }

    // MARK: - Helpers

    /// `queue` names a saved queue to share with another manager, as the
    /// next launch does.
    private func makeManager(ytDlp: String, galleryDl: String, queue: URL? = nil) throws -> DownloadManager {
        let ytDlpScript = root.appendingPathComponent("yt-dlp")
        let galleryDlScript = root.appendingPathComponent("gallery-dl")
        let ytDlpHeader = """
            #!/bin/sh
            case "$1" in --version) echo 2026.01.01; exit 0 ;; esac
            printf '%s\\n' "$@" -- >> "\(ytDlpArguments.path)"
            out=""
            previous=""
            for argument in "$@"; do
                if [ "$previous" = "--output" ]; then out="$argument"; fi
                previous="$argument"
            done
            # The template's directory, read as yt-dlp reads it: an empty
            # list-folder field leaves "<root>//<name>", as yt-dlp reports a
            # single video, and a found folder's step back leaves
            # "<found>/../<name>"; `list_dir` is the folder a list of two or
            # more takes — the one the template names, the found folder, or
            # the folder handed.
            dir=$(dirname "$out")
            field='/%(xdl_folder|)s'
            up='/%(xdl_up|)s'
            root_dir=""
            found_dir=""
            case "$dir" in
                *"$field") root_dir="${dir%"$field"}"; dir="$root_dir/" ;;
                *"$up") found_dir=$(printf '%s' "${dir%"$up"}" | sed 's/%%/%/g'); dir="$found_dir/.." ;;
            esac
            dir=$(printf '%s' "$dir" | sed 's/%%/%/g')
            list_dir() {
                if [ -n "$root_dir" ]; then printf '%s' "$root_dir/$1"
                elif [ -n "$found_dir" ]; then printf '%s' "$found_dir/"
                else printf '%s' "${dir%/}"; fi
            }

            """
        let galleryDlHeader = """
            #!/bin/sh
            case "$1" in --version) echo 1.0.0; exit 0 ;; esac
            printf '%s\\n' "$@" -- >> "\(galleryDlArguments.path)"
            dest=""
            directory=""
            sweep=no
            previous=""
            for argument in "$@"; do
                if [ "$previous" = "--dest" ]; then dest="$argument"; fi
                case "$argument" in
                    directory=*) directory="$argument" ;;
                    videos=false) sweep=yes ;;
                esac
                previous="$argument"
            done

            """
        try Data((ytDlpHeader + ytDlp).utf8).write(to: ytDlpScript)
        try Data((galleryDlHeader + galleryDl).utf8).write(to: galleryDlScript)
        for script in [ytDlpScript, galleryDlScript] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let manager = DownloadManager(
            history: history,
            queueStore: QueueStore(directory: queue ?? root.appendingPathComponent("queue-\(UUID().uuidString)")),
            settingsStore: SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "post-folder-\(UUID().uuidString)"))),
            likesSyncStore: LikesSyncStore(directory: root.appendingPathComponent("stores")),
            galleryDlPathProvider: { galleryDlScript.path },
            ytDlpPathProvider: { ytDlpScript.path })
        manager.outputDirectory = downloads
        if queue == nil { XCTAssertEqual(manager.items.count, 0) }
        return manager
    }

    /// Each recorded start's arguments.
    private func runs(_ log: URL) throws -> [[String]] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        var runs: [[String]] = []
        var current: [String] = []
        for line in try String(contentsOf: log, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "--" {
                runs.append(current)
                current = []
            } else if !line.isEmpty {
                current.append(String(line))
            }
        }
        return runs
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func waitUntil(
        _ what: String, seconds: TimeInterval = 10, line: UInt = #line, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting until \(what)", line: line)
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
