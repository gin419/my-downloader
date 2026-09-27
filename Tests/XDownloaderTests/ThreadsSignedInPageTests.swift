import XCTest

@testable import XDownloader

/// The signed-in second try, in two halves. First the tool side: which
/// arguments yt-dlp is given, and how the page is taken out of what it
/// prints. Then the run: when the login is used, how often, and what is
/// left on the row. The tool is a shell script printing SYNTHETIC output,
/// the pages are the synthetic fixtures, and page and media requests are
/// answered by the URLProtocol stub — no network, no browser, no cookies.
@MainActor
final class ThreadsSignedInPageTests: XCTestCase {

    private var root: URL!
    private var downloads: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadsSignedInPageTests-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubProtocol.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Arguments

    func testArgumentsAreTheCookieArgumentsThenTheFixedList() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.threads.com/@example_author/post/SYNrestrict1"))
        let cookies = CookieArgs.make(browser: .firefox, profile: " Work ", file: nil)
        XCTAssertEqual(cookies, ["--cookies-from-browser", "firefox:Work"])

        let arguments = ThreadsSignedInPage.arguments(cookieArguments: cookies, pageURL: pageURL)

        XCTAssertEqual(
            arguments,
            [
                "--cookies-from-browser", "firefox:Work",
                "--ignore-config", "--no-cache-dir", "--skip-download", "--dump-pages",
                "--user-agent", ThreadsSignedInPage.userAgent,
                "https://www.threads.com/@example_author/post/SYNrestrict1",
            ])
        XCTAssertTrue(ThreadsSignedInPage.userAgent.contains("Chrome/"))
    }

    func testArgumentsNeverLogTrafficOrWriteAnything() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.threads.com/t/SYNrestrict1"))
        let sources = [
            CookieArgs.make(browser: .safari, file: nil),
            CookieArgs.make(browser: .chrome, profile: "Default", file: nil),
            CookieArgs.make(browser: .none, file: "/tmp/example/cookies.txt"),
        ]
        // Options that log the traffic, write the page, a cookie file or
        // any other file, or load more options from somewhere.
        let forbidden: Set<String> = [
            "--print-traffic", "-v", "--verbose", "--write-pages", "--dump-intermediate-pages",
            "--write-info-json", "--write-description", "--write-thumbnail", "--write-comments",
            "--load-info-json", "--config-locations", "--batch-file", "-a", "--download-archive",
            "--print-to-file", "--exec", "-o", "--output", "-P", "--paths", "--cache-dir",
        ]
        for cookies in sources {
            let arguments = ThreadsSignedInPage.arguments(cookieArguments: cookies, pageURL: pageURL)
            XCTAssertEqual(Array(arguments.prefix(cookies.count)), cookies)
            XCTAssertEqual(Set(arguments).intersection(forbidden), [], "\(arguments)")
            XCTAssertTrue(arguments.contains("--ignore-config"))
            XCTAssertTrue(arguments.contains("--no-cache-dir"))
            XCTAssertTrue(arguments.contains("--skip-download"))
            XCTAssertEqual(arguments.last, pageURL.absoluteString)
            // The only cookie option is the one the app's settings produced:
            // none that would write a new cookie file.
            XCTAssertEqual(arguments.filter { $0.hasPrefix("--cookies") }.count, 1, "\(arguments)")
        }
    }

    // MARK: - Reading the tool's output

    func testPageIsTakenFromTheLineAfterTheMarker() throws {
        let html = try fixtureHTML("threads_linked_inline_video.html")
        let lines = toolOutput(page: html, endingAt: "https://www.threads.com/@example_author/post/SYNlinked001")

        let page = try ThreadsSignedInPage.extractPage(from: lines).get()

        XCTAssertEqual(page.html, html)
        XCTAssertEqual(page.finalURL?.absoluteString, "https://www.threads.com/@example_author/post/SYNlinked001")
        guard case .success(let post) = ThreadsService.resolve(html: page.html, finalURL: page.finalURL, code: "SYNlinked001") else {
            return XCTFail("the decoded page must resolve")
        }
        XCTAssertEqual(post.source, .linkedInlineMedia)
        XCTAssertEqual(post.media.map(\.kind), [.video])
    }

    func testMessageBetweenMarkerAndPageIsSteppedOver() throws {
        // Both of the tool's outputs arrive through one handler, so one of
        // its messages can land between the marker and the page.
        let html = "<html><body>synthetic page</body></html>"
        let lines = [
            "[generic] Extracting URL: https://www.threads.com/t/SYNrestrict1",
            "[generic] Dumping request to https://www.threads.com/t/SYNrestrict1",
            "WARNING: [generic] Falling back on generic information extractor",
            Data(html.utf8).base64EncodedString(),
            "ERROR: Unsupported URL: https://www.threads.com/t/SYNrestrict1",
        ]

        XCTAssertEqual(try ThreadsSignedInPage.extractPage(from: lines).get().html, html)
    }

    func testOnlyTheFirstPageIsKept() throws {
        let first = "<html><body>first synthetic page</body></html>"
        let lines =
            toolOutput(page: first, endingAt: "https://www.threads.com/t/SYNrestrict1")
            + toolOutput(page: "<html><body>second</body></html>", endingAt: "https://www.threads.com/login/")

        let page = try ThreadsSignedInPage.extractPage(from: lines).get()

        XCTAssertEqual(page.html, first)
        XCTAssertEqual(page.finalURL?.absoluteString, "https://www.threads.com/t/SYNrestrict1")
    }

    func testMissingMarkerAndMalformedPageAreDifferentFailures() {
        // The request failed: the tool printed no page at all. A base64
        // line alone is not a page — nothing announced it.
        let noMarker = [
            "[generic] Extracting URL: https://www.threads.com/t/SYNrestrict1",
            "ERROR: [generic] Unable to download webpage: timed out",
            Data("<html></html>".utf8).base64EncodedString(),
        ]
        XCTAssertEqual(ThreadsSignedInPage.extractPage(from: noMarker), .failure(.noPage))
        XCTAssertEqual(ThreadsSignedInPage.extractPage(from: []), .failure(.noPage))
        XCTAssertEqual(
            ThreadsSignedInPage.extractPage(from: ["[generic] Dumping request to https://www.threads.com/t/SYNrestrict1"]),
            .failure(.noPage))

        let malformed = [
            "[generic] Dumping request to https://www.threads.com/t/SYNrestrict1",
            "PGh0bWw-not*base64!",
            "ERROR: Unsupported URL: https://www.threads.com/t/SYNrestrict1",
        ]
        XCTAssertEqual(ThreadsSignedInPage.extractPage(from: malformed), .failure(.undecodable))
        XCTAssertNotEqual(ThreadsSignedInPage.ExtractionFailure.noPage, .undecodable)
    }

    // MARK: - Running the tool

    func testPageLargerThanTheRealOneArrivesIntact() async throws {
        // The real page came as ONE line of 1,357,304 characters. This one
        // is longer, and it must reach the collector whole.
        let filler = String(repeating: "synthetic filler 0123456789 ", count: 60_000)
        let html = "<html><body>\(filler)<p>the end of the page</p></body></html>"
        let encoded = Data(html.utf8).base64EncodedString()
        XCTAssertGreaterThan(encoded.count, 2_000_000)
        let pageURL = try XCTUnwrap(URL(string: "https://www.threads.com/t/SYNrestrict1"))
        let tool = try makeTool(printing: html, endingAt: pageURL.absoluteString)
        var registered = 0
        var unregistered = 0

        let outcome = await ThreadsSignedInPage.fetch(
            pageURL, executablePath: tool.path, cookieArguments: ["--cookies-from-browser", "chrome"], usedCookiesFile: false,
            environment: ["PATH": "/usr/bin:/bin"],
            register: { _ in registered += 1 }, unregister: { unregistered += 1 })

        guard case .page(let page, let usedCookiesFile) = outcome else { return XCTFail("no page: \(outcome)") }
        XCTAssertEqual(page.html.utf8.count, html.utf8.count)
        XCTAssertTrue(page.html == html)
        XCTAssertEqual(page.finalURL, pageURL)
        XCTAssertFalse(usedCookiesFile)
        XCTAssertEqual(registered, 1)
        XCTAssertEqual(unregistered, 1)
    }

    func testToolExitingWithAnErrorAfterThePageIsASuccess() async throws {
        // The script ends like the real tool: "Unsupported URL", exit 1.
        let pageURL = try XCTUnwrap(URL(string: "https://www.threads.com/t/SYNrestrict1"))
        let tool = try makeTool(printing: "<html><body>synthetic page</body></html>", endingAt: pageURL.absoluteString)

        let outcome = await fetch(pageURL, tool: tool)

        XCTAssertEqual(
            outcome,
            .page(.init(html: "<html><body>synthetic page</body></html>", finalURL: pageURL), usedCookiesFile: false))
    }

    func testToolFailuresAreToldApart() async throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.threads.com/t/SYNrestrict1"))

        let silent = try makeTool(script: "echo 'ERROR: [generic] Unable to download webpage: timed out' >&2\nexit 1\n")
        let noPage = await fetch(pageURL, tool: silent)
        XCTAssertEqual(noPage, .failed(.noPage))

        let noCookies = try makeTool(script: "echo 'ERROR: could not find chrome cookies database in \"/tmp/example\"' >&2\nexit 1\n")
        let unreadable = await fetch(pageURL, tool: noCookies)
        XCTAssertEqual(unreadable, .failed(.cookiesUnreadable))

        let garbled = try makeTool(script: "echo '[generic] Dumping request to \(pageURL.absoluteString)'\necho '%%%%'\nexit 1\n")
        let undecodable = await fetch(pageURL, tool: garbled)
        XCTAssertEqual(undecodable, .failed(.undecodable))

        let missing = await fetch(pageURL, tool: root.appendingPathComponent("no-such-tool"))
        XCTAssertEqual(missing, .failed(.toolNotStarted))
    }

    func testStuckToolIsTerminatedAtTheTimeout() async throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.threads.com/t/SYNrestrict1"))
        let tool = try makeTool(script: "exec sleep 30\n")
        let started = Date()

        let outcome = await fetch(pageURL, tool: tool, timeout: 0.3)

        XCTAssertEqual(outcome, .failed(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCancelTerminatesTheTool() async throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.threads.com/t/SYNrestrict1"))
        let tool = try makeTool(script: "exec sleep 30\n")
        var process: Process?
        let started = Date()

        let task = Task { @MainActor in
            await ThreadsSignedInPage.fetch(
                pageURL, executablePath: tool.path, cookieArguments: ["--cookies-from-browser", "chrome"], usedCookiesFile: false,
                environment: ["PATH": "/usr/bin:/bin"],
                register: { process = $0 }, unregister: { process = nil })
        }
        for _ in 0..<500 where process?.isRunning != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let running = try XCTUnwrap(process)
        // What Stop does: the Task is cancelled and the registered process
        // terminated.
        task.cancel()
        running.terminate()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(running.isRunning)
        XCTAssertNil(process)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: - The run: when the login is used

    func testRestrictedLoggedOutThenSignedInDownloadsThePost() async throws {
        let post = try restrictedPost()
        StubProtocol.set(page(post.restrictedHTML), for: post.pageURL)
        StubProtocol.set(mp4(), for: post.media)
        let item = DownloadItem(url: post.link)
        var asked: [URL] = []

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession()) { url in
            asked.append(url)
            return .page(.init(html: post.signedInHTML, finalURL: url), usedCookiesFile: false)
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(asked, [post.pageURL])
        // Named as the logged-out path names it: after the media's author.
        let saved = try contents(of: downloads)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].hasPrefix("Reel Maker - "), saved[0])
        XCTAssertTrue(saved[0].hasSuffix(" [SYNreel00001].mp4"), saved[0])
        XCTAssertEqual(item.videoCount, 1)
        XCTAssertFalse(item.emptySuccessFailure)
        // The logged-out page once; the media without cookies or headers.
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
        let mediaRequests = StubProtocol.requests(to: post.media)
        XCTAssertEqual(mediaRequests.count, 1)
        XCTAssertEqual(mediaRequests.first?.allHTTPHeaderFields ?? [:], [:])
        XCTAssertEqual(mediaRequests.first?.httpShouldHandleCookies, false)
    }

    func testRestrictedBothTimesAsksForTheThreadsSignIn() async throws {
        let post = try restrictedPost()
        StubProtocol.set(page(post.restrictedHTML), for: post.pageURL)
        let item = DownloadItem(url: post.link)
        item.emptySuccessFailure = true
        var asked = 0

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession()) { url in
            asked += 1
            return .page(.init(html: post.restrictedHTML, finalURL: url), usedCookiesFile: false)
        }

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(ThreadsService.signInMissingInBrowserMessage))
        XCTAssertFalse(item.emptySuccessFailure)
        XCTAssertFalse(DownloadManager.shouldAutoRetryEmptySuccess(item))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
        XCTAssertEqual(try contents(of: downloads), [])
    }

    func testLoginPageBothTimesAsksForTheThreadsSignIn() async throws {
        let post = try restrictedPost()
        let loginHTML = try fixtureHTML("threads_fail_login_redirect.html")
        let landing = try XCTUnwrap(URL(string: "https://www.threads.com/login/?next=https%3A%2F%2Fwww.threads.com%2F"))
        StubProtocol.set(.redirect(to: landing), for: post.pageURL)
        StubProtocol.set(page(loginHTML), for: landing)
        let item = DownloadItem(url: post.link)
        var asked = 0

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession()) { _ in
            asked += 1
            return .page(.init(html: loginHTML, finalURL: landing), usedCookiesFile: true)
        }

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(ThreadsService.signInMissingInCookiesFileMessage))
        XCTAssertFalse(item.emptySuccessFailure)
        XCTAssertEqual(asked, 1)
    }

    func testPublicPostNeverUsesTheLogin() async throws {
        let html = try fixtureHTML("threads_linked_inline_video.html")
        let post = try restrictedPost()
        StubProtocol.set(page(html), for: post.pageURL)
        StubProtocol.set(mp4(), for: post.media)
        let item = DownloadItem(url: post.link)
        var asked = 0

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession()) { _ in
            asked += 1
            return .cancelled
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(asked, 0)
    }

    func testFailuresALoginCannotChangeNeverUseIt() async throws {
        XCTAssertEqual(Set(ThreadsService.Failure.allCases.filter(ThreadsService.needsSignIn)), [.restricted, .loginRequired])
        let cases: [(fixture: String, message: String)] = [
            ("threads_fail_blocked_shell_404.html", ThreadsService.blockedShellMessage),
            ("threads_text_only.html", ThreadsService.noMediaMessage),
        ]
        for entry in cases {
            let failing = try fixture(entry.fixture)
            StubProtocol.set(page(failing.html), for: failing.pageURL)
            let item = DownloadItem(url: failing.link)
            var asked = 0

            let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession()) { _ in
                asked += 1
                return .cancelled
            }

            XCTAssertFalse(finished, entry.fixture)
            XCTAssertEqual(item.status, .failed(entry.message), entry.fixture)
            XCTAssertEqual(asked, 0, entry.fixture)
        }

        // The request itself failing is no reason either.
        let post = try restrictedPost()
        StubProtocol.set(.init(status: 429, headers: [:], body: Data()), for: post.pageURL)
        let item = DownloadItem(url: post.link)
        var asked = 0
        _ = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession()) { _ in
            asked += 1
            return .cancelled
        }
        XCTAssertEqual(asked, 0)
    }

    func testRefusedMediaAfterTheSignedInPageIsNotASecondSignedInRequest() async throws {
        let post = try restrictedPost()
        StubProtocol.set(page(post.restrictedHTML), for: post.pageURL)
        StubProtocol.set(.init(status: 403, headers: [:], body: Data("refused".utf8)), for: post.media)
        let item = DownloadItem(url: post.link)
        var asked = 0

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession()) { url in
            asked += 1
            return .page(.init(html: post.signedInHTML, finalURL: url), usedCookiesFile: false)
        }

        XCTAssertFalse(finished)
        XCTAssertEqual(
            item.status,
            .failed("None of this post's files could be saved — the server returned HTTP 403. Retry fetches them again."))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1)
        XCTAssertEqual(StubProtocol.requests(to: post.media).count, 1)
        XCTAssertFalse(item.emptySuccessFailure)
    }

    func testEveryEndOfTheSignedInTryLeavesItsOwnMessageAndNoAutoRetry() async throws {
        let post = try restrictedPost()
        let cases: [(outcome: ThreadsSignedInPage.Outcome, message: String)] = [
            (.noCookieSource, ThreadsService.restrictedMessage),
            (.toolMissing, ThreadsService.signedInToolMissingMessage),
            (.failed(.toolNotStarted), ThreadsService.signedInToolNotStartedMessage),
            (.failed(.cookiesUnreadable), YtDlpService.cookieDatabaseMessage),
            (.failed(.timedOut), ThreadsService.signedInTimedOutMessage),
            (.failed(.noPage), ThreadsService.signedInNoPageMessage),
            (.failed(.undecodable), ThreadsService.signedInUndecodableMessage),
            // Signed in, the page came without the post: logged out that
            // answer is retried automatically, here it must not be.
            (
                .page(.init(html: "<html><body>initialRouteInfo</body></html>", finalURL: post.pageURL), usedCookiesFile: false),
                ThreadsService.noPostDataMessage
            ),
            (
                .page(
                    .init(html: "<html></html>", finalURL: URL(string: "https://www.threads.com/?error=invalid_post")),
                    usedCookiesFile: false),
                ThreadsService.notFoundMessage
            ),
        ]
        for entry in cases {
            StubProtocol.removeAll()
            StubProtocol.set(page(post.restrictedHTML), for: post.pageURL)
            let item = DownloadItem(url: post.link)
            item.emptySuccessFailure = true
            var asked = 0

            let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession()) { _ in
                asked += 1
                return entry.outcome
            }

            XCTAssertFalse(finished, entry.message)
            XCTAssertEqual(item.status, .failed(entry.message))
            XCTAssertFalse(item.emptySuccessFailure, entry.message)
            XCTAssertFalse(DownloadManager.shouldAutoRetryEmptySuccess(item), entry.message)
            XCTAssertEqual(asked, 1, entry.message)
            XCTAssertEqual(StubProtocol.requests(to: post.pageURL).count, 1, entry.message)
        }
        XCTAssertEqual(try contents(of: downloads), [])
    }

    func testWithoutASignedInTryTheLoggedOutMessageStands() async throws {
        let post = try restrictedPost()
        StubProtocol.set(page(post.restrictedHTML), for: post.pageURL)
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession())

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .failed(ThreadsService.restrictedMessage))
        XCTAssertFalse(item.emptySuccessFailure)
    }

    func testStopDuringTheSignedInTryClaimsNoOutcome() async throws {
        let post = try restrictedPost()
        StubProtocol.set(page(post.restrictedHTML), for: post.pageURL)
        let item = DownloadItem(url: post.link)

        let finished = await ThreadsService.run(item: item, outputDirectory: downloads, session: stubSession()) { _ in .cancelled }

        XCTAssertFalse(finished)
        XCTAssertEqual(item.status, .fetching)
        XCTAssertFalse(item.emptySuccessFailure)
        XCTAssertEqual(try contents(of: downloads), [])
    }

    // MARK: - Messages

    func testSignedInMessagesAreTheLiteralCopy() {
        XCTAssertEqual(
            ThreadsService.signInMissingInBrowserMessage,
            "Threads still hides this post — sign in at threads.com in the browser selected in Settings → Cookies "
                + "(an Instagram sign-in alone is not enough), then Retry.")
        XCTAssertEqual(
            ThreadsService.signInMissingInCookiesFileMessage,
            "Threads still hides this post — the cookies.txt chosen in Settings → Cookies has no Threads sign-in. "
                + "Clear it to use your browser, or export it again after signing in at threads.com "
                + "(an Instagram sign-in alone is not enough), then Retry.")
        XCTAssertEqual(
            ThreadsService.signedInToolMissingMessage,
            "Threads only shows this post to signed-in visitors — reading it with your sign-in needs yt-dlp, which is not installed. "
                + "Install yt-dlp, then Retry.")
        XCTAssertEqual(
            ThreadsService.signedInToolNotStartedMessage,
            "Threads only shows this post to signed-in visitors — yt-dlp, which reads it with your sign-in, couldn't be started. "
                + "Reinstall yt-dlp, then Retry.")
        XCTAssertEqual(
            ThreadsService.signedInTimedOutMessage,
            "Couldn't load the post from Threads with your sign-in — no answer in time. Check the connection, then Retry.")
        XCTAssertEqual(
            ThreadsService.signedInNoPageMessage,
            "Couldn't load the post from Threads with your sign-in — check the connection, then Retry.")
        XCTAssertEqual(
            ThreadsService.signedInUndecodableMessage,
            "Couldn't read the page yt-dlp returned for this Threads post — update yt-dlp, then Retry.")
    }

    func testSignInMessagesNameThreadsAndNoParticularBrowser() {
        let messages = [
            ThreadsService.restrictedMessage, ThreadsService.loginRequiredMessage,
            ThreadsService.signInMissingInBrowserMessage, ThreadsService.signInMissingInCookiesFileMessage,
        ]
        for message in messages {
            XCTAssertTrue(message.contains("threads.com"), message)
            XCTAssertTrue(message.contains("an Instagram sign-in alone is not enough"), message)
            XCTAssertTrue(message.contains("Settings → Cookies"), message)
            for browser in CookieBrowser.allCases where browser != .none {
                XCTAssertFalse(message.contains(browser.displayName), message)
            }
        }
        let all = ThreadsSignedInPage.FetchFailure.allCases.map(ThreadsService.message(for:))
        XCTAssertEqual(Set(all).count, ThreadsSignedInPage.FetchFailure.allCases.count)
    }

    // MARK: - Helpers

    private struct RestrictedPost {
        let link: String
        let pageURL: URL
        /// What Threads answers logged out.
        let restrictedHTML: String
        /// What it answers signed in: a text post with the video inline.
        let signedInHTML: String
        let media: URL
    }

    private struct FixturePage {
        let link: String
        let pageURL: URL
        let html: String
    }

    private struct ManifestEntry: Decodable {
        struct Media: Decodable {
            let url: String
        }

        let link: String
        let fixture: String
        let expect_media: [Media]
    }

    private func fixtureFile(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent(name)
    }

    private func fixtureHTML(_ name: String) throws -> String {
        try String(contentsOf: fixtureFile(name), encoding: .utf8)
    }

    private func manifestEntry(_ name: String) throws -> ManifestEntry {
        let manifest = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: fixtureFile("manifest.json")))
        return try XCTUnwrap(manifest.first { $0.fixture == name }, "no manifest entry for \(name)")
    }

    private func fixture(_ name: String) throws -> FixturePage {
        let entry = try manifestEntry(name)
        let link = try XCTUnwrap(ThreadsService.parseLink(entry.link))
        return FixturePage(
            link: entry.link, pageURL: try XCTUnwrap(ThreadsService.canonicalURL(for: link)), html: try fixtureHTML(name))
    }

    /// One post seen twice: restricted logged out, whole signed in.
    private func restrictedPost() throws -> RestrictedPost {
        let entry = try manifestEntry("threads_linked_inline_video.html")
        let link = try XCTUnwrap(ThreadsService.parseLink(entry.link))
        return RestrictedPost(
            link: entry.link,
            pageURL: try XCTUnwrap(ThreadsService.canonicalURL(for: link)),
            restrictedHTML: try fixtureHTML("threads_fail_restricted_audience.html"),
            signedInHTML: try fixtureHTML("threads_linked_inline_video.html"),
            media: try XCTUnwrap(URL(string: try XCTUnwrap(entry.expect_media.first).url)))
    }

    /// Lines shaped like the tool's for one page request.
    private func toolOutput(page html: String, endingAt address: String) -> [String] {
        [
            "[generic] Extracting URL: \(address)",
            "[generic] SYNTHETIC: Downloading webpage",
            "[generic] Dumping request to \(address)",
            Data(html.utf8).base64EncodedString(),
            "WARNING: [generic] Falling back on generic information extractor",
            "ERROR: Unsupported URL: \(address)",
        ]
    }

    /// A stand-in for the tool that prints `html` the way the tool prints a
    /// page, then fails with "Unsupported URL" like the tool does.
    private func makeTool(printing html: String, endingAt address: String) throws -> URL {
        let encoded = root.appendingPathComponent("page-\(UUID().uuidString).b64")
        try Data(html.utf8).base64EncodedData().write(to: encoded)
        return try makeTool(
            script: """
                echo '[generic] Extracting URL: \(address)'
                echo '[generic] Dumping request to \(address)'
                cat "\(encoded.path)"
                echo
                echo 'ERROR: Unsupported URL: \(address)' >&2
                exit 1

                """)
    }

    private func makeTool(script: String) throws -> URL {
        let tool = root.appendingPathComponent("tool-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private func fetch(_ pageURL: URL, tool: URL, timeout: TimeInterval = 20) async -> ThreadsSignedInPage.Outcome {
        await ThreadsSignedInPage.fetch(
            pageURL, executablePath: tool.path, cookieArguments: ["--cookies-from-browser", "chrome"], usedCookiesFile: false,
            timeout: timeout, environment: ["PATH": "/usr/bin:/bin"],
            register: { _ in }, unregister: {})
    }

    private func page(_ html: String) -> StubProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    private func mp4() -> StubProtocol.Stub {
        .init(
            status: 200, headers: ["Content-Type": "video/mp4"],
            body: Data([0x00, 0x00, 0x00, 0x20]) + Data("ftypisom".utf8) + Data(repeating: 9, count: 200_000))
    }

    private func stubSession() -> URLSession {
        let configuration = DirectDownload.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
