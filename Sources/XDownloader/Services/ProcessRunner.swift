import Foundation

/// Runs an external process and streams its stdout/stderr through `lineParser`.
/// `register` is called with the live Process before launch (for cancellation support).
/// `unregister` is called after the process exits.
@MainActor
@discardableResult
func runProcess(
    executablePath: String,
    arguments: [String],
    item: DownloadItem,
    register: @escaping (Process) -> Void,
    unregister: @escaping () -> Void,
    lineParser: @escaping (String, DownloadItem) -> Void
) async -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    // GUI apps inherit a minimal PATH that excludes Homebrew. yt-dlp needs to
    // shell out to `deno` (to solve YouTube's JS n-challenge) and `ffmpeg` (to
    // merge streams); without them, YouTube downloads fail with "Requested
    // format is not available". gallery-dl similarly needs ffmpeg on PATH.
    var env = ProcessInfo.processInfo.environment
    let existingPath = env["PATH"] ?? ""
    let homebrewPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
    env["PATH"] = existingPath.isEmpty
        ? "\(homebrewPaths):/usr/bin:/bin:/usr/sbin:/sbin"
        : "\(homebrewPaths):\(existingPath)"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    register(process)

    let makeHandler: (FileHandle) -> @Sendable (FileHandle) -> Void = { handle in
        return { @Sendable _ in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                for line in text.components(separatedBy: .newlines) {
                    lineParser(line.trimmingCharacters(in: .whitespaces), item)
                }
            }
        }
    }

    stdout.fileHandleForReading.readabilityHandler = makeHandler(stdout.fileHandleForReading)
    stderr.fileHandleForReading.readabilityHandler = makeHandler(stderr.fileHandleForReading)

    do {
        try process.run()
    } catch {
        item.status = .failed(error.localizedDescription)
        unregister()
        return -1
    }

    await withCheckedContinuation { continuation in
        process.terminationHandler = { _ in continuation.resume() }
    }

    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil
    unregister()

    return process.terminationStatus
}
