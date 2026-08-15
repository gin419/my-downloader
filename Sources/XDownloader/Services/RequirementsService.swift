import Foundation

struct ToolRequirement: Identifiable {
    let id: String  // stable, used as dict key
    let name: String
    let brewPackage: String
    let docsURL: String
    let searchPaths: [String]

    var installedPath: String? {
        searchPaths.first { FileManager.default.fileExists(atPath: $0) }
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
        nil  // stub — implemented in the follow-up commit
    }

    // MARK: - Version probing (pure parts)

    /// yt-dlp CalVer builds older than this are considered outdated even when
    /// Homebrew's local index has no newer formula.
    static let ytDlpMaxAgeDays = 90

    /// First line of `<tool> --version` → the bare version string.
    /// Verbatim shapes: yt-dlp "2026.07.04" (CalVer), gallery-dl "1.32.9"
    /// (SEMVER), ffmpeg "ffmpeg version 9.0.1 …", deno "deno 2.x.y …".
    static func parsedVersion(fromFirstLine line: String) -> String? {
        nil  // stub — implemented in the follow-up commit
    }

    /// yt-dlp CalVer "2026.07.04" → its build date. Nil for anything that is
    /// not a yyyy.MM.dd version (gallery-dl's SEMVER "1.32.9" carries no date
    /// — age is NOT derivable from it).
    static func calVerDate(_ version: String) -> Date? {
        nil  // stub — implemented in the follow-up commit
    }

    /// "21 months old" / "45 days old" — the banner's humanized age.
    static func humanizedAge(from date: Date, now: Date) -> String {
        ""  // stub — implemented in the follow-up commit
    }

    /// Probe result × brew-outdated list → per-tool status.
    /// Rules: no path → missing; yt-dlp CalVer older than `ytDlpMaxAgeDays` →
    /// outdated (with humanized age); any tool listed by `brew outdated` →
    /// outdated; unparseable probe output → ok("unknown") so existence still
    /// counts. ffmpeg/deno/gallery-dl have no age rule.
    static func deriveStatus(
        toolID: String,
        brewPackage: String,
        installedPath: String?,
        versionLine: String?,
        brewOutdated: Set<String>,
        now: Date
    ) -> ToolStatus {
        .missing  // stub — implemented in the follow-up commit
    }

    /// Problems only (statuses ≠ ok), ordered missing first, then outdated,
    /// keeping the catalogue's relative order within each group.
    static func orderedProblems(_ healths: [ToolHealth]) -> [ToolHealth] {
        []  // stub — implemented in the follow-up commit
    }

    // MARK: - Checks

    static func missingTools() -> [ToolRequirement] {
        all.filter { !$0.isInstalled }
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Homebrew install

    /// Install `tools` via Homebrew, streaming each output line to `onLine`.
    /// Returns the process exit code (0 = success).
    static func installWithBrew(
        tools: [ToolRequirement],
        onLine: @escaping @MainActor (String) -> Void
    ) async -> Int32 {
        guard let brew = brewPath else { return -1 }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Homebrew.fullPATH
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return await ProcessRunner.runRaw(
            executablePath: brew,
            arguments: ["install"] + tools.map(\.brewPackage),
            environment: env,
            onLine: { line in
                // Strip ANSI colour codes that brew emits
                let stripped = line.replacingOccurrences(
                    of: "\\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
                if !stripped.isEmpty { onLine(stripped) }
            }
        )
    }
}
