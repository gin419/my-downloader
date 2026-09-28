import Foundation

/// What an Instagram link names, read off the link itself. Instagram
/// downloads run with the browser login, and the tools walk whatever a link
/// names: handed a tab, a hashtag or a highlights link they fetch everything
/// it names, a whole collection or a whole page of posts, with that login.
/// So the app downloads one post, reel or story at a time, or an account's
/// own newest posts up to the number set in Settings, and every other link
/// on the site is turned down before anything is started. The judgement is
/// host and path only: no request is made to reach it.
enum InstagramLink {

    enum Shape: Equatable {
        /// One post, reel, video post or story.
        case singleItem
        /// An account's profile, its posts tab or its reels tab: the
        /// account's own posts, downloaded up to the number set in Settings.
        /// The username is lowercased, as Instagram treats it.
        case profile(username: String)
        /// On Instagram, but naming neither one item nor a profile: a tab
        /// that is not the account's own posts, a collection or a page of
        /// the site.
        case notASingleItem
        /// Not an Instagram page link at all, and not this guard's to judge:
        /// another site, a look-alike host, a host that serves media files.
        case notInstagram
    }

    // House style of the Threads message it stands beside. A Retry cannot
    // change the outcome, so the copy names the links to paste instead.
    static let notASingleItemMessage =
        "This Instagram link isn't a single post, reel, story or profile — XDownloader doesn't download tagged or saved posts, highlights, hashtags or other pages of the site. Paste the link of a post, reel or story, or of the account's profile, instead."

    /// Exact hosts, compared lowercased — never a substring or suffix test:
    /// either would also claim the hosts Instagram serves media files from,
    /// look-alike domains, and any link that merely carries an Instagram
    /// address in its query.
    static let hosts: Set<String> = [
        "instagram.com", "www.instagram.com", "m.instagram.com", "instagr.am", "www.instagr.am",
    ]

    private static let itemKinds: Set<String> = ["p", "reel", "reels", "tv"]
    private static let codePattern = "^[A-Za-z0-9_-]+$"
    private static let storyIDPattern = "^[0-9]+$"
    private static let usernamePattern = "^[A-Za-z0-9._]+$"
    /// Instagram's own rule for a username: up to 30 letters, digits,
    /// periods and underscores, with no period at either end and no two in
    /// a row. Stricter than `usernamePattern`, which only has to tell a
    /// story's username from the other segments.
    private static let profileUsernamePattern = "^(?!\\.)(?!.*\\.\\.)(?!.*\\.$)[A-Za-z0-9._]{1,30}$"
    /// The tabs of a profile that name the account's own posts. The reels
    /// tab is a view of posts the posts tab holds too, so both download the
    /// same thing: the account's posts, reels included.
    private static let ownPostsTabs: Set<String> = ["posts", "reels"]
    /// First segments that are pages of the site, never a username, compared
    /// lowercased: "/Explore/" is the explore page too. The item kinds and
    /// the pages judged above are among them, so that none of them ever
    /// reads as an account.
    static let reservedFirstSegments: Set<String> = [
        "p", "reel", "reels", "tv", "stories", "share", "s", "explore", "accounts", "direct",
        "about", "api", "challenge", "developer", "directory", "emails", "graphql", "igtv", "legal",
        "locations", "oauth", "privacy", "session", "static", "tags", "web", "your_activity",
    ]

    /// Judges a link by its shape. The query string and the fragment are
    /// ignored entirely: neither changes what the path names (`img_index`
    /// picks the slide shown, not the slide downloaded).
    static func shape(of link: String) -> Shape {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host?.lowercased(), hosts.contains(host)
        else { return .notInstagram }
        // The path as written, escapes and all. Decoded, "reels%2F<code>"
        // would read as two segments here while the tools, which are handed
        // the link as written, read one and take the account's reels tab
        // from it. No pattern below admits a "%", so a segment that carries
        // an escape names nothing.
        let segments = components.percentEncodedPath.split(separator: "/").map(String.init)
        if namesSingleItem(segments) { return .singleItem }
        if let username = profileUsername(segments) { return .profile(username: username) }
        return .notASingleItem
    }

    /// The account a profile link names, nil for any other link.
    static func profileUsername(of link: String) -> String? {
        guard case .profile(let username) = shape(of: link) else { return nil }
        return username
    }

    /// The one spelling a profile link is kept in, whatever host, letter
    /// case, tab or query it was pasted with, so that two spellings of one
    /// profile are one row. Nil for any other link.
    static func canonicalProfileLink(for link: String) -> String? {
        profileUsername(of: link).map { "https://www.instagram.com/\($0)/" }
    }

    /// "/<username>", "/<username>/posts" and "/<username>/reels", and
    /// nothing after them: any other tab is the account's tagged, saved or
    /// highlights, and a deeper path names something else.
    private static func profileUsername(_ segments: [String]) -> String? {
        guard let first = segments.first, segments.count <= 2,
            !reservedFirstSegments.contains(first.lowercased()),
            matches(profileUsernamePattern, first)
        else { return nil }
        if segments.count == 2, !ownPostsTabs.contains(segments[1]) { return nil }
        return first.lowercased()
    }

    /// Whatever follows the code or the story id is not read: the item is
    /// named by then ("/p/<code>/embed/" is still that one post).
    private static func namesSingleItem(_ segments: [String]) -> Bool {
        guard let first = segments.first else { return false }  // the home page
        let rest = Array(segments.dropFirst())
        switch first {
        case "p", "reel", "reels", "tv":
            return namesItem(kind: first, rest)
        case "share":
            // "/share/<kind>/<id>" and the bare "/share/<id>".
            guard let second = rest.first else { return false }
            if itemKinds.contains(second) { return namesItem(kind: second, Array(rest.dropFirst())) }
            return matches(codePattern, second)
        case "stories":
            // "/stories/<username>/<id>". Without the id the link names
            // every story the account has up; "highlights" in the
            // username's place names a whole highlight reel.
            guard rest.count >= 2, rest[0] != "highlights" else { return false }
            return matches(usernamePattern, rest[0]) && matches(storyIDPattern, rest[1])
        case "s", "explore", "accounts", "direct":
            // "/s/…" is the share form of a highlight reel.
            return false
        default:
            // A username first: "/<username>/p/<code>". A username alone
            // is the profile, and a username with anything but an item
            // after it is one of the profile's tabs.
            guard matches(usernamePattern, first), let kind = rest.first, itemKinds.contains(kind) else { return false }
            return namesItem(kind: kind, Array(rest.dropFirst()))
        }
    }

    /// True when `rest`, the segments after an item kind, begins with a
    /// code. "/reels/audio/<id>" is the page of everything that uses one
    /// sound, which the tools would read as a reel whose code is "audio";
    /// "/reels/" alone is the feed.
    ///
    /// A link that lost its "?" carries its parameters in the path
    /// ("/p/<code>&igsh=…"). yt-dlp ends the code at the "&" and downloads
    /// that one post, so the code is read the same way here; anything else
    /// glued to a code names nothing.
    private static func namesItem(kind: String, _ rest: [String]) -> Bool {
        guard let segment = rest.first else { return false }
        let code = segment.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        let glued = segment.dropFirst(code.count)
        guard !code.isEmpty, glued.isEmpty || glued.hasPrefix("&") else { return false }
        return !(kind == "reels" && code == "audio")
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// A profile link's download: the account's own newest posts, up to the
/// number set in Settings. The number counts posts, not files — a carousel
/// is one post however many pictures it holds.
enum InstagramProfilePosts {

    static let defaultLimit = 100
    static let limitRange = 1...1000

    /// A number from Settings, kept inside `limitRange`: a typed 0 or 5000
    /// becomes the nearest number the download can take.
    static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, limitRange.lowerBound), limitRange.upperBound)
    }

    /// The row's title, fixed when the row starts: the number is the one
    /// the run was started with, not whatever Settings says later.
    static func title(username: String, limit: Int) -> String {
        "\(username) - newest \(limit) post\(limit == 1 ? "" : "s")"
    }
}
