import XCTest

@testable import XDownloader

/// The rules of a row's own folder: when there is one, what a tool may be
/// handed, which folder on disk is a post's, and that only an empty folder
/// the run itself made is ever removed. Everything happens in a temporary
/// folder of the test's own.
@MainActor
final class RowFolderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RowFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The folder and its name

    func testTwoOrMoreFilesGetAFolderAndOneStaysLoose() {
        XCTAssertNil(RowFolder.folder(in: root, name: "a - b [1]", fileCount: 0))
        XCTAssertNil(RowFolder.folder(in: root, name: "a - b [1]", fileCount: 1))
        XCTAssertEqual(RowFolder.folder(in: root, name: "a - b [1]", fileCount: 2)?.path, root.appendingPathComponent("a - b [1]").path)
        XCTAssertEqual(RowFolder.folder(in: root, name: "a - b [1]", fileCount: 12)?.lastPathComponent, "a - b [1]")
    }

    func testAppNamedMapsOnlyTheDollarSign() {
        XCTAssertEqual(RowFolder.appNamed("Sale $HOME ${USER} 5$ [x]"), "Sale ＄HOME ＄{USER} 5＄ [x]")
        // Nothing else changes: "%" is escaped where a template is built.
        XCTAssertEqual(RowFolder.appNamed("50% off – «ok» [x]"), "50% off – «ok» [x]")
    }

    func testIsToolSafeRejectsADollarSign() {
        XCTAssertTrue(RowFolder.isToolSafe("/downloads/a - b [123]"))
        XCTAssertTrue(RowFolder.isToolSafe("/downloads/50% ＄ off [123]"))
        XCTAssertFalse(RowFolder.isToolSafe("/downloads/a $HOME b [123]"))
        XCTAssertFalse(RowFolder.isToolSafe("/downloads/5$ [123]"))
    }

    func testTemplateDirectoryDoublesThePercentSign() {
        XCTAssertEqual(RowFolder.templateDirectory(URL(fileURLWithPath: "/out/50% off [x]")), "/out/50%% off [x]")
        XCTAssertEqual(RowFolder.templateDirectory(URL(fileURLWithPath: "/out/%(title)s")), "/out/%%(title)s")
        // A path without one comes out as it went in.
        XCTAssertEqual(RowFolder.templateDirectory(URL(fileURLWithPath: "/out/a - b [x]")), "/out/a - b [x]")
    }

    func testNormalizedCollapsesDoubledSeparators() {
        XCTAssertEqual(RowFolder.normalized("/out//a - b.mp4"), "/out/a - b.mp4")
        XCTAssertEqual(RowFolder.normalized("/out///a.mp4"), "/out/a.mp4")
        XCTAssertEqual(RowFolder.normalized("/out/a [1]/a #1.jpg"), "/out/a [1]/a #1.jpg")
    }

    /// A single video's step back out of a post's found folder is recorded
    /// as the loose file it reaches, whatever the folder's name holds.
    func testNormalizedUndoesTheStepBackOutOfAFoundFolder() {
        XCTAssertEqual(RowFolder.normalized("/out/a: b? [1]/../a - b.mp4"), "/out/a - b.mp4")
        XCTAssertEqual(RowFolder.normalized("/out/50% off [1]/..//a.mp4"), "/out/a.mp4")
        // A list's files in the found folder keep it.
        XCTAssertEqual(RowFolder.normalized("/out/a: b? [1]//a - b [01].mp4"), "/out/a: b? [1]/a - b [01].mp4")
        // Only a whole ".." segment steps back; dots in a name are the name.
        XCTAssertEqual(RowFolder.normalized("/out/a.. [1]/..b.mp4"), "/out/a.. [1]/..b.mp4")
    }

    func testIsSymbolicLinkTellsALinkFromAFolder() throws {
        let folder = try makeFolder("a - b [123]")
        let link = root.appendingPathComponent("linked [123]")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertFalse(RowFolder.isSymbolicLink(folder))
        XCTAssertTrue(RowFolder.isSymbolicLink(link))
        XCTAssertFalse(RowFolder.isSymbolicLink(root.appendingPathComponent("missing [123]")))
    }

    // MARK: - A post's folder on disk

    func testExistingFindsTheFolderEndingInTheID() throws {
        let folder = try makeFolder("a - b [123]")
        XCTAssertEqual(RowFolder.existing(in: root, id: "123")?.path, folder.path)
    }

    func testExistingIgnoresFilesAndOtherNames() throws {
        // A file with the suffix is no post folder.
        try Data("x".utf8).write(to: root.appendingPathComponent("loose [123]"))
        // A longer id that ends in the same digits, a suffix that is not
        // the end of the name, and a folder that has no id at all.
        try makeFolder("c - d [1234]")
        try makeFolder("e - f [123] x")
        try makeFolder("Twitter Likes")
        try makeFolder("g - h [0123]")

        XCTAssertNil(RowFolder.existing(in: root, id: "123"))
        XCTAssertNil(RowFolder.existing(in: root, id: ""))
        XCTAssertNil(RowFolder.existing(in: root.appendingPathComponent("not there"), id: "123"))
        XCTAssertEqual(RowFolder.existing(in: root, id: "1234")?.lastPathComponent, "c - d [1234]")
    }

    // MARK: - Removing an empty folder

    func testAnEmptyFolderThisRunMadeIsRemoved() throws {
        let folder = try makeFolder("a - b [1]")
        XCTAssertTrue(RowFolder.removeIfEmpty(folder, createdThisRun: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testFindersOwnFileAloneCountsAsEmpty() throws {
        let folder = try makeFolder("a - b [1]")
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        XCTAssertTrue(RowFolder.removeIfEmpty(folder, createdThisRun: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testAFolderWithAFileIsNeverRemoved() throws {
        let folder = try makeFolder("a - b [1]")
        let file = folder.appendingPathComponent("a - b [1] #1.jpg")
        try Data("picture".utf8).write(to: file)
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))

        XCTAssertFalse(RowFolder.removeIfEmpty(folder, createdThisRun: true))
        XCTAssertEqual(try Data(contentsOf: file), Data("picture".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".DS_Store").path))

        // A hidden file of anyone else's is content too.
        let other = try makeFolder("c - d [2]")
        try Data().write(to: other.appendingPathComponent(".hidden"))
        XCTAssertFalse(RowFolder.removeIfEmpty(other, createdThisRun: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent(".hidden").path))
    }

    func testAFolderThatWasThereBeforeTheRunIsNeverRemoved() throws {
        let folder = try makeFolder("a - b [1]")
        XCTAssertFalse(RowFolder.removeIfEmpty(folder, createdThisRun: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testAFolderThatIsNotThereIsLeftAlone() {
        XCTAssertFalse(RowFolder.removeIfEmpty(root.appendingPathComponent("never made"), createdThisRun: true))
    }

    // MARK: - The row's note

    func testUseNotesWhetherTheFolderWasThereAndKeepsTheFirstNote() throws {
        let item = DownloadItem(url: "https://www.threads.com/@someone.invented/post/AbCdEfGhIjK")
        let folder = root.appendingPathComponent("a - b [1]", isDirectory: true)

        RowFolder.use(folder, for: item)
        XCTAssertEqual(item.destination, folder)
        XCTAssertFalse(item.destinationExistedAtStart)

        // The run made it; set again within the run, the note stands, so
        // the run may still remove it when it ends empty.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        RowFolder.use(folder, for: item)
        XCTAssertFalse(item.destinationExistedAtStart)

        // The next run starts from nothing and finds the folder there.
        RowFolder.use(nil, for: item)
        XCTAssertNil(item.destination)
        XCTAssertFalse(item.destinationExistedAtStart)
        RowFolder.use(folder, for: item)
        XCTAssertTrue(item.destinationExistedAtStart)
    }

    func testResetForReattemptKeepsTheFolder() {
        let item = DownloadItem(url: "https://x.com/someone/status/123")
        let folder = root.appendingPathComponent("a - b [123]", isDirectory: true)
        RowFolder.use(folder, for: item)

        item.resetForReattempt()

        XCTAssertEqual(item.destination, folder)
    }

    // MARK: - A post's id

    func testPostIDIsTheTweetIDOrThePostCode() {
        XCTAssertEqual(RowFolder.postID(of: "https://x.com/someone/status/1234567890123"), "1234567890123")
        XCTAssertEqual(RowFolder.postID(of: "https://twitter.com/someone/status/1234567890123?s=20"), "1234567890123")
        XCTAssertEqual(RowFolder.postID(of: "https://www.instagram.com/p/SYNpost0001_/"), "SYNpost0001_")
        XCTAssertEqual(RowFolder.postID(of: "https://www.instagram.com/reel/SYNreel0001_/"), "SYNreel0001_")
        // No id to find a folder by.
        XCTAssertNil(RowFolder.postID(of: "https://x.com/someone"))
        XCTAssertNil(RowFolder.postID(of: "https://www.instagram.com/share/SYNshare01/"))
        XCTAssertNil(RowFolder.postID(of: "https://www.instagram.com/someone.invented/"))
        XCTAssertNil(RowFolder.postID(of: "https://www.youtube.com/watch?v=abcdefghijk"))
        XCTAssertNil(RowFolder.postID(of: "https://www.reddit.com/r/invented/comments/abc123/x/"))
    }

    /// A YouTube list's folder is found by the "list=" its link carries, as
    /// a post's is by its id; a list with no id in its link is not.
    func testFolderIDIsThePostsIDOrAYouTubeListsID() {
        XCTAssertEqual(RowFolder.folderID(of: "https://x.com/someone/status/1234567890123"), "1234567890123")
        XCTAssertEqual(RowFolder.folderID(of: "https://www.instagram.com/p/SYNpost0001_/"), "SYNpost0001_")
        XCTAssertEqual(RowFolder.folderID(of: "https://www.youtube.com/playlist?list=PLsynthetic-List_01"), "PLsynthetic-List_01")
        XCTAssertEqual(
            RowFolder.folderID(of: "https://www.youtube.com/watch?v=abcdefghijk&list=PLsynthetic01&index=2"), "PLsynthetic01")
        XCTAssertEqual(RowFolder.folderID(of: "https://youtu.be/abcdefghijk?list=PLsynthetic01"), "PLsynthetic01")
        // No list, or none an id could be: nothing to find a folder by.
        XCTAssertNil(RowFolder.folderID(of: "https://www.youtube.com/watch?v=abcdefghijk"))
        XCTAssertNil(RowFolder.folderID(of: "https://www.youtube.com/@someone/videos"))
        XCTAssertNil(RowFolder.folderID(of: "https://www.youtube.com/playlist?list="))
        XCTAssertNil(RowFolder.folderID(of: "https://www.youtube.com/playlist?list=PL%20x%5D"))
        XCTAssertNil(RowFolder.folderID(of: "https://www.youtube.com/playlist?list=" + String(repeating: "a", count: 65)))
        // "list=" means a YouTube list only on YouTube.
        XCTAssertNil(RowFolder.folderID(of: "https://example.com/page?list=PLsynthetic01"))
    }

    // MARK: - The one move

    func testMoveInMovesTheFileUnderItsOwnName() throws {
        let folder = try makeFolder("a - b [123]")
        let file = root.appendingPathComponent("a - b.mp4")
        try Data("video".utf8).write(to: file)

        let moved = try XCTUnwrap(RowFolder.moveIn(file, to: folder))

        XCTAssertEqual(moved.path, folder.appendingPathComponent("a - b.mp4").path)
        XCTAssertEqual(try Data(contentsOf: moved), Data("video".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMoveInNeverReplacesAFileAndLeavesTheOriginalWhereItWas() throws {
        let folder = try makeFolder("a - b [123]")
        let taken = folder.appendingPathComponent("a - b.mp4")
        try Data("already there".utf8).write(to: taken)
        let file = root.appendingPathComponent("a - b.mp4")
        try Data("video".utf8).write(to: file)

        XCTAssertNil(RowFolder.moveIn(file, to: folder))

        XCTAssertEqual(try Data(contentsOf: taken), Data("already there".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("video".utf8))
    }

    func testMoveInMakesNoFolder() throws {
        let file = root.appendingPathComponent("a - b.mp4")
        try Data("video".utf8).write(to: file)
        let missing = root.appendingPathComponent("a - b [123]", isDirectory: true)

        XCTAssertNil(RowFolder.moveIn(file, to: missing))

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Helpers

    @discardableResult
    private func makeFolder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
