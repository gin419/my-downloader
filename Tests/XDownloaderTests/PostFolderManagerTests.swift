import XCTest

@testable import XDownloader

/// An X post's folder through DownloadManager itself: a folder an earlier
/// run made for the post is found by the id its name ends in and handed to
/// every tool of the run; a folder whose name holds a "$" is never handed to
/// a tool; and a mixed post's video, saved loose by yt-dlp before its photos
/// went into the post's folder, follows them in — only when yt-dlp saved it
/// in this very run, and never over a file already there. The yt-dlp and
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
        XCTAssertEqual(value(after: "--dest", in: secondSweep), folder.path)
        XCTAssertFalse(secondSweep.contains { $0.hasPrefix("directory=") })
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
    /// only reported it as already there.
    func testAVideoAlreadyOnDiskIsNeverMoved() async throws {
        let loose = downloads.appendingPathComponent(videoName)
        try Data("earlier".utf8).write(to: loose)
        let manager = try makeManager(ytDlp: savesVideo, galleryDl: photoPass(photos: 2))

        manager.capture(text: link, source: .field)

        let item = try XCTUnwrap(manager.items.first)
        try await waitUntil("the download finished") { self.history.count() == 1 }
        XCTAssertEqual(item.status, .completed)
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        XCTAssertEqual(try contents(of: downloads), [stem, videoName])
        XCTAssertEqual(try contents(of: folder), ["\(stem) #1.jpg", "\(stem) #2.jpg"])
        XCTAssertEqual(try Data(contentsOf: loose), Data("earlier".utf8))
        XCTAssertEqual(item.outputPath, loose.path)
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

    // MARK: - A photo post's found folder

    func testAFoundFolderIsHandedToEveryToolOfTheRun() async throws {
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
        XCTAssertEqual(value(after: "--output", in: ytDlp)?.hasPrefix(folder.path + "/"), true)
        let galleryDl = try XCTUnwrap(try runs(galleryDlArguments).last)
        XCTAssertEqual(value(after: "--dest", in: galleryDl), folder.path)
        XCTAssertFalse(galleryDl.contains { $0.hasPrefix("directory=") })
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

    /// yt-dlp on a photo post.
    private var findsNoVideo: String {
        """
        echo "ERROR: [twitter] \(id): No video could be found in this tweet"
        exit 1

        """
    }

    /// gallery-dl's photo pass after the video: `photos` photos of the
    /// pasted post, into its folder when the pass names the post (as the
    /// "directory" option asks), flat into the destination otherwise, each
    /// saved or reported as already there; then `then`.
    private func photoPass(photos: Int, then: String = "") -> String {
        """
        if [ "$sweep" = yes ]; then
            folder="$dest"
            case "$directory" in *tweet_id*) folder="$dest/\(stem)" ;; esac
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

    /// gallery-dl's run on a photo post: `photos` photos flat into the
    /// destination (the post's folder when one was handed over), each saved
    /// or reported as already there.
    private func postRun(stem: String, photos: Int = 2) -> String {
        """
        n=1
        while [ $n -le \(photos) ]; do
            file="$dest/\(stem) #$n.jpg"
            if [ -f "$file" ]; then
                echo "# $file"
            else
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
            dir=$(dirname "$out")

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
