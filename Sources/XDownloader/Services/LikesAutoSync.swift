import Foundation

/// How often automatic Likes sync checks for new likes. Fifteen minutes is
/// the floor on purpose: every check costs at least one Likes API request
/// under the user's own X login, and X rate-limits that login.
enum LikesAutoSyncInterval: Int, CaseIterable, Identifiable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case threeHours = 10800
    case sixHours = 21600

    static let `default`: LikesAutoSyncInterval = .thirtyMinutes

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var displayName: String {
        switch self {
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .threeHours: return "3 hours"
        case .sixHours: return "6 hours"
        }
    }

    /// A stored value that is not one of the options (a hand-edited
    /// defaults file) maps to the nearest option, never below the floor.
    static func nearest(toSeconds seconds: Int) -> LikesAutoSyncInterval {
        allCases.min(by: { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) }) ?? .default
    }
}

/// The persisted part of automatic Likes sync. Kept out of `AppSettings` so
/// it travels as one small unit with its own keys.
struct LikesAutoSyncSettings: Equatable {
    var isEnabled = false
    var interval: LikesAutoSyncInterval = .default
}

/// Why automatic sync stopped trying on its own. Each of these needs the
/// user to change something; checking again every few minutes would only
/// fail the same way.
enum LikesAutoSyncPauseReason: Equatable {
    case authentication
    case tool
    case disk

    var message: String {
        switch self {
        case .authentication:
            return "Automatic sync paused — X login could not be verified. Verify access or sync manually to resume."
        case .tool:
            return "Automatic sync paused — gallery-dl needs an update. Update it, then sync manually to resume."
        case .disk:
            return "Automatic sync paused — the Likes folder is not writable or the disk is full. Sync manually to resume."
        }
    }
}

/// What one Likes run means for the auto-sync schedule.
enum LikesAutoSyncRunOutcome: Equatable {
    /// Finished — with or without new media, and with or without per-item
    /// failures (a deleted tweet is not a reason to slow down).
    case succeeded
    case cancelled
    /// X rate-limited the run, fatally or partway through.
    case rateLimited
    /// A run-level failure that may clear by itself (network, unknown).
    case transientFailure
    /// A run-level failure only the user can fix.
    case needsUser(LikesAutoSyncPauseReason)

    /// `runLevelCategory` is the category of the run-level failure (no tweet
    /// id) this run recorded, if any. A clean exit after
    /// `-A`/`skip=abort:N` stopped the scan is exit 0 — gallery-dl swallows
    /// the StopExtraction it raises — so it lands in `.succeeded`.
    static func classify(
        exitCode: Int32,
        cancelled: Bool,
        runLevelCategory: LikesSyncFailureCategory?,
        rateLimitTruncated: Bool
    ) -> LikesAutoSyncRunOutcome {
        if cancelled { return .cancelled }
        switch runLevelCategory {
        case .authentication: return .needsUser(.authentication)
        case .tool: return .needsUser(.tool)
        case .disk: return .needsUser(.disk)
        case .rateLimited: return .rateLimited
        case .some: return .transientFailure
        case nil: break
        }
        if rateLimitTruncated { return .rateLimited }
        // A non-zero exit always records a run-level failure unless the run
        // already recorded per-item ones; those per-item failures are not a
        // reason to back off.
        return .succeeded
    }
}

enum LikesAutoSyncSkipReason: Equatable {
    case disabled
    case paused
    case busy
    case invalidHandle
    case galleryDlMissing
}

enum LikesAutoSyncDecision: Equatable {
    case run
    case skip(LikesAutoSyncSkipReason)
}

/// The pure scheduling rules behind automatic Likes sync: whether a due
/// check runs, how long until the next one, and how failures slow it down.
/// `DownloadManager` owns the timer and feeds this type what happened.
struct LikesAutoSyncSchedule: Equatable {
    /// Consecutive already-saved files after which an automatic run stops
    /// scanning (gallery-dl `-A N`). New likes sit at the top of the Likes
    /// timeline, so a run of saved media means everything below was seen by
    /// an earlier scan. gallery-dl fetches Likes 50 tweets per request, so
    /// 30 saved files ends a run with nothing new inside its first request,
    /// instead of the hundreds a full scan makes. 30 is still several times
    /// a single post's media (up to 4 pictures), so a few re-liked posts or
    /// a previously failed item between new likes don't stop it too early.
    static let abortAfterConsecutiveSkips = 30

    /// Delay before the first check after launch or after the setting is
    /// turned on: soon enough to pick up likes made while the app was closed,
    /// late enough not to compete with launch.
    static let firstCheckDelay: TimeInterval = 60

    /// Rate limits and transient failures double the interval, up to 2⁴×,
    /// and never beyond 12 hours (or the interval itself, if longer).
    static let maxBackoffLevel = 4
    static let maxBackoffDelay: TimeInterval = 12 * 3600

    private(set) var backoffLevel = 0
    private(set) var pauseReason: LikesAutoSyncPauseReason?
    /// True until the first check after launch / enabling has been made.
    private(set) var isFirstCheck = true

    var isPaused: Bool { pauseReason != nil }

    func nextDelay(interval: TimeInterval) -> TimeInterval {
        if isFirstCheck, backoffLevel == 0 { return min(Self.firstCheckDelay, interval) }
        guard backoffLevel > 0 else { return interval }
        let backedOff = interval * pow(2, Double(backoffLevel))
        return min(backedOff, max(interval, Self.maxBackoffDelay))
    }

    static func decide(
        enabled: Bool,
        paused: Bool,
        syncActive: Bool,
        verifying: Bool,
        hasValidHandle: Bool,
        hasGalleryDl: Bool
    ) -> LikesAutoSyncDecision {
        guard enabled else { return .skip(.disabled) }
        guard !paused else { return .skip(.paused) }
        guard !syncActive, !verifying else { return .skip(.busy) }
        guard hasValidHandle else { return .skip(.invalidHandle) }
        guard hasGalleryDl else { return .skip(.galleryDlMissing) }
        return .run
    }

    /// A due check happened (ran or was skipped): later delays use the
    /// regular interval.
    mutating func markChecked() {
        isFirstCheck = false
    }

    mutating func record(_ outcome: LikesAutoSyncRunOutcome) {
        isFirstCheck = false
        switch outcome {
        case .succeeded:
            backoffLevel = 0
            pauseReason = nil
        case .cancelled:
            break
        case .rateLimited, .transientFailure:
            backoffLevel = min(backoffLevel + 1, Self.maxBackoffLevel)
        case .needsUser(let reason):
            pauseReason = reason
        }
    }

    /// The user acted (turned the setting on, changed the interval, verified
    /// access, or a manual sync succeeded): forget backoff and pause, and
    /// check again soon.
    mutating func resume() {
        backoffLevel = 0
        pauseReason = nil
        isFirstCheck = true
    }

    /// Automatic runs stay silent unless they brought something new or need
    /// the user: new media, a new failed item, or a pause.
    static func shouldNotify(
        outcome: LikesAutoSyncRunOutcome, downloadedCount: Int, newFailureCount: Int
    ) -> Bool {
        if case .needsUser = outcome { return true }
        if case .cancelled = outcome { return false }
        return downloadedCount > 0 || newFailureCount > 0
    }
}

/// What the Likes card and Settings show about automatic sync.
struct LikesAutoSyncStatus: Equatable {
    var lastCheckAt: Date?
    var nextCheckAt: Date?
    var pauseReason: LikesAutoSyncPauseReason?
    var backoffLevel = 0
}
