import Foundation

enum LikesSyncEventName: String, Equatable {
    case prepare
    case post
    case postAfter = "post-after"
    case after
    case skip
    case error
}

struct LikesSyncEvent: Equatable {
    var name: LikesSyncEventName
    var tweetID: String?
    var tweetURL: String?
    var text: String?
    var authorHandle: String?
    var mediaID: String?
    var mediaURL: String?
    var mediaPath: String?
    var mediaKind: String?
    var message: String?
    var failureCategory: LikesSyncFailureCategory?
}

struct LikesSyncRunAccumulator: Equatable {
    private(set) var tweetIDs: Set<String> = []
    private(set) var mediaIDs: Set<String> = []
    private(set) var downloadedMediaIDs: Set<String> = []
    private(set) var skippedMediaIDs: Set<String> = []
    private(set) var noMediaTweetIDs: Set<String> = []
    private var tweetIDsWithMedia: Set<String> = []
    private(set) var failures: [LikesSyncFailureCategory: Int] = [:]

    var tweetCount: Int { tweetIDs.count }
    var mediaCount: Int { mediaIDs.count }
    var downloadedCount: Int { downloadedMediaIDs.count }
    var skippedCount: Int { skippedMediaIDs.count }
    var noMediaCount: Int { noMediaTweetIDs.count }
    var failureCount: Int { failures.values.reduce(0, +) }

    mutating func apply(_ event: LikesSyncEvent) {
        if let tweetID = event.tweetID, !tweetID.isEmpty {
            tweetIDs.insert(tweetID)
        }
        let mediaKey: String? = {
            if let mediaID = event.mediaID, !mediaID.isEmpty { return mediaID }
            if let path = event.mediaPath, !path.isEmpty { return path }
            if let url = event.mediaURL, !url.isEmpty { return url }
            return nil
        }()
        if let mediaKey {
            mediaIDs.insert(mediaKey)
            if let tweetID = event.tweetID { tweetIDsWithMedia.insert(tweetID) }
            if event.name == .after { downloadedMediaIDs.insert(mediaKey) }
            if event.name == .skip { skippedMediaIDs.insert(mediaKey) }
        }
        if event.name == .postAfter, let tweetID = event.tweetID, mediaKey == nil,
            !tweetIDsWithMedia.contains(tweetID)
        {
            noMediaTweetIDs.insert(tweetID)
        }
        if event.name == .error, let message = event.message, !message.isEmpty {
            let category = event.failureCategory ?? LikesSyncFailureCategory.classify(message)
            failures[category, default: 0] += 1
        }
    }
}

enum LikesSyncEventParser {
    private static let prefix = "likes-sync\t"

    /// True when a non-event stderr/stdout line is a diagnostic worth keeping
    /// for failure messages. gallery-dl's info/debug-level lines are routine
    /// progress — most importantly the rate-limit wait notices ("[twitter][info]
    /// Waiting until … (rate limit)"), which describe a pause the run already
    /// survived, not a failure — so only warning/error-level (or unleveled)
    /// lines qualify.
    static func isUsefulDiagnostic(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("[info]") || lower.contains("[debug]") { return false }
        if lower.trimmingCharacters(in: .whitespaces).hasPrefix("waiting") { return false }
        if lower.contains("[warning]") && lower.contains("api errors (") { return false }
        // Stale-tool output carries no bracketed level: argparse rejections
        // (a gallery-dl too old for this app's CLI options exits 2 printing
        // "usage:" / "gallery-dl: error: unrecognized arguments…") and
        // Python traceback tails ("KeyError: 'data'"). Dropped, the failure
        // card falls back to a bare exit code and blames the user's login
        // for an outdated binary. Indented usage-continuation and traceback
        // frame lines stay excluded — only the head/tail names the cause.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if lower.contains("unrecognized arguments") || trimmed.hasPrefix("usage: gallery-dl")
            || trimmed.hasPrefix("gallery-dl: error:")
            || trimmed.range(of: #"^\w+Error: "#, options: .regularExpression) != nil
        {
            return true
        }
        let cookieFailure =
            lower.contains("cookie")
            && (lower.contains("[warning]") || lower.contains("[error]")
                || lower.contains("failed") || lower.contains("unable")
                || lower.contains("could not") || lower.contains("not found"))
        return lower.contains("[error]") || lower.contains("429") || lower.contains("rate limit")
            || lower.contains("login") || lower.contains("unauthorized") || cookieFailure
            || lower.contains("no space") || lower.contains("permission denied")
            || lower.contains("connection") || lower.contains("timeout")
    }

    static func parse(_ line: String) -> LikesSyncEvent? {
        guard let split = line.firstIndex(of: ":") else { return nil }
        let eventRaw = String(line[..<split])
        guard let eventName = LikesSyncEventName(rawValue: eventRaw) else { return nil }

        let payloadStart = line.index(after: split)
        let payload = String(line[payloadStart...])
        guard payload.hasPrefix(prefix) else { return nil }
        let jsonText = String(payload.dropFirst(prefix.count))
        guard let data = jsonText.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return LikesSyncEvent(
                name: .error,
                tweetID: nil,
                tweetURL: nil,
                text: nil,
                authorHandle: nil,
                mediaID: nil,
                mediaURL: nil,
                mediaPath: nil,
                mediaKind: nil,
                message: "Could not parse gallery-dl event JSON",
                failureCategory: .parse
            )
        }

        let tweetID = firstString(object, keys: ["tweet_id", "tweetID", "id"])
        let message = firstString(object, keys: ["message", "error", "exception", "reason"])
        let category = message.map(LikesSyncFailureCategory.classify)
        return LikesSyncEvent(
            name: eventName,
            tweetID: tweetID,
            tweetURL: firstString(object, keys: ["tweet_url", "tweetURL", "url", "webpage_url"]),
            text: firstString(object, keys: ["content", "text", "description"]),
            authorHandle: firstString(
                object,
                keys: ["author.nick", "author.name", "user.name", "username", "handle", "author"]
            ).map(normalizeAuthor),
            mediaID: mediaIdentifier(object: object, tweetID: tweetID),
            mediaURL: firstString(object, keys: ["media_url", "mediaURL", "file_url", "src"]),
            mediaPath: firstString(object, keys: ["_path", "filepath", "file_path", "path"]),
            mediaKind: firstString(object, keys: ["type", "media_type", "extension"]),
            message: message,
            failureCategory: category
        )
    }

    private static func firstString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            let components = key.split(separator: ".").map(String.init)
            var nested: Any? = object
            for component in components {
                nested = (nested as? [String: Any])?[component]
            }
            if let value = nested as? String, !value.isEmpty {
                return value
            }
            if let value = nested as? CustomStringConvertible {
                let string = value.description
                if !string.isEmpty { return string }
            }
        }
        return nil
    }

    private static func mediaIdentifier(object: [String: Any], tweetID: String?) -> String? {
        if let value = firstString(object, keys: ["media_id", "mediaID"]) { return value }
        guard let tweetID else {
            return firstString(object, keys: ["_filename", "filename", "_path", "path"])
        }
        if let number = firstString(object, keys: ["num", "index"]) { return "\(tweetID):\(number)" }
        if let filename = firstString(object, keys: ["_filename", "filename"]) { return "\(tweetID):\(filename)" }
        return nil
    }

    private static func normalizeAuthor(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
    }
}
