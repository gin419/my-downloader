import XCTest

@testable import XDownloader

/// Where gallery-dl puts a single post's files: its command line asks it to
/// give a post of two or more files a folder of its own, decided by the
/// post's own count before anything is written, and only X and Instagram
/// declare the folder's name. Every name here is invented.
@MainActor
final class GalleryDlFolderArgumentTests: XCTestCase {

    private let downloads = URL(fileURLWithPath: "/tmp/xdownloader-tests/downloads")
    private let tweet = "https://x.com/someone/status/1234567890123"
    private let post = "https://www.instagram.com/p/SYNpost0001_/"

    private let twitterFolder = #"["{author[nick]} - {content!s:.100} [{tweet_id}]"]"#
    private let instagramFolder = #"["{username} - {description|''!s:.100} [{post_shortcode}]"]"#

    func testTwitterAndInstagramAskForAFolderRightAfterTheDirectoryFlag() throws {
        let cases = [
            (tweet, #"directory={"count > 1": \#(twitterFolder), "": []}"#),
            (post, #"directory={"count > 1": \#(instagramFolder), "": []}"#),
        ]
        for (link, expected) in cases {
            let args = GalleryDlService.arguments(
                for: link, outputDirectory: downloads, folderMode: .perPostIfMultiple,
                cookieBrowser: .chrome, cookiesFile: nil)
            let flag = try XCTUnwrap(args.firstIndex(of: "-D"), link)
            XCTAssertEqual(Array(args[flag...flag + 3]), ["-D", ".", "-o", expected], link)
            XCTAssertEqual(value(after: "--dest", in: args), downloads.path, link)
            XCTAssertEqual(directoryOptions(args).count, 1, link)
            try assertValidJSON(expected)
        }
    }

    /// The folder is the file-name template less its number, so the folder
    /// and the files in it read the same.
    func testTheFolderFormatIsTheFileNameLessItsNumber() throws {
        for profile in [SiteRegistry.twitter, SiteRegistry.instagram] {
            let fileFormat = try XCTUnwrap(value(after: "-f", in: profile.galleryDlArgs))
            let folder = try XCTUnwrap(profile.galleryDlFolderFormat)
            XCTAssertEqual(fileFormat, folder + " #{num}.{extension}", profile.id)
        }
    }

    func testSitesWithoutAFolderFormatAndTheOtherRunsAskForNone() {
        for link in ["https://www.reddit.com/r/invented/comments/abc123/x/", "https://example.com/a.jpg"] {
            let args = GalleryDlService.arguments(
                for: link, outputDirectory: downloads, folderMode: .perPostIfMultiple,
                cookieBrowser: .chrome, cookiesFile: nil)
            XCTAssertEqual(directoryOptions(args), [], link)
        }
        // The default, the photo pass's extra args and the profile: flat.
        for link in [tweet, post] {
            XCTAssertEqual(
                directoryOptions(
                    GalleryDlService.arguments(
                        for: link, outputDirectory: downloads, cookieBrowser: .chrome, cookiesFile: nil,
                        extraArgs: ["-o", "videos=false"])), [], link)
        }
        let profile = GalleryDlService.profileArguments(
            username: "someone.invented", postLimit: 5, outputDirectory: downloads.appendingPathComponent("someone.invented"),
            cookieBrowser: .chrome, cookiesFile: nil)
        XCTAssertEqual(directoryOptions(profile), [])
    }

    /// A folder found for the post takes every file flat: it is the
    /// destination, and no folder is asked for inside it.
    func testAFoundFolderIsTheDestinationAndGetsNoFolderInside() {
        let folder = downloads.appendingPathComponent("someone - two photos [1234567890123]", isDirectory: true)
        let args = GalleryDlService.arguments(
            for: tweet, outputDirectory: downloads, folderMode: .into(folder), cookieBrowser: .chrome, cookiesFile: nil)
        XCTAssertEqual(value(after: "--dest", in: args), folder.path)
        XCTAssertEqual(value(after: "-D", in: args), ".")
        XCTAssertEqual(directoryOptions(args), [])
    }

    /// The photo pass names the pasted post first: its count leaves out the
    /// video, and the post's photos must still share a folder with it.
    func testThePhotoPassNamesThePastedPostFirst() throws {
        let tweetCondition = try XCTUnwrap(GalleryDlService.ownPostCondition(for: tweet))
        XCTAssertEqual(tweetCondition, "tweet_id == 1234567890123")
        let postCondition = try XCTUnwrap(GalleryDlService.ownPostCondition(for: post))
        XCTAssertEqual(postCondition, #"post_shortcode == "SYNpost0001_""#)
        XCTAssertNil(GalleryDlService.ownPostCondition(for: "https://www.instagram.com/share/SYNshare01/"))

        let tweetArgs = GalleryDlService.arguments(
            for: tweet, outputDirectory: downloads, folderMode: .perPost(always: tweetCondition),
            cookieBrowser: .chrome, cookiesFile: nil, extraArgs: ["-o", "videos=false"])
        let expectedTweet = #"directory={"tweet_id == 1234567890123": \#(twitterFolder), "count > 1": \#(twitterFolder), "": []}"#
        XCTAssertEqual(directoryOptions(tweetArgs), [expectedTweet])
        try assertValidJSON(expectedTweet)

        let postArgs = GalleryDlService.arguments(
            for: post, outputDirectory: downloads, folderMode: .perPost(always: postCondition),
            cookieBrowser: .chrome, cookiesFile: nil, extraArgs: ["-o", "videos=false"])
        let expectedPost =
            #"directory={"post_shortcode == \"SYNpost0001_\"": \#(instagramFolder), "count > 1": \#(instagramFolder), "": []}"#
        XCTAssertEqual(directoryOptions(postArgs), [expectedPost])
        try assertValidJSON(expectedPost)
    }

    // MARK: - Helpers

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func directoryOptions(_ args: [String]) -> [String] {
        args.filter { $0.hasPrefix("directory=") }
    }

    /// gallery-dl reads the value as JSON: an object, keys in order.
    private func assertValidJSON(_ option: String, line: UInt = #line) throws {
        let json = String(option.dropFirst("directory=".count))
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertTrue(object is [String: Any], line: line)
    }
}

/// `GalleryDlService.run` against a fake gallery-dl that saves and reports
/// files the way gallery-dl does: which files are the row's, which " #1" is
/// dropped, and where the row points when the tool reports a file that was
/// saved before posts had folders. Everything happens in a temporary folder.
@MainActor
final class GalleryDlFolderRunTests: XCTestCase {

    private var root: URL!
    private var downloads: URL!
    private var argumentsLog: URL!
    private let link = "https://x.com/someone/status/1234567890123"
    private let stem = "someone - two photos [1234567890123]"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GalleryDlFolderRunTests-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("downloads", isDirectory: true)
        argumentsLog = root.appendingPathComponent("arguments")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testATwoFilePostIsSavedInItsFolderWithItsNumbers() async throws {
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        let item = try await run(saving: [
            folder.appendingPathComponent("\(stem) #1.jpg"), folder.appendingPathComponent("\(stem) #2.jpg"),
        ])

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.imageCount, 2)
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(item.outputPath)).deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(try contents(of: folder), ["\(stem) #1.jpg", "\(stem) #2.jpg"])
        XCTAssertEqual(try contents(of: downloads), [stem])
        XCTAssertEqual(item.title, "someone - two photos")
    }

    /// A quoted tweet's one photo lies loose beside the main tweet's folder:
    /// only the loose one loses its " #1".
    func testOnlyTheLooseFileLosesItsNumber() async throws {
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        let quoted = "other - quoted [9876543210987]"
        let item = try await run(saving: [
            folder.appendingPathComponent("\(stem) #1.jpg"),
            folder.appendingPathComponent("\(stem) #2.jpg"),
            downloads.appendingPathComponent("\(quoted) #1.jpg"),
        ])

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try contents(of: downloads), ["\(quoted).jpg", stem])
        XCTAssertEqual(try contents(of: folder), ["\(stem) #1.jpg", "\(stem) #2.jpg"])
        let output = try XCTUnwrap(item.outputPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output), output)
    }

    /// A one-file post stays loose and loses its " #1", as it always has.
    func testAOneFilePostStaysLooseAndLosesItsNumber() async throws {
        let item = try await run(saving: [downloads.appendingPathComponent("\(stem) #1.jpg")])

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try contents(of: downloads), ["\(stem).jpg"])
        XCTAssertEqual(item.outputPath, downloads.appendingPathComponent("\(stem).jpg").path)
    }

    /// The download archive answers for a file saved loose before posts had
    /// folders with the path the file would have now: the row points at the
    /// loose file that is really there, and nothing is moved or made.
    func testAnArchiveHitPointsAtTheLooseFileThatIsThere() async throws {
        let loose = downloads.appendingPathComponent("\(stem) #1.jpg")
        try Data("earlier".utf8).write(to: loose)
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        let item = try await run(
            saying: [
                "# \(folder.appendingPathComponent("\(stem) #1.jpg").path)",
                "# \(folder.appendingPathComponent("\(stem) #2.jpg").path)",
            ])

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.outputPath, loose.path)
        XCTAssertEqual(try contents(of: downloads), ["\(stem) #1.jpg"])
        XCTAssertEqual(try Data(contentsOf: loose), Data("earlier".utf8))
    }

    /// Into a folder found for the post, flat, and a lone file there keeps
    /// its number: it is one of the post's files, not a one-file post.
    func testAFoundFolderTakesTheFilesFlatAndKeepsTheirNumbers() async throws {
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = try await run(
            saving: [folder.appendingPathComponent("\(stem) #2.jpg")], folderMode: .into(folder))

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(try contents(of: folder), ["\(stem) #2.jpg"])
        XCTAssertEqual(item.outputPath, folder.appendingPathComponent("\(stem) #2.jpg").path)
        let args = try String(contentsOf: argumentsLog, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--dest")) + 1], folder.path)
        XCTAssertFalse(args.contains { $0.hasPrefix("directory=") })
    }

    /// A file in the download folder the run did not report — another row's
    /// — is not this row's, however new.
    func testAFileTheRunDidNotReportIsNotTheRows() async throws {
        let folder = downloads.appendingPathComponent(stem, isDirectory: true)
        let other = downloads.appendingPathComponent("stranger - photo [5555555555555] #1.jpg")
        let item = try await run(
            saving: [folder.appendingPathComponent("\(stem) #1.jpg"), folder.appendingPathComponent("\(stem) #2.jpg")],
            alsoRunning: "printf 'x' > \"\(other.path)\"")

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.imageCount, 2)
        // Neither counted nor renamed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(try contents(of: downloads), [stem, other.lastPathComponent])
    }

    // MARK: - Helpers

    /// Runs a fake gallery-dl that records its arguments, saves each of
    /// `saving` (making its folder, as gallery-dl does on the first file)
    /// and reports it, then prints `saying` and exits 0.
    private func run(
        saving: [URL] = [], saying: [String] = [], alsoRunning: String = "",
        folderMode: GalleryDlService.FolderMode = .perPostIfMultiple
    ) async throws -> DownloadItem {
        var script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(argumentsLog.path)\"\n\(alsoRunning)\n"
        for file in saving {
            script += """
                mkdir -p "\(file.deletingLastPathComponent().path)"
                printf 'synthetic' > "\(file.path)"
                echo "\(file.path)"

                """
        }
        let output = root.appendingPathComponent("fake-gallery-dl.out")
        try saying.map { $0 + "\n" }.joined().write(to: output, atomically: true, encoding: .utf8)
        script += "cat \"\(output.path)\"\nexit 0\n"
        let tool = root.appendingPathComponent("fake-gallery-dl")
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let item = DownloadItem(url: link)
        await GalleryDlService.run(
            item: item, executablePath: tool.path, outputDirectory: downloads, folderMode: folderMode,
            cookieBrowser: .none, register: { _ in }, unregister: {})
        return item
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
