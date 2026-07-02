import XCTest

@testable import XDownloader

final class SchemeCommandTests: XCTestCase {

    private func command(_ s: String) -> DownloadManager.SchemeCommand? {
        DownloadManager.schemeCommand(from: URL(string: s)!)
    }

    func testDownloadSingleURLIsPercentDecoded() {
        XCTAssertEqual(
            command("xdownloader://download?url=https%3A%2F%2Fx.com%2Fa%2Fstatus%2F1%3Fb%3D2"),
            .download("https://x.com/a/status/1?b=2"))
    }

    func testDownloadJoinsRepeatedURLParams() {
        XCTAssertEqual(
            command("xdownloader://download?url=https%3A%2F%2Fa.com%2F1&url=https%3A%2F%2Fb.com%2F2"),
            .download("https://a.com/1\nhttps://b.com/2"))
    }

    func testURLSParamIsAnAlias() {
        XCTAssertEqual(
            command("xdownloader://download?urls=https%3A%2F%2Fa.com%2F1%0Ahttps%3A%2F%2Fb.com%2F2"),
            .download("https://a.com/1\nhttps://b.com/2"))
    }

    func testHostlessFormWorks() {
        XCTAssertEqual(
            command("xdownloader:download?url=https%3A%2F%2Fx.com%2F1"),
            .download("https://x.com/1"))
    }

    func testNoClipboardVerbExists() {
        // Any webpage can fire a scheme URL; clipboard reads must stay tied
        // to an in-app gesture, so there deliberately is no "paste" verb.
        XCTAssertNil(command("xdownloader://paste"))
    }

    func testRejectsWrongSchemeAndUnknownVerb() {
        XCTAssertNil(command("https://download?url=https%3A%2F%2Fx.com"))
        XCTAssertNil(command("xdownloader://frobnicate"))
    }

    func testEmptyDownloadIsStillADownloadCommand() {
        // capture() answers these with the truthful "carried no link"
        // feedback — better than pretending the verb wasn't recognized.
        XCTAssertEqual(command("xdownloader://download"), .download(""))
        XCTAssertEqual(command("xdownloader://download?url="), .download(""))
    }
}
