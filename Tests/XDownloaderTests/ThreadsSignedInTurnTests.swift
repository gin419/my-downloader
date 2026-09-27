import XCTest

@testable import XDownloader

/// The signed-in Threads requests take turns: one at a time and a pause
/// apart, whatever the concurrency setting. First the line by itself, on a
/// clock the test moves, then through DownloadManager with rows started
/// together. The links and pages are synthetic, every request is answered by
/// the URLProtocol stub, and the yt-dlp is a script that notes when it began
/// and ended; the pause is the test's own, so nothing here waits it out and
/// nothing touches the network, a browser or a cookie.
@MainActor
final class ThreadsSignedInTurnTests: XCTestCase {

    private var root: URL!
    private var downloads: URL!
    private var history: HistoryStore!
    /// "begin" and "end", one line for each, as the tool runs.
    private var toolLog: URL!
    /// The arguments of the last start, one per line.
    private var toolArguments: URL!
    /// The process the tool last ran as.
    private var toolProcessID: URL!
    private var clock: Clock!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadsSignedInTurnTests-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        history = HistoryStore(directory: root.appendingPathComponent("stores"))
        toolLog = root.appendingPathComponent("tool-log")
        toolArguments = root.appendingPathComponent("tool-arguments")
        toolProcessID = root.appendingPathComponent("tool-process")
        clock = Clock()
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The line by itself

    func testRequestsStartedTogetherRunOneAtATimeAndThePauseApart() async throws {
        let turn = makeTurn()
        var inFlight = 0
        var mostInFlight = 0
        var spans: [(began: Date, ended: Date)] = []
        var waited = 0

        let tasks = (0..<5).map { _ in
            Task {
                await turn.run(whileWaiting: { waited += 1 }) {
                    inFlight += 1
                    mostInFlight = max(mostInFlight, inFlight)
                    let began = self.clock.time
                    for _ in 0..<5 { await Task.yield() }
                    self.clock.time += 2
                    spans.append((began: began, ended: self.clock.time))
                    inFlight -= 1
                }
            }
        }
        for task in tasks { _ = await task.value }

        XCTAssertEqual(mostInFlight, 1)
        XCTAssertEqual(spans.count, 5)
        for (earlier, later) in zip(spans, spans.dropFirst()) {
            XCTAssertEqual(later.began.timeIntervalSince(earlier.ended), 3)
        }
        XCTAssertEqual(clock.pauses, [3, 3, 3, 3])
        // The first started at once; the others waited, for the line and
        // then for the pause.
        XCTAssertEqual(waited, 8)
    }

    func testFirstRequestAndOneLongAfterTheLastStartAtOnce() async throws {
        let turn = makeTurn()
        var waited = 0

        let first = await turn.run(whileWaiting: { waited += 1 }) { "first" }
        clock.time += 1
        let soonAfter = await turn.run(whileWaiting: { waited += 1 }) { "soon after" }
        clock.time += 3
        let longAfter = await turn.run(whileWaiting: { waited += 1 }) { "long after" }

        XCTAssertEqual([first, soonAfter, longAfter], ["first", "soon after", "long after"])
        // Only what was left of the pause, and only for the second.
        XCTAssertEqual(clock.pauses, [2])
        XCTAssertEqual(waited, 1)
    }

    func testCancelledWhileWaitingNeverStartsAndLetsTheNextProceed() async throws {
        let turn = makeTurn()
        let holder = Latch()
        var started: [String] = []
        let first = Task {
            await turn.run(whileWaiting: {}) {
                started.append("first")
                await holder.opened()
            }
        }
        try await waitUntil("the first holds the turn") { started == ["first"] }
        var secondWaits = false
        let second = Task {
            await turn.run(whileWaiting: { secondWaits = true }) { started.append("second") }
        }
        try await waitUntil("the second waits") { secondWaits }
        var thirdWaits = false
        let third = Task {
            await turn.run(whileWaiting: { thirdWaits = true }) { started.append("third") }
        }
        try await waitUntil("the third waits") { thirdWaits }

        second.cancel()

        // It leaves the line while the first still holds the turn.
        let left: Void? = await second.value
        XCTAssertNil(left)
        XCTAssertEqual(started, ["first"])
        holder.open()
        _ = await first.value
        let ran: Void? = await third.value
        XCTAssertNotNil(ran)
        XCTAssertEqual(started, ["first", "third"])
        XCTAssertEqual(clock.pauses, [3])
    }

    func testCancelledInThePauseNeverStartsAndLetsTheNextProceed() async throws {
        let pause = Latch()
        var pauses: [TimeInterval] = []
        let turn = ThreadsSignedInTurn(
            pause: 3, now: { self.clock.time },
            sleep: { seconds in
                pauses.append(seconds)
                // The first pause lasts until the test ends it.
                if pauses.count == 1 { await pause.opened() }
                try Task.checkCancellation()
            })
        var started: [String] = []
        await turn.run(whileWaiting: {}) { started.append("first") }
        let second = Task { await turn.run(whileWaiting: {}) { started.append("second") } }
        try await waitUntil("the second is in the pause") { pauses.count == 1 }
        let third = Task { await turn.run(whileWaiting: {}) { started.append("third") } }
        // Time for the third to reach the line.
        try await Task.sleep(nanoseconds: 50_000_000)

        second.cancel()
        clock.time += 1
        pause.open()

        let left: Void? = await second.value
        XCTAssertNil(left)
        let ran: Void? = await third.value
        XCTAssertNotNil(ran)
        XCTAssertEqual(started, ["first", "third"])
        // No request was made in between, so the third owes what is left.
        XCTAssertEqual(pauses, [3, 2])
    }

    func testTimedOutHolderHandsTheTurnOn() async throws {
        let turn = makeTurn()
        let tool = root.appendingPathComponent("tool")
        try Data("#!/bin/sh\necho begin >> \"\(toolLog.path)\"\nexec sleep 30\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let pageURL = try XCTUnwrap(URL(string: "https://www.threads.com/@synthetic.author/post/SYNturn0000"))
        var events: [String] = []

        let tasks = ["first", "second"].map { name in
            Task {
                await turn.run(whileWaiting: {}) {
                    events.append("\(name) began")
                    let outcome = await ThreadsSignedInPage.fetch(
                        pageURL, executablePath: tool.path, cookieArguments: ["--cookies-from-browser", "chrome"],
                        usedCookiesFile: false, timeout: 0.3, environment: ["PATH": "/usr/bin:/bin"],
                        register: { _ in }, unregister: {})
                    events.append("\(name) ended")
                    return outcome
                }
            }
        }
        var outcomes: [ThreadsSignedInPage.Outcome?] = []
        for task in tasks { outcomes.append(await task.value) }

        XCTAssertEqual(outcomes, [.failed(.timedOut), .failed(.timedOut)])
        XCTAssertEqual(events, ["first began", "first ended", "second began", "second ended"])
        XCTAssertEqual(try toolRuns(), ["begin", "begin"])
        XCTAssertEqual(clock.pauses, [3])
    }

    // MARK: - Through DownloadManager

    func testRestrictedRowsStartedTogetherStartTheToolOneAtATime() async throws {
        let pages = try (1...4).map { try restrictedPage($0) }
        // The tool fails every time: a holder that failed hands the turn on.
        let manager = try makeManager(tool: "sleep 0.2\necho end >> \"\(toolLog.path)\"\nexit 1\n")
        manager.maxConcurrent = 5

        let result = manager.capture(text: pages.map(\.link).joined(separator: "\n"), source: .field)

        XCTAssertEqual(result.queued, 4)
        try await waitUntil("every row has its outcome") { self.history.count() == 4 }
        XCTAssertEqual(try toolRuns(), ["begin", "end", "begin", "end", "begin", "end", "begin", "end"])
        XCTAssertEqual(clock.pauses, [3, 3, 3])
        for item in manager.items {
            XCTAssertEqual(item.status, .failed(ThreadsService.signedInNoPageMessage))
            XCTAssertFalse(item.autoRetryAttempted)
        }
        for page in pages {
            XCTAssertEqual(StubProtocol.requests(to: page.address).count, 1)
        }
    }

    func testStopAndRemoveOnWaitingRowsNeverStartTheToolAndLetTheNextProceed() async throws {
        let pages = try (1...4).map { try restrictedPage($0) }
        let manager = try makeManager(tool: "exec sleep 30\n")
        manager.maxConcurrent = 5
        let holder = try start(pages[0], in: manager)
        try await waitUntil("the tool started") { (try? self.toolRuns()) == ["begin"] }
        XCTAssertEqual(holder.status, .fetching)
        var waiting: [DownloadItem] = []
        for page in pages.dropFirst() {
            let item = try start(page, in: manager)
            try await waitUntil("the row waits for its turn") {
                StubProtocol.requests(to: page.address).count == 1 && item.status == .queued
            }
            waiting.append(item)
        }

        manager.pauseItem(waiting[0])
        manager.removeItem(waiting[1])

        try await waitUntil("the stopped row is paused", seconds: 5) { waiting[0].status == .paused }
        XCTAssertEqual(manager.items.count, 3)
        XCTAssertEqual(try toolRuns(), ["begin"])
        XCTAssertTrue(toolIsRunning())
        XCTAssertEqual(waiting[2].status, .queued)

        manager.removeItem(holder)

        // The last in line is next: the two before it gave their places up.
        try await waitUntil("the tool started again", seconds: 5) { (try? self.toolRuns()) == ["begin", "begin"] }
        XCTAssertEqual(waiting[2].status, .fetching)
        XCTAssertEqual(try lastToolArguments().last, pages[3].address.absoluteString)
        XCTAssertEqual(clock.pauses, [3])
        manager.removeItem(waiting[2])
        try await waitUntil("the tool was terminated", seconds: 5) { !self.toolIsRunning() }
        // Time for a row that wrongly kept its place to show itself.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(try toolRuns(), ["begin", "begin"])
        XCTAssertEqual(waiting[0].status, .paused)
        XCTAssertEqual(history.count(), 0)
    }

    func testPublicRowsStartedAlongsideAreNotDelayed() async throws {
        let pages = try (1...2).map { try restrictedPage($0) }
        let post = try publicPost()
        StubProtocol.set(page(post.html), for: post.address)
        StubProtocol.set(
            .init(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 3, count: 2_000)),
            for: post.media)
        let manager = try makeManager(tool: "exec sleep 30\n")
        manager.maxConcurrent = 5
        let holder = try start(pages[0], in: manager)
        try await waitUntil("the tool started") { (try? self.toolRuns()) == ["begin"] }
        let waiting = try start(pages[1], in: manager)
        try await waitUntil("the row waits for its turn") {
            StubProtocol.requests(to: pages[1].address).count == 1 && waiting.status == .queued
        }

        let item = try start(post, in: manager)

        // Far inside the tool's 30 seconds, with the turn taken and a row in
        // line for it.
        try await waitUntil("the public post is downloaded", seconds: 5) { item.status == .completed }
        XCTAssertEqual(try contents(of: downloads).count, 1)
        XCTAssertEqual(holder.status, .fetching)
        XCTAssertEqual(waiting.status, .queued)
        XCTAssertEqual(try toolRuns(), ["begin"])
        XCTAssertEqual(clock.pauses, [])

        manager.removeItem(waiting)
        manager.removeItem(holder)
        try await waitUntil("the tool was terminated", seconds: 5) { !self.toolIsRunning() }
    }

    // MARK: - Helpers

    /// The time the line reads, moved by the test and by the pauses, which
    /// pass the moment they are asked for.
    @MainActor
    private final class Clock {
        var time = Date(timeIntervalSinceReferenceDate: 0)
        private(set) var pauses: [TimeInterval] = []

        func pass(_ seconds: TimeInterval) {
            pauses.append(seconds)
            time += seconds
        }
    }

    /// Keeps a request in flight until the test opens it.
    @MainActor
    private final class Latch {
        private var isOpen = false

        func open() { isOpen = true }

        func opened() async {
            while !isOpen { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
    }

    private struct Page {
        let link: String
        let address: URL
        let html: String
        /// The post's one file; the restricted pages have none.
        var media: URL! = nil
    }

    private struct ManifestEntry: Decodable {
        struct Media: Decodable {
            let url: String
        }

        let link: String
        let fixture: String
        let expect_media: [Media]
    }

    private func makeTurn() -> ThreadsSignedInTurn {
        ThreadsSignedInTurn(
            pause: 3, now: { self.clock.time },
            sleep: { seconds in
                self.clock.pass(seconds)
                try Task.checkCancellation()
            })
    }

    private func fixtureHTML(_ name: String) throws -> (entry: ManifestEntry, html: String) {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let manifest = try JSONDecoder().decode(
            [ManifestEntry].self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        let entry = try XCTUnwrap(manifest.first { $0.fixture == name }, "no manifest entry for \(name)")
        return (entry, try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8))
    }

    /// An invented post that answers logged out as the restricted fixture
    /// does, stubbed at its own address.
    private func restrictedPage(_ number: Int) throws -> Page {
        let link = "https://www.threads.com/@synthetic.author/post/SYNturn000\(number)"
        let address = try XCTUnwrap(URL(string: link))
        let html = try fixtureHTML("threads_fail_restricted_audience.html").html
        StubProtocol.set(page(html), for: address)
        return Page(link: link, address: address, html: html)
    }

    private func publicPost() throws -> Page {
        let (entry, html) = try fixtureHTML("threads_single_image.html")
        let link = try XCTUnwrap(ThreadsService.parseLink(entry.link))
        return Page(
            link: entry.link, address: try XCTUnwrap(ThreadsService.canonicalURL(for: link)), html: html,
            media: try XCTUnwrap(URL(string: try XCTUnwrap(entry.expect_media.first).url)))
    }

    /// Queues the link and returns its row.
    private func start(_ page: Page, in manager: DownloadManager) throws -> DownloadItem {
        let known = Set(manager.items.map(\.id))
        XCTAssertEqual(manager.capture(text: page.link, source: .field).queued, 1)
        return try XCTUnwrap(manager.items.first { !known.contains($0.id) })
    }

    private func toolRuns() throws -> [String] {
        guard FileManager.default.fileExists(atPath: toolLog.path) else { return [] }
        return try String(contentsOf: toolLog, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func lastToolArguments() throws -> [String] {
        try String(contentsOf: toolArguments, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// Whether the process the tool last ran as is still there.
    private func toolIsRunning() -> Bool {
        guard let text = try? String(contentsOf: toolProcessID, encoding: .utf8),
            let id = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return kill(id, 0) == 0
    }

    /// A manager on temporary stores whose Threads requests go to the stub,
    /// whose signed-in requests stand in a line of the test's own, and whose
    /// yt-dlp notes that it began and then does what `tool` says.
    private func makeManager(tool: String) throws -> DownloadManager {
        let stores = root.appendingPathComponent("stores")
        let script = root.appendingPathComponent("yt-dlp")
        let header = """
            #!/bin/sh
            echo $$ > "\(toolProcessID.path)"
            printf '%s\\n' "$@" > "\(toolArguments.path)"
            echo begin >> "\(toolLog.path)"

            """
        try Data((header + tool).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        let manager = DownloadManager(
            history: history,
            queueStore: QueueStore(directory: stores),
            settingsStore: SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "threads-turn-\(UUID().uuidString)"))),
            likesSyncStore: LikesSyncStore(directory: stores),
            galleryDlPathProvider: { nil },
            ytDlpPathProvider: { script.path },
            threadsSession: URLSession(configuration: configuration),
            threadsSignedInTurn: makeTurn())
        manager.outputDirectory = downloads
        manager.cookieBrowser = .chrome
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(manager.saveHistoryEnabled)
        return manager
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

    private func page(_ html: String) -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
