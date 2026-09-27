import Foundation

/// The signed-in second try for a Threads post that Threads withholds from
/// logged-out visitors. yt-dlp — the tool the app already hands the browser
/// login to — requests the post's page with that login and prints the page;
/// the app takes the page from the tool's output, in memory. No cookie file
/// is written and the app never holds a cookie value: yt-dlp reads the
/// browser's cookies in its own process, as it does for every other download.
///
/// One run is one request. Nothing here repeats it.
enum ThreadsSignedInPage {

    /// A page handed back by the tool. `finalURL` is the address the request
    /// ended at, which is what tells the login page from the post's.
    struct Page: Equatable {
        let html: String
        let finalURL: URL?
    }

    /// Why the tool's output held no usable page.
    enum ExtractionFailure: Error, Equatable {
        /// The tool never announced a page: the request itself failed.
        case noPage
        /// A page was announced, but what followed was not one.
        case undecodable
    }

    enum Outcome: Equatable {
        /// `usedCookiesFile` is true when the login came from the
        /// cookies.txt chosen in Settings instead of the browser.
        case page(Page, usedCookiesFile: Bool)
        /// Settings name no browser and no cookies.txt: nothing was started.
        case noCookieSource
        /// yt-dlp is not installed: nothing was started.
        case toolMissing
        case failed(FetchFailure)
        /// Stop, or the row's ✕: the tool was terminated.
        case cancelled
    }

    enum FetchFailure: Equatable, CaseIterable {
        case toolNotStarted
        case cookiesUnreadable
        case timedOut
        case noPage
        case undecodable
    }

    // MARK: - Arguments

    /// What the tool introduces itself as. Its own default is refused by
    /// Threads the way URLSession's is.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    /// The app's own cookie arguments, then: no user configuration (it could
    /// add logging or output options), no cache, no download, and the page
    /// printed to the tool's output. Never an option that logs the traffic
    /// or writes the page to a file — both would put the login on disk.
    static func arguments(cookieArguments: [String], pageURL: URL) -> [String] {
        cookieArguments
            + [
                "--ignore-config",
                "--no-cache-dir",
                "--skip-download",
                "--dump-pages",
                "--user-agent", userAgent,
                pageURL.absoluteString,
            ]
    }

    // MARK: - Reading the tool's output

    /// The line announcing a page reads "[generic] Dumping request to
    /// <address>"; the name in brackets is the extractor's and not ours to
    /// rely on.
    static let pageMarker = "] Dumping request to "

    /// Takes the tool's lines as they arrive and keeps the first page among
    /// them, encoded as it came. Everything else is dropped on the spot:
    /// nothing of the tool's output is kept, shown or logged.
    struct Collector {
        private var sawMarker = false
        private var finalURL: URL?
        private var encoded: String?
        private(set) var cookiesUnreadable = false

        mutating func take(_ line: String) {
            if encoded == nil {
                // The page is the line after the marker on the tool's
                // standard output. Both outputs arrive through one handler,
                // so a warning may land in between: a message has spaces, a
                // base64 line has none.
                if sawMarker, !line.contains(" ") {
                    encoded = line
                    return
                }
                if !sawMarker, let marker = line.range(of: pageMarker) {
                    sawMarker = true
                    finalURL = URL(string: line[marker.upperBound...].trimmingCharacters(in: .whitespaces))
                    return
                }
            }
            guard line.hasPrefix("ERROR:") else { return }
            let lower = line.lowercased()
            if lower.contains("could not find"), lower.contains("cookies database") { cookiesUnreadable = true }
        }

        /// Decodes the page. The tool exits with an error even when it has
        /// printed the page — it has no extractor for Threads and says
        /// "Unsupported URL" — so the page, not the exit code, is the result.
        func page() -> Result<Page, ExtractionFailure> {
            guard sawMarker, let encoded else { return .failure(.noPage) }
            guard let data = Data(base64Encoded: encoded), !data.isEmpty else { return .failure(.undecodable) }
            return .success(Page(html: String(decoding: data, as: UTF8.self), finalURL: finalURL))
        }
    }

    /// The page in a finished run's output lines.
    static func extractPage(from lines: [String]) -> Result<Page, ExtractionFailure> {
        var collector = Collector()
        for line in lines { collector.take(line) }
        return collector.page()
    }

    // MARK: - Running the tool

    /// The tool gives up on a connection after 20 seconds by itself, and
    /// reading the browser's cookies comes before that; past this it is
    /// stuck, and the row must not be.
    static let timeout: TimeInterval = 90

    /// State of one run, touched on the main actor only.
    @MainActor
    private final class Run {
        var collector = Collector()
        var process: Process?
        var timedOut = false
    }

    /// One request for `pageURL` with the login `cookieArguments` name.
    /// `register` and `unregister` are DownloadManager's process registry:
    /// that is where Stop and the row's ✕ find the tool to terminate. The
    /// line handler is this function's own and never touches a row.
    @MainActor
    static func fetch(
        _ pageURL: URL,
        executablePath: String,
        cookieArguments: [String],
        usedCookiesFile: Bool,
        timeout: TimeInterval = ThreadsSignedInPage.timeout,
        environment: [String: String]? = nil,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void
    ) async -> Outcome {
        let run = Run()
        let watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let process = run.process, process.isRunning else { return }
            run.timedOut = true
            process.terminate()
        }
        let result = await ProcessRunner.runStreaming(
            executablePath: executablePath,
            arguments: arguments(cookieArguments: cookieArguments, pageURL: pageURL),
            environment: environment,
            register: { process in
                run.process = process
                register(process)
            },
            unregister: {
                run.process = nil
                unregister()
            },
            onLine: { line in run.collector.take(line) })
        watchdog.cancel()

        if Task.isCancelled { return .cancelled }
        if run.timedOut { return .failed(.timedOut) }
        if result.code == -1, !result.wasSignal { return .failed(.toolNotStarted) }
        switch run.collector.page() {
        case .success(let page):
            return .page(page, usedCookiesFile: usedCookiesFile)
        case .failure(.undecodable):
            return .failed(.undecodable)
        case .failure(.noPage):
            return .failed(run.collector.cookiesUnreadable ? .cookiesUnreadable : .noPage)
        }
    }
}
