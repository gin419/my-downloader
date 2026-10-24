import AppKit
import Foundation

/// The link check: the app downloads a list of known links with its own code
/// and network path, compares what landed on disk with what each link should
/// give, and writes a report. Run before a release and nightly, so a site
/// change or a regression shows up before the user meets it.
///
///     XDownloader --check-links <list.json> --report <report.json> [--timeout <seconds>]
///
/// It runs without a window and never touches the user's queue, history,
/// Likes data or download folder: every store points into a scratch folder
/// that is deleted at the end. Failed links leave the usual diagnostic record.
enum LinkCheck {

    // MARK: - The list

    enum Kind: String, Codable, CaseIterable {
        case video, image, audio
    }

    struct Expectation: Codable, Equatable {
        /// Media files the link must leave on disk.
        var minFiles: Int
        /// Kinds that must each appear among those files (none: any kind).
        var kinds: [Kind]
        /// Stop the download as soon as `minFiles` files of the expected
        /// kinds are on disk, and pass — for pages of many large videos,
        /// where one finished file already proves the path works.
        var stopEarly: Bool

        init(minFiles: Int = 1, kinds: [Kind] = [], stopEarly: Bool = false) {
            self.minFiles = minFiles
            self.kinds = kinds
            self.stopEarly = stopEarly
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            minFiles = try c.decodeIfPresent(Int.self, forKey: .minFiles) ?? 1
            kinds = try c.decodeIfPresent([Kind].self, forKey: .kinds) ?? []
            stopEarly = try c.decodeIfPresent(Bool.self, forKey: .stopEarly) ?? false
        }
    }

    struct Entry: Codable, Equatable {
        var url: String
        var label: String?
        var expect: Expectation

        init(url: String, label: String? = nil, expect: Expectation = Expectation()) {
            self.url = url
            self.label = label
            self.expect = expect
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            expect = try c.decodeIfPresent(Expectation.self, forKey: .expect) ?? Expectation()
        }

        var displayName: String { label ?? url }
    }

    enum ListError: Error, CustomStringConvertible {
        case unreadable(String)
        case empty
        case badEntry(Int, String)

        var description: String {
            switch self {
            case .unreadable(let why): return "The link list could not be read: \(why)"
            case .empty: return "The link list has no links."
            case .badEntry(let index, let why): return "Link \(index + 1) in the list is not usable: \(why)"
            }
        }
    }

    /// A list is a JSON array of entries, or an object with a `links` array
    /// (room for comments or settings beside it).
    static func parseList(_ data: Data) throws -> [Entry] {
        struct Wrapped: Decodable { let links: [Entry] }
        let entries: [Entry]
        do {
            if let array = try? JSONDecoder().decode([Entry].self, from: data) {
                entries = array
            } else {
                entries = try JSONDecoder().decode(Wrapped.self, from: data).links
            }
        } catch {
            throw ListError.unreadable(String(describing: error))
        }
        guard !entries.isEmpty else { throw ListError.empty }
        for (index, entry) in entries.enumerated() {
            guard let url = URL(string: entry.url.trimmingCharacters(in: .whitespaces)),
                let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
            else { throw ListError.badEntry(index, "\"\(entry.url)\" is not a web link") }
            guard entry.expect.minFiles >= 1 else { throw ListError.badEntry(index, "minFiles must be at least 1") }
        }
        return entries
    }

    // MARK: - What landed on disk

    struct Files: Equatable {
        var names: [String] = []
        var kinds: [Kind] = []

        var count: Int { names.count }
        func count(of kind: Kind) -> Int { kinds.filter { $0 == kind }.count }
    }

    static func kind(ofExtension ext: String) -> Kind? {
        let ext = ext.lowercased()
        if MediaExtensions.video.contains(ext) { return .video }
        if MediaExtensions.image.contains(ext) { return .image }
        if MediaExtensions.audio.contains(ext) { return .audio }
        return nil
    }

    /// Finished media files under `directory`, at any depth. Partial
    /// downloads (".part", ".ytdl", "*.f137.mp4"-style unmerged streams) and
    /// hidden files are left out; subtitles and metadata are not media.
    static func files(in directory: URL) -> Files {
        var result = Files()
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return result }
        // Both sides resolved: the temporary folder is reached through the
        // /var → /private/var link, and the enumerator may report either.
        let base = directory.resolvingSymlinksInPath().path + "/"
        var found: [(String, Kind)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                let kind = kind(ofExtension: url.pathExtension),
                !isUnmergedStream(url.lastPathComponent)
            else { continue }
            let path = url.resolvingSymlinksInPath().path
            found.append((path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent, kind))
        }
        found.sort { $0.0 < $1.0 }
        result.names = found.map(\.0)
        result.kinds = found.map(\.1)
        return result
    }

    /// yt-dlp's separate video/audio streams before merging: "name.f137.mp4".
    static func isUnmergedStream(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        let last = (stem as NSString).pathExtension
        return last.count >= 2 && last.first == "f" && last.dropFirst().allSatisfy(\.isNumber)
    }

    /// True once `files` meets the entry's count and kinds.
    static func meets(_ expect: Expectation, _ files: Files) -> Bool {
        files.count >= expect.minFiles && expect.kinds.allSatisfy { files.count(of: $0) > 0 }
    }

    // MARK: - Grading

    enum Outcome: Equatable {
        case completed
        case failed(String)
        case timedOut
        case stoppedEarly
        case notQueued(String)
    }

    struct Result: Codable, Equatable {
        var url: String
        var label: String?
        var passed: Bool
        var status: String
        var problem: String?
        var rowMessage: String?
        var expectedMinFiles: Int
        var expectedKinds: [Kind]
        var gotFiles: Int
        var gotKinds: [String: Int]
        var fileNames: [String]
        var seconds: Double
        var diagnosticRecord: String?
    }

    static func grade(
        _ entry: Entry, outcome: Outcome, files: Files, seconds: Double, diagnosticRecord: String? = nil
    ) -> Result {
        var gotKinds: [String: Int] = [:]
        for kind in files.kinds { gotKinds[kind.rawValue, default: 0] += 1 }
        var problem: String?
        var rowMessage: String?
        let status: String
        switch outcome {
        case .completed:
            status = "completed"
        case .stoppedEarly:
            status = "stopped early"
        case .failed(let message):
            status = "failed"
            rowMessage = message
            problem = "the download failed: \(message)"
        case .timedOut:
            status = "timed out"
            problem = "the download did not finish in time"
        case .notQueued(let why):
            status = "not queued"
            problem = why
        }
        if problem == nil {
            let missing = entry.expect.kinds.filter { files.count(of: $0) == 0 }
            if files.count < entry.expect.minFiles {
                problem = "expected at least \(entry.expect.minFiles) file(s), got \(files.count)"
            } else if !missing.isEmpty {
                problem = "no \(missing.map(\.rawValue).joined(separator: " or ")) among the files"
            }
        }
        return Result(
            url: entry.url, label: entry.label, passed: problem == nil, status: status, problem: problem,
            rowMessage: rowMessage, expectedMinFiles: entry.expect.minFiles, expectedKinds: entry.expect.kinds,
            gotFiles: files.count, gotKinds: gotKinds, fileNames: files.names, seconds: (seconds * 10).rounded() / 10,
            diagnosticRecord: diagnosticRecord)
    }

    struct Report: Codable {
        var appVersion: String
        var appBuild: String
        var startedAt: Date
        var finishedAt: Date
        var total: Int
        var passed: Int
        var failed: Int
        var results: [Result]
    }

    /// The short table printed to the terminal.
    static func table(_ results: [Result]) -> String {
        var lines: [String] = []
        for result in results {
            let mark = result.passed ? "PASS" : "FAIL"
            let name = String((result.label ?? result.url).prefix(44))
            let padded = name.padding(toLength: 44, withPad: " ", startingAt: 0)
            let detail = result.passed ? "\(result.gotFiles) file(s), \(result.seconds)s" : (result.problem ?? "")
            lines.append("\(mark)  \(padded)  \(detail)")
        }
        let passed = results.filter(\.passed).count
        lines.append("SUMMARY passed=\(passed) failed=\(results.count - passed) total=\(results.count)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Command line

    struct Command: Equatable {
        var listPath: String
        var reportPath: String?
        var timeout: TimeInterval
    }

    static let defaultTimeout: TimeInterval = 180

    /// The check's arguments, or nil when the app was not launched for a check.
    static func command(from arguments: [String]) -> Command? {
        guard let index = arguments.firstIndex(of: "--check-links"), index + 1 < arguments.count else { return nil }
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let timeout = value("--timeout").flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil } ?? defaultTimeout
        return Command(listPath: arguments[index + 1], reportPath: value("--report"), timeout: timeout)
    }

    /// Runs the check with no window and exits with 0 (all passed), 1 (some
    /// failed) or 2 (the check itself could not run). Never returns.
    @MainActor
    static func runHeadless(_ command: Command) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await LinkCheckRunner.run(command)
            exit(code)
        }
        app.run()
        exit(2)
    }
}

/// Drives a private `DownloadManager` through the list, one link at a time.
@MainActor
enum LinkCheckRunner {
    /// The app's own settings domain, read whatever bundle runs the check.
    static let settingsDomain = "com.gin.xdownloader"

    static func run(_ command: LinkCheck.Command) async -> Int32 {
        let entries: [LinkCheck.Entry]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: (command.listPath as NSString).expandingTildeInPath))
            entries = try LinkCheck.parseList(data)
        } catch {
            printError("\(error)")
            return 2
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(
            "xdownloader-linkcheck-\(UUID().uuidString)", isDirectory: true)
        // One fixed settings domain, emptied at both ends of every run: the
        // system may write its (empty) file back after removal, and a fixed
        // name keeps that to a single file instead of one per run.
        let suiteName = "\(settingsDomain).linkcheck"
        guard (try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil,
            let defaults = UserDefaults(suiteName: suiteName)
        else {
            printError("Could not create the check's scratch folder.")
            return 2
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            try? fm.removeItem(at: scratch)
            defaults.removePersistentDomain(forName: suiteName)
        }
        // The user's settings (browser for cookies, formats, …), copied so
        // nothing the manager saves can reach the real ones.
        for (key, value) in UserDefaults.standard.persistentDomain(forName: settingsDomain) ?? [:] {
            defaults.set(value, forKey: key)
        }
        NotificationService.isMuted = true

        let stores = scratch.appendingPathComponent("stores", isDirectory: true)
        let manager = DownloadManager(
            history: HistoryStore(directory: stores),
            queueStore: QueueStore(directory: stores),
            settingsStore: SettingsStore(defaults: defaults),
            likesSyncStore: LikesSyncStore(directory: stores))
        manager.maxConcurrent = 1

        let startedAt = Date()
        var results: [LinkCheck.Result] = []
        for (index, entry) in entries.enumerated() {
            let folder = scratch.appendingPathComponent(String(format: "%02d", index + 1), isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let result = await check(entry, in: folder, manager: manager, timeout: command.timeout)
            results.append(result)
            print(LinkCheck.table([result]).components(separatedBy: "\n").first ?? "")
            fflush(stdout)
        }

        let passed = results.filter(\.passed).count
        let report = LinkCheck.Report(
            appVersion: DiagnosticsStore.appVersion, appBuild: DiagnosticsStore.appBuild, startedAt: startedAt,
            finishedAt: Date(), total: results.count, passed: passed, failed: results.count - passed, results: results)
        if let path = command.reportPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try encoder.encode(report).write(to: url, options: .atomic)
            } catch {
                printError("Could not write the report: \(error)")
            }
        }
        print("SUMMARY passed=\(passed) failed=\(results.count - passed) total=\(results.count)")
        fflush(stdout)
        return passed == results.count ? 0 : 1
    }

    private static func check(
        _ entry: LinkCheck.Entry, in folder: URL, manager: DownloadManager, timeout: TimeInterval
    ) async -> LinkCheck.Result {
        let start = Date()
        manager.outputDirectory = folder
        let before = Set(manager.items.map(\.id))
        manager.capture(text: entry.url, source: .file)
        guard let item = manager.items.first(where: { !before.contains($0.id) }) else {
            return LinkCheck.grade(
                entry, outcome: .notQueued("the app did not queue the link"), files: LinkCheck.files(in: folder),
                seconds: Date().timeIntervalSince(start))
        }

        var outcome: LinkCheck.Outcome?
        while outcome == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if manager.hasFinishedRun(item) {
                if case .failed(let message) = item.status {
                    outcome = .failed(message)
                } else {
                    outcome = .completed
                }
            } else if entry.expect.stopEarly, LinkCheck.meets(entry.expect, LinkCheck.files(in: folder)) {
                outcome = .stoppedEarly
            } else if Date().timeIntervalSince(start) > timeout {
                outcome = .timedOut
            }
        }
        let seconds = Date().timeIntervalSince(start)
        var record: String?
        if case .failed = outcome {
            record = await diagnosticRecord(for: item)
        }
        let files = LinkCheck.files(in: folder)
        manager.removeItem(item)
        return LinkCheck.grade(entry, outcome: outcome ?? .timedOut, files: files, seconds: seconds, diagnosticRecord: record)
    }

    /// The record the failed run left, found by the row's id in its folder
    /// name. It is written off the main actor, so give it a moment.
    private static func diagnosticRecord(for item: DownloadItem) async -> String? {
        guard let directory = DiagnosticsStore.live.directory else { return nil }
        let suffix = "-" + DiagnosticsStore.safeName(String(item.id.uuidString.prefix(8)))
        for _ in 0..<10 {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if let name = names.sorted().last(where: { $0.hasSuffix(suffix) }) {
                return directory.appendingPathComponent(name).path
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("link check: \(message)\n".utf8))
    }
}
