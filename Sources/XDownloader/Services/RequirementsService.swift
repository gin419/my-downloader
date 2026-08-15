import Foundation

struct ToolRequirement: Identifiable {
    let id: String  // stable, used as dict key
    let name: String
    let brewPackage: String
    let docsURL: String
    let searchPaths: [String]

    /// Resolved through the ONE shared resolver — the requirements banner and
    /// the launch paths in DownloadManager must never disagree about where a
    /// tool lives.
    var installedPath: String? {
        RequirementsService.resolvedPath(for: self)
    }
    var isInstalled: Bool { installedPath != nil }
}

/// Per-tool health as probed. Existence alone is not health: the origin
/// incident was a 2024 yt-dlp that passed the existence-only check for months
/// while every YouTube download failed with misleading errors.
/// `outdated` carries the installed version string for display; `detail` is a
/// humanized age ("21 months old") when it is derivable from the version
/// (yt-dlp's CalVer), nil otherwise (SEMVER tools flagged by brew).
enum ToolStatus: Equatable {
    case missing
    case outdated(installed: String, detail: String?)
    case ok(version: String)
}

/// One tool's identity + probed status, the unit the banner and the install
/// sheet render. Value type so views can diff it cheaply.
struct ToolHealth: Identifiable, Equatable {
    let id: String
    let name: String
    let brewPackage: String
    let docsURL: String
    let path: String?
    let status: ToolStatus
}

enum RequirementsService {

    // MARK: - Tool catalogue

    static let ytdlp: ToolRequirement = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ToolRequirement(
            id: "yt-dlp",
            name: "yt-dlp",
            brewPackage: "yt-dlp",
            docsURL: "https://github.com/yt-dlp/yt-dlp#installation",
            searchPaths: [
                "/opt/homebrew/bin/yt-dlp",
                "/usr/local/bin/yt-dlp",
                "/usr/bin/yt-dlp",
                "\(home)/.local/bin/yt-dlp",
                "/opt/local/bin/yt-dlp",
            ]
        )
    }()

    static let galleryDl: ToolRequirement = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ToolRequirement(
            id: "gallery-dl",
            name: "gallery-dl",
            brewPackage: "gallery-dl",
            docsURL: "https://github.com/mikf/gallery-dl#installation",
            searchPaths: [
                "/opt/homebrew/bin/gallery-dl",
                "/usr/local/bin/gallery-dl",
                "\(home)/Library/Python/3.9/bin/gallery-dl",
                "\(home)/Library/Python/3.10/bin/gallery-dl",
                "\(home)/Library/Python/3.11/bin/gallery-dl",
                "\(home)/Library/Python/3.12/bin/gallery-dl",
                "\(home)/Library/Python/3.13/bin/gallery-dl",
                "\(home)/.local/bin/gallery-dl",
                "/opt/local/bin/gallery-dl",
            ]
        )
    }()

    static let ffmpeg: ToolRequirement = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ToolRequirement(
            id: "ffmpeg",
            name: "ffmpeg",
            brewPackage: "ffmpeg",
            docsURL: "https://ffmpeg.org/download.html",
            searchPaths: [
                "/opt/homebrew/bin/ffmpeg",
                "/usr/local/bin/ffmpeg",
                "/usr/bin/ffmpeg",
                "\(home)/.local/bin/ffmpeg",
                "/opt/local/bin/ffmpeg",
            ]
        )
    }()

    /// yt-dlp's JavaScript runtime for YouTube (it solves the n-challenge).
    /// Without it, YouTube downloads degrade into misleading format errors —
    /// Phase 1's missingJSRuntimeMessage already points users here.
    static let deno: ToolRequirement = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ToolRequirement(
            id: "deno",
            name: "deno",
            brewPackage: "deno",
            docsURL: "https://docs.deno.com/runtime/",
            searchPaths: [
                "/opt/homebrew/bin/deno",
                "/usr/local/bin/deno",
                "\(home)/.deno/bin/deno",
                "\(home)/.local/bin/deno",
                "/opt/local/bin/deno",
            ]
        )
    }()

    static let all: [ToolRequirement] = [ytdlp, galleryDl, ffmpeg, deno]

    static func tool(withID id: String) -> ToolRequirement? {
        all.first { $0.id == id }
    }

    // MARK: - Unified path resolution

    /// The one resolver shared by the requirements banner and the launch-path
    /// properties in DownloadManager — the banner must never disagree with
    /// what downloads actually execute. First existing search path wins;
    /// `exists` is injectable for tests.
    static func resolvedPath(
        for tool: ToolRequirement,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        tool.searchPaths.first(where: exists)
    }

    // MARK: - Version probing (pure parts)

    /// yt-dlp CalVer builds older than this are considered outdated even when
    /// Homebrew's local index has no newer formula.
    static let ytDlpMaxAgeDays = 90

    /// Deterministic date math — never the user's locale/timezone calendar.
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// First line of `<tool> --version` → the bare version string.
    /// Verbatim shapes: yt-dlp "2026.07.04" (CalVer), gallery-dl "1.32.9"
    /// (SEMVER), ffmpeg "ffmpeg version 9.0.1 …", deno "deno 2.x.y …".
    /// The first dotted numeric token wins; a leading "v"/"n" build prefix is
    /// stripped; undotted year ranges ("2000-2025") never match.
    static func parsedVersion(fromFirstLine line: String) -> String? {
        for token in line.split(separator: " ") {
            var candidate = token
            if candidate.first == "v" || candidate.first == "n" {
                candidate = candidate.dropFirst()
            }
            if let match = candidate.range(of: #"^[0-9]+(\.[0-9]+)+"#, options: .regularExpression) {
                return String(candidate[match])
            }
        }
        return nil
    }

    /// yt-dlp CalVer "2026.07.04" → its build date. Nil for anything that is
    /// not a yyyy.MM.dd version (gallery-dl's SEMVER "1.32.9" carries no date
    /// — age is NOT derivable from it).
    static func calVerDate(_ version: String) -> Date? {
        let parts = version.split(separator: ".")
        guard parts.count == 3, parts[0].count == 4,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return utcCalendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// "21 months old" / "45 days old" — the banner's humanized age.
    static func humanizedAge(from date: Date, now: Date) -> String {
        let months = utcCalendar.dateComponents([.month], from: date, to: now).month ?? 0
        if months >= 2 { return "\(months) months old" }
        let days = utcCalendar.dateComponents([.day], from: date, to: now).day ?? 0
        return days == 1 ? "1 day old" : "\(days) days old"
    }

    /// Probe result × brew-outdated list → per-tool status.
    /// Rules: no path → missing; yt-dlp CalVer older than `ytDlpMaxAgeDays` →
    /// outdated (with humanized age); any tool listed by `brew outdated` →
    /// outdated; unparseable probe output → ok("unknown") so existence still
    /// counts. ffmpeg/deno/gallery-dl have no age rule — existence + probe +
    /// brew-outdated only.
    static func deriveStatus(
        toolID: String,
        brewPackage: String,
        installedPath: String?,
        versionLine: String?,
        brewOutdated: Set<String>,
        now: Date
    ) -> ToolStatus {
        guard installedPath != nil else { return .missing }
        let version = versionLine.flatMap { parsedVersion(fromFirstLine: $0) }
        let age = version.flatMap { calVerDate($0) }.map { humanizedAge(from: $0, now: now) }
        if toolID == ytdlp.id, let version, let buildDate = calVerDate(version) {
            let days = utcCalendar.dateComponents([.day], from: buildDate, to: now).day ?? 0
            if days > ytDlpMaxAgeDays {
                return .outdated(installed: version, detail: age)
            }
        }
        if brewOutdated.contains(brewPackage) {
            return .outdated(installed: version ?? "unknown", detail: age)
        }
        return .ok(version: version ?? "unknown")
    }

    /// Problems only (statuses ≠ ok), ordered missing first, then outdated,
    /// keeping the catalogue's relative order within each group.
    static func orderedProblems(_ healths: [ToolHealth]) -> [ToolHealth] {
        let missing = healths.filter { $0.status == .missing }
        let outdated = healths.filter {
            if case .outdated = $0.status { return true } else { return false }
        }
        return missing + outdated
    }

    // MARK: - Checks

    static func missingTools() -> [ToolRequirement] {
        all.filter { !$0.isInstalled }
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// `brew outdated --quiet <names>` against the LOCAL formula index — no
    /// forced network. Names not managed by brew make it exit non-zero;
    /// failures are tolerated silently (whatever names it printed still
    /// count). Callers must check `brewPath` themselves for the empty case.
    @MainActor
    static func brewOutdatedNames(packages: [String]) async -> Set<String> {
        guard let brew = brewPath, !packages.isEmpty else { return [] }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Homebrew.fullPATH
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        var names: Set<String> = []
        _ = await ProcessRunner.runRaw(
            executablePath: brew,
            arguments: ["outdated", "--quiet"] + packages,
            environment: env,
            onLine: { line in
                // --quiet prints one bare formula name per line; anything else
                // (errors, warnings) simply won't match a catalogue package.
                let name = line.split(separator: " ").first.map(String.init) ?? line
                if packages.contains(name) { names.insert(name) }
            }
        )
        return names
    }

    // MARK: - Homebrew install / upgrade

    /// Surfaced above the log when a brew run failed on a network error.
    static let brewNetworkFailureMessage =
        "Homebrew couldn't reach the network — check your connection and try again."

    /// brew's "already installed and up-to-date" warnings are noise in a
    /// repair log — the interesting lines are the ones that change something.
    static func isSuppressedBrewNoise(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("already installed") || lower.contains("already up-to-date")
    }

    /// Maps a failed brew run's log to a friendly one-liner when the cause is
    /// recognizably the network; nil keeps the generic check-the-log pointer.
    static func friendlyBrewFailure(inLog lines: [String]) -> String? {
        let networkTells = [
            "could not resolve host",
            "network is unreachable",
            "failed to connect",
            "no route to host",
            "couldn't connect to server",
        ]
        for line in lines {
            let lower = line.lowercased()
            if networkTells.contains(where: lower.contains) { return brewNetworkFailureMessage }
        }
        return nil
    }

    /// The combined flow's argument plan: install what's missing, then
    /// upgrade what's outdated. Pure so tests can pin the exact argv.
    static func brewInvocations(missing: [String], outdated: [String]) -> [[String]] {
        var invocations: [[String]] = []
        if !missing.isEmpty { invocations.append(["install"] + missing) }
        if !outdated.isEmpty { invocations.append(["upgrade"] + outdated) }
        return invocations
    }

    /// Install `tools` via Homebrew, streaming each output line to `onLine`.
    /// Returns the process exit code (0 = success).
    static func installWithBrew(
        tools: [ToolRequirement],
        onLine: @escaping @MainActor (String) -> Void
    ) async -> Int32 {
        // Auto-update off: a plain install works from the local index and
        // shouldn't stall on a slow network.
        await runBrew(
            invocations: [["install"] + tools.map(\.brewPackage)],
            allowAutoUpdate: false,
            onLine: onLine)
    }

    /// Upgrade `tools` via Homebrew. Auto-update stays ON: upgrading from a
    /// stale local index would happily report "already up-to-date" while the
    /// tool stays broken — the exact lie this feature exists to end.
    static func upgradeWithBrew(
        tools: [ToolRequirement],
        onLine: @escaping @MainActor (String) -> Void
    ) async -> Int32 {
        await runBrew(
            invocations: [["upgrade"] + tools.map(\.brewPackage)],
            allowAutoUpdate: true,
            onLine: onLine)
    }

    /// The combined flow: install missing, then upgrade outdated, one shared
    /// log stream. Stops at the first failing step and returns its exit code.
    static func repairWithBrew(
        missing: [ToolRequirement],
        outdated: [ToolRequirement],
        onLine: @escaping @MainActor (String) -> Void
    ) async -> Int32 {
        await runBrew(
            invocations: brewInvocations(
                missing: missing.map(\.brewPackage),
                outdated: outdated.map(\.brewPackage)),
            allowAutoUpdate: !outdated.isEmpty,
            onLine: onLine)
    }

    private static func runBrew(
        invocations: [[String]],
        allowAutoUpdate: Bool,
        onLine: @escaping @MainActor (String) -> Void
    ) async -> Int32 {
        guard let brew = brewPath else { return -1 }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Homebrew.fullPATH
        if !allowAutoUpdate { env["HOMEBREW_NO_AUTO_UPDATE"] = "1" }
        for arguments in invocations {
            let code = await ProcessRunner.runRaw(
                executablePath: brew,
                arguments: arguments,
                environment: env,
                onLine: { line in
                    // Strip ANSI colour codes that brew emits
                    let stripped = line.replacingOccurrences(
                        of: "\\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
                    if !stripped.isEmpty { onLine(stripped) }
                }
            )
            if code != 0 { return code }
        }
        return 0
    }
}
