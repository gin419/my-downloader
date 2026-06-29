import Foundation

/// Accumulates bytes across reads and yields only complete newline-terminated lines
/// (lossily UTF-8 decoded), so a line — or a multi-byte character — split across two
/// `availableData` chunks isn't truncated or dropped. `flush()` returns any trailing
/// partial line. Reads for one pipe are serialized; the lock guards the race with
/// `flush()` after the handler is detached.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func take(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(String(decoding: data[data.startIndex..<nl], as: UTF8.self))
            data.removeSubrange(data.startIndex...nl)
        }
        return lines
    }
    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        defer { data.removeAll() }
        return String(decoding: data, as: UTF8.self)
    }
}

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
    env["PATH"] =
        existingPath.isEmpty
        ? "\(homebrewPaths):/usr/bin:/bin:/usr/sbin:/sbin"
        : "\(homebrewPaths):\(existingPath)"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    register(process)

    let stdoutBuffer = LineBuffer()
    let stderrBuffer = LineBuffer()
    func makeHandler(_ buffer: LineBuffer) -> @Sendable (FileHandle) -> Void {
        return { @Sendable handle in
            let lines = buffer.take(handle.availableData)
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                for line in lines {
                    lineParser(line.trimmingCharacters(in: .whitespaces), item)
                }
            }
        }
    }

    stdout.fileHandleForReading.readabilityHandler = makeHandler(stdoutBuffer)
    stderr.fileHandleForReading.readabilityHandler = makeHandler(stderrBuffer)

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
    // Flush any trailing partial line (final output without a newline).
    for tail in [stdoutBuffer.flush(), stderrBuffer.flush()] {
        if let trimmed = tail?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty {
            lineParser(trimmed, item)
        }
    }
    unregister()

    return process.terminationStatus
}

/// Minimal variant: no DownloadItem coupling, no register/unregister.
/// Used by one-shot tool invocations (e.g. Homebrew install) that only need
/// streamed output and an exit code.
@discardableResult
func runRawProcess(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    onLine: @escaping @MainActor (String) -> Void
) async -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let stdoutBuffer = LineBuffer()
    let stderrBuffer = LineBuffer()
    func makeHandler(_ buffer: LineBuffer) -> @Sendable (FileHandle) -> Void {
        return { @Sendable handle in
            let lines = buffer.take(handle.availableData)
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                for line in lines {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { onLine(t) }
                }
            }
        }
    }
    stdout.fileHandleForReading.readabilityHandler = makeHandler(stdoutBuffer)
    stderr.fileHandleForReading.readabilityHandler = makeHandler(stderrBuffer)

    do { try process.run() } catch { return -1 }

    await withCheckedContinuation { continuation in
        process.terminationHandler = { _ in continuation.resume() }
    }

    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil
    for tail in [stdoutBuffer.flush(), stderrBuffer.flush()] {
        if let t = tail?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            await MainActor.run { onLine(t) }
        }
    }
    return process.terminationStatus
}
