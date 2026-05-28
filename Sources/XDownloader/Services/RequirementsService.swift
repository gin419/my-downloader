import Foundation

struct ToolRequirement: Identifiable {
    let id: String          // stable, used as dict key
    let name: String
    let brewPackage: String
    let docsURL: String
    let searchPaths: [String]

    var installedPath: String? {
        searchPaths.first { FileManager.default.fileExists(atPath: $0) }
    }
    var isInstalled: Bool { installedPath != nil }
}

enum RequirementsService {

    // MARK: - Tool catalogue

    static let ytdlp = ToolRequirement(
        id: "yt-dlp",
        name: "yt-dlp",
        brewPackage: "yt-dlp",
        docsURL: "https://github.com/yt-dlp/yt-dlp#installation",
        searchPaths: [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
        ]
    )

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
            ]
        )
    }()

    static let ffmpeg = ToolRequirement(
        id: "ffmpeg",
        name: "ffmpeg",
        brewPackage: "ffmpeg",
        docsURL: "https://ffmpeg.org/download.html",
        searchPaths: [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
    )

    static let all: [ToolRequirement] = [ytdlp, galleryDl, ffmpeg]

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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install"] + tools.map(\.brewPackage)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let forward: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                for raw in text.components(separatedBy: .newlines) {
                    let line = raw
                        // Strip ANSI colour codes
                        .replacingOccurrences(of: "\\u{1B}\\[[0-9;]*[A-Za-z]",
                                              with: "",
                                              options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty { onLine(line) }
                }
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { @Sendable h in forward(h) }
        stderr.fileHandleForReading.readabilityHandler = { @Sendable h in forward(h) }

        do { try process.run() } catch { return -1 }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        return process.terminationStatus
    }
}
