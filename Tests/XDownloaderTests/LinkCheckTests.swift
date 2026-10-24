import XCTest

@testable import XDownloader

final class LinkCheckTests: XCTestCase {

    // MARK: - The list

    func testListParsesArrayWithDefaults() throws {
        let json = """
            [
              {"url": "https://example.com/a", "label": "A", "expect": {"minFiles": 3, "kinds": ["image"]}},
              {"url": "https://example.com/b"},
              {"url": "https://example.com/c", "expect": {"kinds": ["video"], "stopEarly": true}}
            ]
            """
        let entries = try LinkCheck.parseList(Data(json.utf8))
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].expect, LinkCheck.Expectation(minFiles: 3, kinds: [.image]))
        XCTAssertEqual(entries[0].displayName, "A")
        XCTAssertEqual(entries[1].expect, LinkCheck.Expectation())
        XCTAssertEqual(entries[1].displayName, "https://example.com/b")
        XCTAssertEqual(entries[2].expect, LinkCheck.Expectation(minFiles: 1, kinds: [.video], stopEarly: true))
    }

    func testListParsesWrappedForm() throws {
        let json = #"{"note": "anything", "links": [{"url": "https://example.com/a"}]}"#
        XCTAssertEqual(try LinkCheck.parseList(Data(json.utf8)).map(\.url), ["https://example.com/a"])
    }

    func testListRejectsEmptyNonWebAndZeroFiles() {
        XCTAssertThrowsError(try LinkCheck.parseList(Data("[]".utf8)))
        XCTAssertThrowsError(try LinkCheck.parseList(Data("not json".utf8)))
        XCTAssertThrowsError(try LinkCheck.parseList(Data(#"[{"url": "file:///etc/hosts"}]"#.utf8)))
        XCTAssertThrowsError(
            try LinkCheck.parseList(Data(#"[{"url": "https://example.com", "expect": {"minFiles": 0}}]"#.utf8)))
        XCTAssertThrowsError(try LinkCheck.parseList(Data(#"[{"url": "https://x", "expect": {"kinds": ["pdf"]}}]"#.utf8)))
    }

    // MARK: - Command line

    func testCommandIsNilForNormalLaunch() {
        XCTAssertNil(LinkCheck.command(from: ["/Applications/XDownloader.app/Contents/MacOS/XDownloader"]))
        XCTAssertNil(LinkCheck.command(from: ["XDownloader", "--check-links"]))
    }

    func testCommandReadsListReportAndTimeout() {
        let command = LinkCheck.command(from: [
            "XDownloader", "--check-links", "~/list.json", "--report", "/tmp/r.json", "--timeout", "60",
        ])
        XCTAssertEqual(command, LinkCheck.Command(listPath: "~/list.json", reportPath: "/tmp/r.json", timeout: 60))
        let bare = LinkCheck.command(from: ["XDownloader", "--check-links", "l.json", "--timeout", "nope"])
        XCTAssertEqual(bare, LinkCheck.Command(listPath: "l.json", reportPath: nil, timeout: LinkCheck.defaultTimeout))
    }

    // MARK: - Files on disk

    func testFilesCountsFinishedMediaAtAnyDepth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkcheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Post [1]")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.jpg", "Post [1]/b.PNG", "Post [1]/c.mp4", "d.mp4.part", "e.f137.mp4", "f.en.vtt", ".hidden.jpg", "g.m4a"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let files = LinkCheck.files(in: root)
        XCTAssertEqual(files.names, ["Post [1]/b.PNG", "Post [1]/c.mp4", "a.jpg", "g.m4a"])
        XCTAssertEqual(files.count(of: .image), 2)
        XCTAssertEqual(files.count(of: .video), 1)
        XCTAssertEqual(files.count(of: .audio), 1)
    }

    func testUnmergedStreamNames() {
        XCTAssertTrue(LinkCheck.isUnmergedStream("clip.f137.mp4"))
        XCTAssertTrue(LinkCheck.isUnmergedStream("clip.f251.webm"))
        XCTAssertFalse(LinkCheck.isUnmergedStream("clip.mp4"))
        XCTAssertFalse(LinkCheck.isUnmergedStream("final.cut.mp4"))
        XCTAssertFalse(LinkCheck.isUnmergedStream("photo.f.jpg"))
    }

    // MARK: - Grading

    private func files(_ kinds: [LinkCheck.Kind]) -> LinkCheck.Files {
        LinkCheck.Files(names: kinds.enumerated().map { "f\($0.offset)" }, kinds: kinds)
    }

    func testCompletedWithEnoughFilesPasses() {
        let entry = LinkCheck.Entry(url: "https://e/x", expect: .init(minFiles: 2, kinds: [.image]))
        let result = LinkCheck.grade(entry, outcome: .completed, files: files([.image, .image]), seconds: 3.14)
        XCTAssertTrue(result.passed)
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.gotKinds, ["image": 2])
        XCTAssertEqual(result.seconds, 3.1)
    }

    func testCompletedWithTooFewFilesFails() {
        let entry = LinkCheck.Entry(url: "https://e/x", expect: .init(minFiles: 16))
        let result = LinkCheck.grade(entry, outcome: .completed, files: files([.image]), seconds: 1)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.problem, "expected at least 16 file(s), got 1")
    }

    func testMissingKindFails() {
        let entry = LinkCheck.Entry(url: "https://e/x", expect: .init(minFiles: 1, kinds: [.video]))
        let result = LinkCheck.grade(entry, outcome: .completed, files: files([.image, .image]), seconds: 1)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.problem, "no video among the files")
    }

    func testFailedRowFailsEvenWithFilesAndKeepsMessage() {
        let entry = LinkCheck.Entry(url: "https://e/x")
        let result = LinkCheck.grade(
            entry, outcome: .failed("No media found"), files: files([.image]), seconds: 1, diagnosticRecord: "/d/r")
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.rowMessage, "No media found")
        XCTAssertEqual(result.diagnosticRecord, "/d/r")
    }

    func testTimeoutAndNotQueuedFail() {
        let entry = LinkCheck.Entry(url: "https://e/x")
        XCTAssertFalse(LinkCheck.grade(entry, outcome: .timedOut, files: files([.video]), seconds: 1).passed)
        XCTAssertFalse(LinkCheck.grade(entry, outcome: .notQueued("no"), files: files([]), seconds: 1).passed)
    }

    func testStoppedEarlyPassesWhenMet() {
        let entry = LinkCheck.Entry(url: "https://e/x", expect: .init(minFiles: 1, kinds: [.video], stopEarly: true))
        XCTAssertTrue(LinkCheck.meets(entry.expect, files([.video])))
        XCTAssertFalse(LinkCheck.meets(entry.expect, files([.image])))
        XCTAssertTrue(LinkCheck.grade(entry, outcome: .stoppedEarly, files: files([.video]), seconds: 1).passed)
    }

    func testTableEndsWithSummary() {
        let entry = LinkCheck.Entry(url: "https://e/x", label: "X picture")
        let pass = LinkCheck.grade(entry, outcome: .completed, files: files([.image]), seconds: 2)
        let fail = LinkCheck.grade(entry, outcome: .timedOut, files: files([]), seconds: 2)
        let table = LinkCheck.table([pass, fail]).components(separatedBy: "\n")
        XCTAssertTrue(table[0].hasPrefix("PASS  X picture"))
        XCTAssertTrue(table[1].hasPrefix("FAIL  X picture"))
        XCTAssertEqual(table.last, "SUMMARY passed=1 failed=1 total=2")
    }
}
