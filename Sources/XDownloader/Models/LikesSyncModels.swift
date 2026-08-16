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
    /// diagnostic line was captured.
    ///
    /// Declared red: still reports `verified` on a silent exit 0; the honest
    /// third state lands with the implementation.
    static func outcome(exitCode: Int32, sawLikes: Bool, hasDiagnostics: Bool)
        -> LikesVerificationOutcome
    {
        if exitCode == 0, !hasDiagnostics || sawLikes { return .verified }
        return .failed
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
    /// run-level rows must say the whole sync failed and why, instead of
    /// masquerading as an item.
    ///
    /// Declared red: still shows the item placeholder for run-level rows; the
    /// category-based title lands with the implementation.
    var displayTitle: String {
        url ?? tweetID.map { "Tweet \($0)" } ?? "X Likes item"
    }

    /// Retry button label. A run-level row's retry silently re-runs the whole
    /// scan, so its button must say so.
    ///
    /// Declared red: still labels run-level rows "Retry"; the honest label
    /// lands with the implementation.
    var retryActionTitle: String { "Retry" }
}
