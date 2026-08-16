import Foundation

struct LikesSyncHandle: Hashable, Codable {
    let value: String

    var displayName: String { "@\(value)" }
    var profileURL: URL { URL(string: "https://x.com/\(value)")! }
    var likesURL: URL { URL(string: "https://x.com/\(value)/likes")! }

    init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let url = URL(string: trimmed), let host = url.host?.lowercased(),
            host == "x.com" || host == "twitter.com" || host.hasSuffix(".x.com") || host.hasSuffix(".twitter.com")
        {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 1 || (parts.count == 2 && parts[1].lowercased() == "likes")
            else { throw LikesSyncValidationError.invalidHandle(input) }
            candidate = parts[0]
        } else if trimmed.hasPrefix("@") {
            candidate = String(trimmed.dropFirst())
        } else {
            candidate = trimmed
        }

        let normalized = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "@/ "))
        guard normalized.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil else {
            throw LikesSyncValidationError.invalidHandle(input)
        }
        let lowered = normalized.lowercased()
        guard !Self.reservedPaths.contains(lowered) else {
            throw LikesSyncValidationError.invalidHandle(input)
        }
        self.value = lowered
    }

    private static let reservedPaths: Set<String> = [
        "about", "account", "compose", "explore", "hashtag", "home", "i", "intent", "login",
        "logout", "messages", "notifications", "privacy", "search", "settings", "share", "signup",
        "tos", "welcome",
    ]
}

enum LikesSyncValidationError: Error, Equatable {
    case invalidHandle(String)
}

enum LikesSyncRunStatus: String, Codable, CaseIterable {
    case idle
    case running
    case cancelling
    case completed
    case partial
    case failed
    case cancelled
    case interrupted

    var isActive: Bool { self == .running || self == .cancelling }
    var needsAttention: Bool { self == .partial || self == .failed || self == .interrupted }
}

enum LikesSyncFailureCategory: String, Codable, CaseIterable {
    case authentication
    case rateLimited
    case unavailable
    case network
    case disk
    case tool
    case parse
    case unknown

    static func classify(_ message: String) -> LikesSyncFailureCategory {
        let lower = message.lowercased()
        if lower.contains("login") || lower.contains("unauthorized") || lower.contains("cookie") {
            return .authentication
        }
        if lower.contains("rate limit") || lower.contains("too many requests") || lower.contains("429") {
            return .rateLimited
        }
        if lower.contains("not found") || lower.contains("unavailable") || lower.contains("no results")
            || lower.contains("deleted")
        {
            return .unavailable
        }
        if lower.contains("timeout") || lower.contains("network") || lower.contains("connection")
            || lower.contains("temporarily unavailable")
        {
            return .network
        }
        if lower.contains("no space") || lower.contains("disk full") || lower.contains("permission denied")
            || lower.contains("read-only file system")
        {
            return .disk
        }
        if lower.contains("not installed") || lower.contains("unsupported url")
            || lower.contains("no suitable extractor") || lower.contains("process")
        {
            return .tool
        }
        if lower.contains("parse") || lower.contains("json") || lower.contains("decode") {
            return .parse
        }
        return .unknown
    }

    /// True when an HTTP-404 diagnostic names an X/Twitter API endpoint
    /// rather than a single tweet or media file. gallery-dl formats HTTP
    /// failures as "'404 Not Found' for '<url>'"; when X retires a GraphQL
    /// endpoint EVERY call 404s — that is the installed tool speaking a
    /// retired dialect (the historically documented way stale gallery-dl
    /// breaks), not deleted content. Per-item 404s (twimg media, status
    /// URLs) stay `.unavailable`.
    ///
    /// Declared red: always false for now; the URL inspection lands with the
    /// implementation commit.
    static func isEndpointNotFound(_ message: String) -> Bool {
        _ = message
        return false
    }
}

struct LikesSyncAccount: Equatable {
    var id: Int64?
    var handle: LikesSyncHandle
    var input: String
    var outputDirectory: URL
    var archivePath: URL
}

struct LikesSyncRun: Equatable {
    var id: String
    var accountID: Int64
    var status: LikesSyncRunStatus
    var startedAt: Date
    var finishedAt: Date?
    var tweetCount: Int
    var mediaCount: Int
    var failureCount: Int
    var skippedCount: Int = 0
    var noMediaCount: Int = 0
    var ignoredCount: Int = 0
}

struct LikesSyncCounts: Equatable, Codable {
    var discovered = 0
    var downloaded = 0
    var skipped = 0
    var noMedia = 0
    var failed = 0
    var ignored = 0
}

struct LikesSyncSnapshot: Equatable {
    var handle: LikesSyncHandle?
    var status: LikesSyncRunStatus
    var counts: LikesSyncCounts
    var failures: [LikesSyncFailure]
    var message: String?
    var outputDirectory: URL?
    var startedAt: Date?
    var finishedAt: Date?

    static let idle = LikesSyncSnapshot(
        handle: nil, status: .idle, counts: LikesSyncCounts(), failures: [],
        message: nil, outputDirectory: nil, startedAt: nil, finishedAt: nil)
}

enum LikesAccessVerification: Equatable {
    case idle
    case verifying
    case verified(LikesSyncHandle)
    /// gallery-dl exited cleanly but observed ZERO likes — what the wrong
    /// account's session (likes are private) or an empty account looks like.
    /// Distinct from `verified` and from `failed`, which names a diagnostic.
    case noLikesVisible(LikesSyncHandle)
    case failed(String)
}

/// Decision behind the Settings "Verify" status row. `verified` must mean
/// gallery-dl actually SAW at least one like — an exit code of 0 alone also
/// covers the wrong-account session, whose likes are private and therefore
/// invisible, and the empty account. Those report `noLikesVisible` instead.
enum LikesVerificationOutcome: Equatable {
    case verified
    case noLikesVisible
    case failed
}

extension LikesAccessVerification {
    /// Pure decision for the verify flow: `sawLikes` is true when at least one
    /// likes-verify extractor line was observed; `hasDiagnostics` when a useful
    /// diagnostic line was captured. "Verified" requires an observed like — a
    /// silent exit 0 is the third state, and a diagnostic still names the
    /// precise failure.
    static func outcome(exitCode: Int32, sawLikes: Bool, hasDiagnostics: Bool)
        -> LikesVerificationOutcome
    {
        guard exitCode == 0 else { return .failed }
        if sawLikes { return .verified }
        return hasDiagnostics ? .failed : .noLikesVisible
    }

    /// Settings status-row copy for `noLikesVisible`.
    static func noLikesVisibleMessage(for handle: LikesSyncHandle) -> String {
        "Could not see any likes for \(handle.displayName). If this account has likes, "
            + "the selected browser profile is signed in to a different account."
    }
}

struct LikesSyncTweet: Equatable {
    var tweetID: String
    var accountID: Int64
    var runID: String
    var url: String?
    var text: String?
    var authorHandle: String?
}

struct LikesSyncMedia: Equatable {
    var id: String
    var accountID: Int64
    var tweetID: String
    var runID: String
    var kind: String?
    var url: String?
    var filePath: String?
}

struct LikesSyncFailure: Equatable, Identifiable {
    var id: String
    var accountID: Int64
    var runID: String?
    var tweetID: String?
    var url: String?
    var category: LikesSyncFailureCategory
    var message: String
    var ignoredAt: Date?
    var resolvedAt: Date?
    var retryCount: Int
}

extension LikesSyncFailure {
    /// A run-level failure describes the whole sync (authentication, rate
    /// limit, disk…), not one liked tweet — it has neither a tweet id nor a
    /// URL, and retrying it re-runs the full scan.
    var isRunLevel: Bool { tweetID == nil && url == nil }

    /// Row title for the failure list. Per-item rows show the tweet URL or id;
    /// run-level rows say the whole sync failed and why, instead of
    /// masquerading as an item.
    var displayTitle: String {
        if let url { return url }
        if let tweetID { return "Tweet \(tweetID)" }
        switch category {
        case .authentication: return "Whole sync failed — sign-in"
        case .rateLimited: return "Whole sync failed — rate limit"
        case .network: return "Whole sync failed — network"
        case .disk: return "Whole sync failed — disk"
        case .unavailable: return "Whole sync failed — content unavailable"
        case .tool: return "Whole sync failed — gallery-dl"
        case .parse: return "Whole sync failed — output parsing"
        case .unknown: return "Whole sync failed"
        }
    }

    /// Retry button label. A run-level row's retry re-runs the whole scan, so
    /// its button says so.
    var retryActionTitle: String { isRunLevel ? "Retry Sync" : "Retry" }

    /// The failure whose message headlines a failed run: prefer a failure
    /// recorded by the current run, so a stale row whose `updated_at` was
    /// bumped (mid-run Ignore/Restore, a retry marker) never masks the new
    /// cause. Falls back to the list's own order — most recently updated
    /// first.
    static func headline(
        from failures: [LikesSyncFailure], currentRunID: String?
    ) -> LikesSyncFailure? {
        guard let currentRunID else { return failures.first }
        return failures.first { $0.runID == currentRunID } ?? failures.first
    }
}
