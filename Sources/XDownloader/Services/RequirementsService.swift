import Foundation

struct ToolRequirement: Identifiable {
    let id: String  // stable, used as dict key
    let name: String
    let brewPackage: String
    let docsURL: String
    let searchPaths: [String]
    /// argv for the health probe. Most tools take GNU-style `--version`;
    /// ffmpeg REJECTS it (exit 8, empty stdout, banner on stderr) and only
    /// accepts single-dash `-version` — probing it with the wrong flag made
    /// every healthy ffmpeg derive `.broken` forever.
    var versionArguments: [String] = ["--version"]

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
/// `broken` is a file that exists but can't be run (exec failure, non-zero
/// exit, hung probe, or no parseable version output) — red family, because a
/// broken tool fails downloads exactly like a missing one.
enum ToolStatus: Equatable {
    case missing
    case broken(detail: String)
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
            ],
            // ffmpeg has no `--version`: it exits 8 with the banner on stderr
            // and NOTHING on stdout. `-version` prints
            // "ffmpeg version 9.0.1 …" on stdout and exits 0.
            versionArguments: ["-version"]
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

    /// Every catalogue tool's resolved absolute path — feeds child-process
    /// PATH composition (Homebrew.launchPATH) so launched downloads can exec
    /// exactly the binaries the probe certified.
    static var resolvedToolPaths: [String] {
        all.compactMap(\.installedPath)
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

    /// yt-dlp CalVer "2026.07.04" → its build date; nightly builds append a
    /// timestamp part ("2024.11.04.232815"), so 3 OR 4 dot-parts are accepted
    /// and the first three are used. Nil for anything else (gallery-dl's
    /// SEMVER "1.32.9" carries no date — age is NOT derivable from it).
    static func calVerDate(_ version: String) -> Date? {
        let parts = version.split(separator: ".")
        guard parts.count == 3 || parts.count == 4, parts[0].count == 4,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return utcCalendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// "21 months old" / "45 days old" — the banner's humanized age.
    /// Clamped at zero: a build date in the future (clock skew, timezone
    /// edges) must never render a negative age.
    static func humanizedAge(from date: Date, now: Date) -> String {
        let months = utcCalendar.dateComponents([.month], from: date, to: now).month ?? 0
        if months >= 2 { return "\(months) months old" }
        let days = max(0, utcCalendar.dateComponents([.day], from: date, to: now).day ?? 0)
        return days == 1 ? "1 day old" : "\(days) days old"
    }

    /// The `broken` detail — the probe couldn't get a version out of the
    /// binary (exec failure, non-zero exit, timeout, or unparseable output).
    static let brokenProbeDetail = "can't run"

    /// Probe result × brew-outdated list → per-tool status.
    /// Rules: no path → missing; no parseable probed version (exec failure,
    /// non-zero exit, timeout, garbage output) → broken, NEVER ok — an
    /// unrunnable binary fails downloads exactly like a missing one; yt-dlp
    /// CalVer older than `ytDlpMaxAgeDays` → outdated (with humanized age);
    /// any tool listed by `brew outdated` → outdated. ffmpeg/deno/gallery-dl
    /// have no age rule — existence + probe + brew-outdated only.
    static func deriveStatus(
        toolID: String,
        brewPackage: String,
        installedPath: String?,
        versionLine: String?,
        brewOutdated: Set<String>,
        now: Date
    ) -> ToolStatus {
        guard installedPath != nil else { return .missing }
        guard let version = versionLine.flatMap({ parsedVersion(fromFirstLine: $0) }) else {
            return .broken(detail: brokenProbeDetail)
        }
        let age = calVerDate(version).map { humanizedAge(from: $0, now: now) }
        if toolID == ytdlp.id, let buildDate = calVerDate(version) {
            let days = utcCalendar.dateComponents([.day], from: buildDate, to: now).day ?? 0
            if days > ytDlpMaxAgeDays {
                return .outdated(installed: version, detail: age)
            }
        }
        if brewOutdated.contains(brewPackage) {
            return .outdated(installed: version, detail: age)
        }
        return .ok(version: version)
    }

    /// Problems only (statuses ≠ ok), ordered missing first, then broken,
    /// then outdated, keeping the catalogue's relative order within each
    /// group. Red family = missing ∪ broken.
    static func orderedProblems(_ healths: [ToolHealth]) -> [ToolHealth] {
        let missing = healths.filter { $0.status == .missing }
        let broken = healths.filter {
            if case .broken = $0.status { return true } else { return false }
        }
        let outdated = healths.filter {
            if case .outdated = $0.status { return true } else { return false }
        }
        return missing + broken + outdated
    }

    // MARK: - Checks

    static func missingTools() -> [ToolRequirement] {
        all.filter { !$0.isInstalled }
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// True when a resolved tool path lives under a Homebrew prefix. A brew
    /// reinstall/upgrade only ever touches brew's own cellar — running it for
    /// a pipx/MacPorts/manual install at ~/.local/bin or /opt/local "succeeds"
    /// while the actually-resolved binary stays broken.
    static func isBrewManagedPath(_ path: String) -> Bool {
        path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/")
    }

    /// `brew outdated --quiet <names>` against the LOCAL formula index — no
    /// forced network. Names not managed by brew make it exit non-zero;
    /// failures are tolerated silently (whatever names it printed still
    /// count). Callers must check `brewPath` themselves for the empty case.
    /// Main-actor-confined mutable box: `runRaw`'s @Sendable line sink cannot
    /// capture a mutable local, and every delivery happens on the main actor.
    @MainActor
    private final class OutdatedNames {
        var value: Set<String> = []
    }

    @MainActor
    static func brewOutdatedNames(packages: [String]) async -> Set<String> {
        guard let brew = brewPath, !packages.isEmpty else { return [] }
        let env = brewEnvironment(
            base: ProcessInfo.processInfo.environment, allowAutoUpdate: false)
        let names = OutdatedNames()
        _ = await ProcessRunner.runRaw(
            executablePath: brew,
            arguments: ["outdated", "--quiet"] + packages,
            environment: env,
            onLine: { line in
                // --quiet prints one bare formula name per line; anything else
                // (errors, warnings) simply won't match a catalogue package.
                let name = line.split(separator: " ").first.map(String.init) ?? line
                if packages.contains(name) { names.value.insert(name) }
            }
        )
        return names.value
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
    /// "Already installed" chatter is excluded from failure detection.
    static func friendlyBrewFailure(inLog lines: [String]) -> String? {
        let networkTells = [
            "could not resolve host",
            "network is unreachable",
            "failed to connect",
            "no route to host",
            "couldn't connect to server",
        ]
        for line in lines where !isSuppressedBrewNoise(line) {
            let lower = line.lowercased()
            if networkTells.contains(where: lower.contains) { return brewNetworkFailureMessage }
        }
        return nil
    }

    /// What the repair run means for the user, derived AFTER the forced
    /// re-probe so the sheet never claims "All done" while a problem stands.
    enum RepairOutcome: Equatable {
        /// Exit 0 and no problems remain.
        case success
        /// Exit 0 but a repaired tool still derives a problem: brew's local
        /// index likely lags the release. Carries the full user-facing copy.
        case indexMayLag(String)
        /// Non-zero exit: a friendly cause when recognizable, else nil
        /// (the view keeps its generic check-the-log pointer).
        case failed(String?)
    }

    static func repairOutcome(
        exitCode: Int32,
        remainingProblems: [ToolHealth],
        log: [String]
    ) -> RepairOutcome {
        guard exitCode == 0 else { return .failed(friendlyBrewFailure(inLog: log)) }
        guard !remainingProblems.isEmpty else { return .success }
        let names = remainingProblems.map(\.brewPackage).joined(separator: " ")
        return .indexMayLag(
            "Homebrew reports it's already at its newest available version — the index may lag the release; try again later or update manually (brew upgrade \(names))."
        )
    }

    /// The combined flow's argument plan: install what's missing, reinstall
    /// what's broken, then upgrade what's outdated. Pure so tests can pin the
    /// exact argv.
    static func brewInvocations(missing: [String], broken: [String], outdated: [String]) -> [[String]] {
        var invocations: [[String]] = []
        if !missing.isEmpty { invocations.append(["install"] + missing) }
        if !broken.isEmpty { invocations.append(["reinstall"] + broken) }
        if !outdated.isEmpty { invocations.append(["upgrade"] + outdated) }
        return invocations
    }

    /// The brew process environment. `allowAutoUpdate` must actively REMOVE
    /// an inherited HOMEBREW_NO_AUTO_UPDATE (a shell-profile export would
    /// otherwise silently keep the index stale through an upgrade).
    static func brewEnvironment(base: [String: String], allowAutoUpdate: Bool) -> [String: String] {
        var env = base
        env["PATH"] = Homebrew.fullPATH
        if allowAutoUpdate {
            env.removeValue(forKey: "HOMEBREW_NO_AUTO_UPDATE")
        } else {
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        return env
    }

    /// Strips brew's ANSI colour codes. The escape is a literal U+001B scalar
    /// — an ICU pattern spelled "\\u{1B}" silently matches nothing.
    static func strippedANSI(_ line: String) -> String {
        line.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// Install `tools` via Homebrew, streaming each output line to `onLine`.
    /// Returns the process exit code (0 = success).
    static func installWithBrew(
        tools: [ToolRequirement],
        onLine: @escaping @MainActor @Sendable (String) -> Void
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
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Int32 {
        await runBrew(
            invocations: [["upgrade"] + tools.map(\.brewPackage)],
            allowAutoUpdate: true,
            onLine: onLine)
    }

    /// The combined flow: install missing, reinstall broken, then upgrade
    /// outdated — one shared log stream. Every step runs even when an earlier
    /// one fails (one bad formula must not doom the rest); the FIRST failing
    /// step's exit code is returned.
    static func repairWithBrew(
        missing: [ToolRequirement],
        broken: [ToolRequirement],
        outdated: [ToolRequirement],
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Int32 {
        await runBrew(
            invocations: brewInvocations(
                missing: missing.map(\.brewPackage),
                broken: broken.map(\.brewPackage),
                outdated: outdated.map(\.brewPackage)),
            allowAutoUpdate: !outdated.isEmpty,
            onLine: onLine)
    }

    private static func runBrew(
        invocations: [[String]],
        allowAutoUpdate: Bool,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Int32 {
        guard let brew = brewPath else { return -1 }
        let env = brewEnvironment(
            base: ProcessInfo.processInfo.environment, allowAutoUpdate: allowAutoUpdate)
        // Steps run independently: aborting at the first failure used to leave
        // every later tool unrepaired because of one unrelated bad formula.
        var firstFailure: Int32 = 0
        for arguments in invocations {
            let code = await ProcessRunner.runRaw(
                executablePath: brew,
                arguments: arguments,
                environment: env,
                onLine: { line in
                    let stripped = strippedANSI(line)
                    if !stripped.isEmpty { onLine(stripped) }
                }
            )
            if code != 0, firstFailure == 0 { firstFailure = code }
        }
        return firstFailure
    }
}
