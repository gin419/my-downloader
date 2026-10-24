import Foundation

/// What one row's run did, kept so that a failure can be explained from a
/// file instead of by reproducing it: the pages and API answers the app
/// fetched itself, the tool runs it started, and the steps it went through.
///
/// One trail lives for one run of one row (`DiagnosticTrail.current`, a
/// task-local set around the run, so every request and process inside the
/// run finds it without being handed it). It is written out only when the
/// run ends failed (`DiagnosticsStore`).
///
/// Nothing of the user's login is ever kept: request and response headers
/// pass through `DiagnosticRedaction`, tool arguments and output too, and
/// a body fetched with the user's login is not kept at all.
final class DiagnosticTrail: @unchecked Sendable {
    @TaskLocal static var current: DiagnosticTrail?

    /// One request the app made itself.
    struct Exchange: Codable, Equatable {
        var label: String
        var method: String
        var requestURL: String
        var requestHeaders: [String: String]
        var finalURL: String?
        var status: Int?
        var responseHeaders: [String: String]
        var error: String?
        var bodyBytes: Int
        /// The body as received, cut at `DiagnosticTrail.bodyCap`. Nil when
        /// the request failed before a body, or the body may hold the login.
        var body: Data?
        var bodyTruncated: Bool
        var startedAt: Date
        var seconds: Double
    }

    /// One external tool run (yt-dlp, gallery-dl).
    struct ToolRun: Codable, Equatable {
        var tool: String
        var executable: String
        var arguments: [String]
        var exitCode: Int32?
        var wasSignal: Bool
        /// The run's last output lines, newest last, cut at `outputCap`.
        var outputTail: String
        var outputTruncated: Bool
        var startedAt: Date
        var seconds: Double?
    }

    static let bodyCap = 5 * 1024 * 1024
    static let outputCap = 1024 * 1024
    /// Kept per trail: an automatic retry runs the whole chain again, and
    /// both attempts are worth having, but nothing should grow unbounded.
    static let maxExchanges = 16
    static let maxToolRuns = 8
    static let maxSteps = 64

    private let lock = NSLock()
    private var _exchanges: [Exchange] = []
    private var _toolRuns: [ToolRun] = []
    private var _steps: [String] = []
    private var _written = false

    var exchanges: [Exchange] { lock.withLock { _exchanges } }
    var toolRuns: [ToolRun] { lock.withLock { _toolRuns } }
    var steps: [String] { lock.withLock { _steps } }

    /// A step of the run ("yt-dlp", "fallback: galleryDl", …). The last one
    /// names where the run was when it failed.
    func step(_ name: String) {
        lock.withLock {
            _steps.append(name)
            if _steps.count > Self.maxSteps { _steps.removeFirst(_steps.count - Self.maxSteps) }
        }
    }

    func record(_ exchange: Exchange) {
        lock.withLock {
            _exchanges.append(exchange)
            if _exchanges.count > Self.maxExchanges { _exchanges.removeFirst(_exchanges.count - Self.maxExchanges) }
        }
    }

    /// Starts a tool run and returns its index, for `appendOutput` and `endToolRun`.
    func beginToolRun(executable: String, arguments: [String]) -> Int {
        let run = ToolRun(
            tool: URL(fileURLWithPath: executable).lastPathComponent, executable: executable,
            arguments: DiagnosticRedaction.arguments(arguments), exitCode: nil, wasSignal: false,
            outputTail: "", outputTruncated: false, startedAt: Date(), seconds: nil)
        return lock.withLock {
            _toolRuns.append(run)
            if _toolRuns.count > Self.maxToolRuns { _toolRuns.removeFirst(_toolRuns.count - Self.maxToolRuns) }
            return _toolRuns.count - 1
        }
    }

    func appendOutput(_ line: String, toRun index: Int) {
        let clean = DiagnosticRedaction.text(line)
        lock.withLock {
            guard _toolRuns.indices.contains(index) else { return }
            var tail = _toolRuns[index].outputTail
            tail += clean + "\n"
            if tail.utf8.count > Self.outputCap {
                tail = String(decoding: Array(tail.utf8).suffix(Self.outputCap), as: UTF8.self)
                _toolRuns[index].outputTruncated = true
            }
            _toolRuns[index].outputTail = tail
        }
    }

    func endToolRun(_ index: Int, exitCode: Int32, wasSignal: Bool) {
        lock.withLock {
            guard _toolRuns.indices.contains(index) else { return }
            _toolRuns[index].exitCode = exitCode
            _toolRuns[index].wasSignal = wasSignal
            _toolRuns[index].seconds = Date().timeIntervalSince(_toolRuns[index].startedAt)
        }
    }

    /// True the first time only: a run that ends failed is written once,
    /// however many places settle it.
    func claimWrite() -> Bool {
        lock.withLock {
            if _written { return false }
            _written = true
            return true
        }
    }

    /// A request made by the app itself, recorded into the current trail
    /// (when there is one) whatever its outcome. `bodyMayHoldLogin` keeps a
    /// body fetched with the user's login out of the record.
    static func data(
        for request: URLRequest, session: URLSession, label: String,
        delegate: (any URLSessionTaskDelegate)? = nil, bodyMayHoldLogin: Bool = false
    ) async throws -> (Data, URLResponse) {
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            current?.record(
                exchange(
                    label: label, request: request, response: response, data: data, error: nil, started: started,
                    keepBody: !bodyMayHoldLogin))
            return (data, response)
        } catch {
            current?.record(
                exchange(
                    label: label, request: request, response: nil, data: nil, error: error, started: started,
                    keepBody: false))
            throw error
        }
    }

    static func exchange(
        label: String, request: URLRequest, response: URLResponse?, data: Data?, error: Error?, started: Date,
        keepBody: Bool
    ) -> Exchange {
        let http = response as? HTTPURLResponse
        var responseHeaders: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            responseHeaders[String(describing: key)] = String(describing: value)
        }
        let body = keepBody ? data.map { $0.prefix(bodyCap) } : nil
        return Exchange(
            label: label,
            method: request.httpMethod ?? "GET",
            requestURL: request.url.map { DiagnosticRedaction.url($0.absoluteString) } ?? "",
            requestHeaders: DiagnosticRedaction.headers(request.allHTTPHeaderFields ?? [:]),
            finalURL: response?.url.map { DiagnosticRedaction.url($0.absoluteString) },
            status: http?.statusCode,
            responseHeaders: DiagnosticRedaction.headers(responseHeaders),
            error: error.map { String(describing: $0) },
            bodyBytes: data?.count ?? 0,
            body: body.map { Data($0) },
            bodyTruncated: keepBody && (data?.count ?? 0) > bodyCap,
            startedAt: started,
            seconds: Date().timeIntervalSince(started))
    }
}

/// Removes everything of the user's login from what a record keeps.
enum DiagnosticRedaction {
    static let redacted = "<redacted>"

    /// Header names whose value is never kept.
    static func isSecretHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["cookie", "set-cookie", "authorization", "proxy-authorization"].contains(lower)
            || lower.contains("token") || lower.contains("csrf") || lower.contains("auth")
            || lower.contains("session") || lower.contains("api-key") || lower.contains("apikey")
    }

    static func headers(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in headers { out[name] = isSecretHeader(name) ? redacted : value }
        return out
    }

    /// Option names whose following argument is never kept as given.
    static let secretValueOptions: Set<String> = [
        "--password", "-p", "--video-password", "--ap-password", "--twofactor", "-2", "--netrc-cmd",
        "--username", "-u", "--ap-username",
    ]

    /// Tool arguments with every secret masked. A cookies file is named by
    /// its path, which is kept; its contents never reach an argument.
    static func arguments(_ arguments: [String]) -> [String] {
        var out: [String] = []
        var maskNext = false
        var headerNext = false
        for argument in arguments {
            if maskNext {
                out.append(redacted)
                maskNext = false
                continue
            }
            if headerNext {
                out.append(headerArgument(argument))
                headerNext = false
                continue
            }
            if secretValueOptions.contains(argument) {
                out.append(argument)
                maskNext = true
                continue
            }
            if argument == "--add-header" || argument == "--add-headers" || argument == "-H" {
                out.append(argument)
                headerNext = true
                continue
            }
            if let equals = argument.firstIndex(of: "="), argument.hasPrefix("--") {
                let name = String(argument[..<equals])
                if secretValueOptions.contains(name) {
                    out.append("\(name)=\(redacted)")
                    continue
                }
                if name == "--add-header" || name == "--add-headers" {
                    out.append("\(name)=\(headerArgument(String(argument[argument.index(after: equals)...])))")
                    continue
                }
            }
            out.append(text(argument))
        }
        return out
    }

    /// "Name: value" / "Name:value" with a secret name keeps only the name.
    private static func headerArgument(_ argument: String) -> String {
        guard let colon = argument.firstIndex(of: ":") else { return text(argument) }
        let name = argument[..<colon].trimmingCharacters(in: .whitespaces)
        return isSecretHeader(name) ? "\(name): \(redacted)" : text(argument)
    }

    private static let headerLine = try! NSRegularExpression(
        pattern: #"(?i)\b((?:set-)?cookie|(?:proxy-)?authorization|x-csrf-token|x-guest-token|x-ig-www-claim|x-fb-lsd)(\s*[:=]\s*)[^\r\n]*"#)
    private static let secretPair = try! NSRegularExpression(
        pattern:
            #"(?i)\b(auth_token|ct0|twid|kdt|sessionid|csrftoken|ds_user_id|rur|fb_dtsg|lsd|access_token|refresh_token|refresh-token|id_token|token|api_key|apikey|password|passwd|PHPSESSID|SID|HSID|SSID|APISID|SAPISID|LOGIN_INFO|__Secure-[A-Za-z0-9_-]+)(["']?\s*[=:]\s*["']?)([^;&\s"',}]+)"#
    )
    private static let bearer = try! NSRegularExpression(pattern: #"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=%-]+"#)

    /// Free text (a tool's output line, an argument) with secret values masked.
    static func text(_ text: String) -> String {
        var s = text
        var range = NSRange(s.startIndex..., in: s)
        s = headerLine.stringByReplacingMatches(in: s, range: range, withTemplate: "$1$2\(redacted)")
        range = NSRange(s.startIndex..., in: s)
        s = secretPair.stringByReplacingMatches(in: s, range: range, withTemplate: "$1$2\(redacted)")
        range = NSRange(s.startIndex..., in: s)
        s = bearer.stringByReplacingMatches(in: s, range: range, withTemplate: "$1 \(redacted)")
        return s
    }

    /// A URL with secret query values masked.
    static func url(_ url: String) -> String { text(url) }
}

/// Writes a failed run's record under Application Support/XDownloader/
/// diagnostics, one folder per failure, and keeps the folder small: the
/// newest `maxRecords`, nothing older than `maxAge`. Writing happens off
/// the main actor and never throws: a record is a help, never a reason for
/// a download to fail or wait.
struct DiagnosticsStore {
    struct Record: Codable {
        var appVersion: String
        var appBuild: String
        var writtenAt: Date
        var url: String
        var siteID: String
        var failedStep: String?
        var steps: [String]
        var message: String
        var tools: [String: String]
        var exchanges: [ExchangeSummary]
        var toolRuns: [DiagnosticTrail.ToolRun]
    }

    /// An exchange as `record.json` lists it: the body lives in its own file.
    struct ExchangeSummary: Codable {
        var label: String
        var method: String
        var requestURL: String
        var requestHeaders: [String: String]
        var finalURL: String?
        var status: Int?
        var responseHeaders: [String: String]
        var error: String?
        var bodyBytes: Int
        var bodyFile: String?
        var bodyTruncated: Bool
        var startedAt: Date
        var seconds: Double
    }

    static let maxRecords = 100
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// Nil: records are not written (tests that do not ask for them).
    let directory: URL?

    /// The app's store; disabled under XCTest so no test writes into the
    /// user's Application Support.
    static let live: DiagnosticsStore = {
        if NSClassFromString("XCTestCase") != nil { return DiagnosticsStore(directory: nil) }
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return DiagnosticsStore(
            directory: base.appendingPathComponent("XDownloader", isDirectory: true)
                .appendingPathComponent("diagnostics", isDirectory: true))
    }()

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    /// The record of a failed run, from what the trail kept.
    static func makeRecord(
        url: String, siteID: String, message: String, tools: [String: String], trail: DiagnosticTrail,
        now: Date = Date()
    ) -> (record: Record, bodies: [String: Data]) {
        var bodies: [String: Data] = [:]
        let summaries = trail.exchanges.enumerated().map { index, exchange -> ExchangeSummary in
            var file: String?
            if let body = exchange.body {
                let name = String(format: "body-%02d-%@.%@", index + 1, safeName(exchange.label), bodyExtension(exchange))
                bodies[name] = body
                file = name
            }
            return ExchangeSummary(
                label: exchange.label, method: exchange.method, requestURL: exchange.requestURL,
                requestHeaders: exchange.requestHeaders, finalURL: exchange.finalURL, status: exchange.status,
                responseHeaders: exchange.responseHeaders, error: exchange.error, bodyBytes: exchange.bodyBytes,
                bodyFile: file, bodyTruncated: exchange.bodyTruncated, startedAt: exchange.startedAt,
                seconds: exchange.seconds)
        }
        let steps = trail.steps
        let record = Record(
            appVersion: appVersion, appBuild: appBuild, writtenAt: now, url: DiagnosticRedaction.url(url),
            siteID: siteID, failedStep: steps.last, steps: steps, message: message, tools: tools,
            exchanges: summaries, toolRuns: trail.toolRuns)
        return (record, bodies)
    }

    /// Writes the record, then prunes. Returns the record's folder, nil when
    /// disabled or when writing failed.
    @discardableResult
    func write(_ record: Record, bodies: [String: Data], id: String, now: Date = Date()) -> URL? {
        guard let directory else { return nil }
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(formatter.string(from: now))-\(Self.safeName(record.siteID))-\(Self.safeName(String(id.prefix(8))))"
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: folder.appendingPathComponent("record.json"), options: .atomic)
            for (file, data) in bodies {
                try? data.write(to: folder.appendingPathComponent(file), options: .atomic)
            }
        } catch {
            try? fm.removeItem(at: folder)
            return nil
        }
        prune(now: now)
        return folder
    }

    /// Keeps the newest `maxRecords` folders and drops any older than `maxAge`.
    func prune(now: Date = Date()) {
        guard let directory else { return }
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return }
        let folders =
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { url -> (URL, Date) in
                (url, (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }
            // Names start with the time written; ties broken by creation date.
            .sorted { ($0.0.lastPathComponent, $0.1) > ($1.0.lastPathComponent, $1.1) }
        for (index, entry) in folders.enumerated()
        where index >= Self.maxRecords || now.timeIntervalSince(entry.1) > Self.maxAge {
            try? fm.removeItem(at: entry.0)
        }
    }

    static func safeName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? $0 : "-" }))
        return cleaned.isEmpty ? "x" : String(cleaned.prefix(40))
    }

    private static func bodyExtension(_ exchange: DiagnosticTrail.Exchange) -> String {
        let type = (exchange.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value ?? "").lowercased()
        if type.contains("json") { return "json" }
        if type.contains("html") { return "html" }
        if type.contains("xml") { return "xml" }
        return "txt"
    }
}
