import Foundation

@MainActor
protocol LikesSyncProcessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Int32
}

struct LiveLikesSyncProcessRunner: LikesSyncProcessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Int32 {
        await ProcessRunner.runStreaming(
            executablePath: executablePath,
            arguments: arguments,
            register: register,
            unregister: unregister,
            onLine: onLine)
    }
}
