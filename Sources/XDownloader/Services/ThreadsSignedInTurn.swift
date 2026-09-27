import Foundation

/// The line the signed-in Threads requests stand in (see
/// ThreadsSignedInPage). Several restricted links started together would
/// send the login several times in the same moment, and that is the pattern
/// an account gets challenged for. So the requests take turns: one at a
/// time, whatever the concurrency setting, and with a pause after each.
///
/// Only the signed-in request waits here. The logged-out page request, the
/// media and every other site never come near it.
@MainActor
final class ThreadsSignedInTurn {

    /// The app's one line. A seam for tests, which bring their own.
    static let shared = ThreadsSignedInTurn()

    /// How long after one request's end the next may start.
    nonisolated static let pause: TimeInterval = 3

    private let pause: TimeInterval
    private let now: @MainActor () -> Date
    /// Waits out the seconds given, and throws when the task is cancelled
    /// meanwhile.
    private let sleep: @MainActor (TimeInterval) async throws -> Void

    private var held = false
    /// When the last request ended; nil before the first.
    private var lastEnded: Date?
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(
        pause: TimeInterval = ThreadsSignedInTurn.pause,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.pause = pause
        self.now = now
        self.sleep = sleep
    }

    /// Runs `request` when its turn has come, and hands the turn on when it
    /// returns — whatever it returns: a failure and a timeout end the turn
    /// like a page does. Nil when the task was cancelled while it waited:
    /// `request` was never started, and the place in line is given up.
    /// `whileWaiting` is called when the request has to wait, for the line
    /// or for the pause; a request that starts at once never calls it.
    func run<Result>(whileWaiting: () -> Void, _ request: () async -> Result) async -> Result? {
        guard await take(whileWaiting: whileWaiting) else { return nil }
        let result = await request()
        lastEnded = now()
        handOn()
        return result
    }

    /// True once the turn is this task's and the pause is over. False when
    /// the task was cancelled first; the turn is then not held.
    private func take(whileWaiting: () -> Void) async -> Bool {
        if Task.isCancelled { return false }
        if held {
            whileWaiting()
            let id = UUID()
            let granted = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiting.append((id: id, continuation: continuation))
                }
            } onCancel: {
                Task { @MainActor in self.leave(id) }
            }
            // Granted, the turn came over still held.
            guard granted else { return false }
        } else {
            held = true
        }
        // The pause is waited out holding the turn, so the ones behind wait
        // for it too. Cancelled in it, no request was made: the next in
        // line owes only what is left of the pause.
        if let lastEnded {
            let rest = min(pause, pause - now().timeIntervalSince(lastEnded))
            if rest > 0 {
                whileWaiting()
                try? await sleep(rest)
            }
        }
        if Task.isCancelled {
            handOn()
            return false
        }
        return true
    }

    private func handOn() {
        guard !waiting.isEmpty else {
            held = false
            return
        }
        waiting.removeFirst().continuation.resume(returning: true)
    }

    /// A cancelled task leaves the line. One that was handed the turn in
    /// the same moment is no longer in it, and gives the turn up itself.
    private func leave(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}
