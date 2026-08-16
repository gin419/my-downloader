import Foundation

@MainActor
protocol LikesSyncProcessRunning {
    /// Returns the full `ProcessResult` — callers must be able to tell a
    /// signal death (`wasSignal`, `code` = signal number) from a real exit
    /// code before interpreting the number (a SIGINT death would otherwise
    /// read as argparse's exit 2).
    func run(
        executablePath: String,
        arguments: [String],
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> ProcessResult
}

struct LiveLikesSyncProcessRunner: LikesSyncProcessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> ProcessResult {
        await ProcessRunner.runStreaming(
            executablePath: executablePath,
            arguments: arguments,
            register: register,
            unregister: unregister,
            onLine: onLine)
    }
}
