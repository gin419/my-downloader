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

/// Outcome of a finished download process. `code` is the raw
/// `terminationStatus`: an exit code normally, the **signal number** when
/// `wasSignal` is set (`terminationReason == .uncaughtSignal` — our own
/// pause/cancel `terminate()`, or a crash). User-facing messages must not
/// present a signal number as if the tool chose to exit with it.
struct ProcessResult {
    let code: Int32
    let wasSignal: Bool
    var isSuccess: Bool { code == 0 && !wasSignal }
}

enum ProcessRunner {

    /// Generic cancellable streaming process used by long-running work that
    /// is not represented by a DownloadItem (for example, an account-level
    /// Likes sync). The caller owns the Process reference via register /
    /// unregister and can terminate it at any time.
    @MainActor
    @discardableResult
    static func runStreaming(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        if let environment {
            process.environment = environment
        } else {
            var env = ProcessInfo.processInfo.environment
            let existingPath = env["PATH"] ?? ""
            env["PATH"] =
                existingPath.isEmpty
                ? Homebrew.fullPATH
                : "\(Homebrew.binPaths):\(existingPath)"
            process.environment = env
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        guard !Task.isCancelled else { return 15 }
        register(process)
        guard !Task.isCancelled else {
            unregister()
            return 15
        }
        do {
            try process.run()
        } catch {
            unregister()
            onLine("[process][error] \(error.localizedDescription)")
            return -1
        }

        let stdoutTask = makeStreamingReader(
            handle: stdout.fileHandleForReading,
            buffer: LineBuffer(),
            onLine: onLine)
        let stderrTask = makeStreamingReader(
            handle: stderr.fileHandleForReading,
            buffer: LineBuffer(),
            onLine: onLine)

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }

        // The process can terminate before its pipe callbacks have delivered the
        // final bytes. Await both readers so the caller can safely finalize
        // durable state immediately after this method returns.
        await stdoutTask.value
        await stderrTask.value
        unregister()
        return process.terminationStatus
    }

    private static func makeStreamingReader(
        handle: FileHandle,
        buffer: LineBuffer,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) -> Task<Void, Never> {
        Task.detached {
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                for line in buffer.take(chunk) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { await onLine(trimmed) }
                }
            }
            if let trimmed = buffer.flush()?.trimmingCharacters(in: .whitespaces),
                !trimmed.isEmpty
            {
                await onLine(trimmed)
            }
        }
    }

    /// Runs an external process and streams its stdout/stderr through `lineParser`.
    /// `register` is called with the live Process before launch (for cancellation support).
    /// `unregister` is called after the process exits. A launch failure sets the
    /// item failed and returns `code` -1 (not a signal).
    @MainActor
    @discardableResult
    static func run(
        executablePath: String,
        arguments: [String],
        item: DownloadItem,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void,
        lineParser: @escaping (String, DownloadItem) -> Void
    ) async -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        // GUI apps inherit a minimal PATH that excludes Homebrew. yt-dlp needs to
        // shell out to `deno` (to solve YouTube's JS n-challenge) and `ffmpeg` (to
        // merge streams); without them, YouTube downloads fail with "Requested
        // format is not available". gallery-dl similarly needs ffmpeg on PATH.
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] =
            existingPath.isEmpty
            ? Homebrew.fullPATH
            : "\(Homebrew.binPaths):\(existingPath)"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        register(process)

        do {
            try process.run()
        } catch {
            item.status = .failed(error.localizedDescription)
            unregister()
            return ProcessResult(code: -1, wasSignal: false)
        }

        // Same reader pattern as runStreaming: blocking availableData loops
        // (trailing partial line included) that are awaited below.
        let stdoutTask = makeStreamingReader(
            handle: stdout.fileHandleForReading,
            buffer: LineBuffer(),
            onLine: { line in lineParser(line, item) })
        let stderrTask = makeStreamingReader(
            handle: stderr.fileHandleForReading,
            buffer: LineBuffer(),
            onLine: { line in lineParser(line, item) })

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }

        // The process can terminate before its pipes have delivered the final
        // bytes. Await both readers so a last ERROR line always reaches
        // lineParser before the caller composes a generic exit message —
        // the detach-a-readabilityHandler approach used here before could
        // drop it on short-lived processes.
        await stdoutTask.value
        await stderrTask.value
        unregister()

        return ProcessResult(
            code: process.terminationStatus,
            wasSignal: process.terminationReason == .uncaughtSignal)
    }

    /// Minimal variant: no DownloadItem coupling, no register/unregister.
    /// Used by one-shot tool invocations (e.g. Homebrew install) that only need
    /// streamed output and an exit code.
    @discardableResult
    static func runRaw(
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
}
