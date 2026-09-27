import Foundation

/// What an Instagram link names, read off the link itself. Instagram
/// downloads run with the browser login, and the tools walk whatever a link
/// names: handed a profile, a tab, a hashtag or a highlights link they fetch
/// everything it names, a whole account or a whole page of posts, with that
/// login. So the app downloads one post, reel or story at a time, and every
/// other link on the site is turned down before anything is started. The
/// judgement is host and path only: no request is made to reach it.
enum InstagramLink {

    enum Shape: Equatable {
        /// One post, reel, video post or story.
        case singleItem
        /// On Instagram, but naming an account, a collection or a page of
        /// the site.
        case notASingleItem
        /// Not an Instagram page link at all, and not this guard's to judge:
        /// another site, a look-alike host, a host that serves media files.
        case notInstagram
    }

    // House style of the Threads message it stands beside. A Retry cannot
    // change the outcome, so the copy names the link to paste instead.
    static let notASingleItemMessage =
        "This Instagram link isn't a single post, reel or story — XDownloader doesn't download whole Instagram accounts. Open the post, reel or story on Instagram and paste its own link instead."

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
        return namesSingleItem(segments) ? .singleItem : .notASingleItem
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
