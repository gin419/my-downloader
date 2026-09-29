import Foundation

/// Everything that distinguishes one site from another, gathered in one place.
///
/// Goal of this abstraction: adding a site = add one profile to `SiteRegistry`;
/// changing a site = edit only its profile, without risking other sites. It owns
/// URL detection, the fallback-pipeline declaration, the per-site argument
/// construction (`galleryDlArgs` / `outputTemplateSuffix`), and the capability
/// flags that used to be scattered as `SiteKind(url:) == .x` / `isYouTube` checks.
struct SiteProfile {

    /// A downloader tried after yt-dlp when it fails / finds no media — or,
    /// for a site that skips yt-dlp (`usesYtDlp == false`), the downloader
    /// that does the whole job.
    enum Fallback {
        case galleryDl  // image tweets, Reddit posts/galleries, …
        case fxTwitter  // X CDN direct download for spam-flagged/hidden tweets
        case threads  // in-app Threads resolver, direct download

        /// Runs an external command-line tool, which may not be installed.
        /// The in-app resolvers need nothing but the network.
        var needsExternalTool: Bool {
            switch self {
            case .galleryDl: return true
            case .fxTwitter, .threads: return false
            }
        }
    }

    /// Stable identifier, also used as the history "site" label.
    let id: String
    /// Whether this profile handles the given URL.
    let matches: (String) -> Bool
    /// Ordered fallbacks tried after yt-dlp (or instead of it, see
    /// `usesYtDlp`) — the single source of truth; the orchestrator drives its
    /// whole fallback loop from this list.
    let fallbacks: [Fallback]

    // MARK: Capability flags (replace the old scattered site checks)

    /// Request subtitles via yt-dlp (`--write-sub`). YouTube only.
    let supportsSubtitles: Bool
    /// Use yt-dlp's DASH/avc YouTube format selector instead of the generic one.
    let usesYouTubeFormatSelector: Bool
    /// Suffix appended to the yt-dlp output template (before the extension).
    /// Twitter and Instagram use it for the multi-video playlist index so
    /// entries of one post don't collide on the same filename; empty elsewhere.
    let outputTemplateSuffix: String
    /// The extractor's own %(title)s already begins with "<uploader> - ", so
    /// the template must not prepend %(uploader)s again or every filename and
    /// row title doubles the author ("NASA - NASA - …"). Twitter only.
    let extractorTitleIncludesUploader: Bool
    /// Kill yt-dlp if it follows a redirect *out* of the original page, so a
    /// fallback can handle it. Twitter only.
    let detectsExternalRedirect: Bool
    /// Extra gallery-dl args for this site (filename template, etc.); empty when
    /// gallery-dl's per-extractor defaults are fine.
    let galleryDlArgs: [String]
    /// Non-nil: after a SUCCESSFUL yt-dlp run, gallery-dl runs once more with
    /// these extra args to collect the post's photos. yt-dlp deliberately skips
    /// photos in mixed video+photo posts and exits 0, and success bypasses the
    /// failure-driven `fallbacks` chain — without the sweep the photos would
    /// silently vanish. Never runs for a site that skips yt-dlp.
    let imageSweepArgs: [String]?
    /// False: yt-dlp is not run at all and `fallbacks` does the whole job.
    /// For sites yt-dlp has no extractor for — running it there costs
    /// seconds per link and leaves its raw "Unsupported URL" line as the
    /// row's message. Such a site must declare at least one fallback that
    /// needs no external tool, or nothing could ever download it. Declared
    /// last and defaulted so every other profile stays as written.
    var usesYtDlp: Bool = true
    /// True: the link names a page, not a file, and the address yt-dlp is to
    /// download is looked up in-app before every run (see
    /// `DmmPreviewResolver`). The row keeps the page link as its identity;
    /// the address is never stored. Defaulted like `usesYtDlp`.
    var resolvesAddressBeforeDownload: Bool = false
    /// False: nothing of the browser login goes to this site — yt-dlp is
    /// started without cookie arguments and the cookies file is not looked
    /// up. For a site whose downloads are what it serves every logged-out
    /// visitor. Defaulted like `usesYtDlp`.
    var receivesBrowserCookies: Bool = true
    /// Non-nil: the site is downloaded one item at a time. A link on it
    /// that names more than one item — a tab, a collection, a page of the
    /// site — would have the tools walk all of it with the browser login, so
    /// the run ends at once under `message` instead: no tool is started, no
    /// request is made and no cookie source is looked up. (An Instagram
    /// profile is the one exception, and is never turned down: it runs as
    /// its own bounded download, see `InstagramProfilePosts`.) Defaulted like
    /// `usesYtDlp`: a site that declares nothing turns nothing down.
    var singleItemGuard: SingleItemGuard? = nil

    struct SingleItemGuard {
        /// True for a link to turn down. Judged by the link's shape alone,
        /// without a request; a link that is not the site's own is never
        /// turned down.
        let turnsDown: (String) -> Bool
        /// The failed row's whole message.
        let message: String
    }
    /// Non-nil: the gallery-dl folder a single post of two or more files
    /// goes into inside the download folder — the file-name template less
    /// its " #{num}.{extension}", so the folder is named exactly as its
    /// files are, number aside, and gallery-dl cleans it the same way.
    /// gallery-dl picks it itself from the post's own file count before it
    /// writes (see `GalleryDlService.FolderMode`). Declared last and
    /// defaulted like `usesYtDlp`: a site without it stays loose.
    var galleryDlFolderFormat: String? = nil

    /// The message `link` is turned down under, nil when it may run.
    func refusalMessage(for link: String) -> String? {
        guard let singleItemGuard, singleItemGuard.turnsDown(link) else { return nil }
        return singleItemGuard.message
    }

}

/// The single registry of known sites. Order matters: specific profiles first,
/// the `other` catch-all last (first match wins). `threads` and `dmm` lead
/// because the other profiles match by substring: a Threads link whose
/// username ends in "x.com" ("/@fox.com/post/…") contains "x.com/" and would
/// be claimed by `twitter`, and so would a work page link carrying such text
/// in its query. The two match by host, so neither can claim the other's
/// links or anyone else's.
enum SiteRegistry {

    static let twitter = SiteProfile(
        id: "twitter",
        matches: { $0.contains("x.com/") || $0.contains("twitter.com/") },
        fallbacks: [.galleryDl, .fxTwitter],
        supportsSubtitles: false,
        usesYouTubeFormatSelector: false,
        // `{0}` replacement syntax, NOT the nested %(...)fmt form: the nested
        // form has never been valid on yt-dlp's current template engine
        // (verified to corrupt to null bytes and raise KeyError in
        // prepare_filename on 2023.07 through 2026.07) — for EVERY tweet,
        // single videos too — so yt-dlp never downloaded and gallery-dl
        // silently absorbed all Twitter traffic.
        outputTemplateSuffix: "%(playlist_index& [{0:02d}]|)s",
        // yt-dlp's twitter extractor builds title as "<user name> - <text>".
        extractorTitleIncludesUploader: true,
        detectsExternalRedirect: true,
        // gallery-dl Twitter args (hard-won against silent empty-success bugs):
        // quoted/retweets=true fetch media owned by quoted/retweeted tweets;
        // {content!s:.100} forces str(None) so no-text tweets don't raise on the
        // .100 precision spec; [{tweet_id}] keeps filenames unique so same-author
        // no-text tweets don't collide and get skipped as "already downloaded".
        galleryDlArgs: [
            "-o", "quoted=true",
            "-o", "retweets=true",
            "-f", twitterFileStem + " #{num}.{extension}",
        ],
        imageSweepArgs: ["-o", "videos=false"],
        galleryDlFolderFormat: twitterFileStem
    )

    /// A tweet's gallery-dl file name without its number and extension: the
    /// files' stem and the folder of a tweet with two or more files.
    private static let twitterFileStem = "{author[nick]} - {content!s:.100} [{tweet_id}]"

    static let youtube = SiteProfile(
        id: "youtube",
        matches: { $0.contains("youtube.com/") || $0.contains("youtu.be/") },
        fallbacks: [],
        supportsSubtitles: true,
        usesYouTubeFormatSelector: true,
        outputTemplateSuffix: "",
        extractorTitleIncludesUploader: false,
        detectsExternalRedirect: false,
        galleryDlArgs: [],
        imageSweepArgs: nil
    )

    static let reddit = SiteProfile(
        id: "reddit",
        matches: { $0.contains("reddit.com/") || $0.contains("redd.it/") },
        fallbacks: [.galleryDl],
        supportsSubtitles: false,
        usesYouTubeFormatSelector: false,
        outputTemplateSuffix: "",
        extractorTitleIncludesUploader: false,
        detectsExternalRedirect: false,
        galleryDlArgs: [],
        imageSweepArgs: nil
    )

    static let instagram = SiteProfile(
        id: "instagram",
        matches: { $0.contains("instagram.com/") || $0.contains("instagr.am/") },
        fallbacks: [.galleryDl],
        supportsSubtitles: false,
        usesYouTubeFormatSelector: false,
        // Multi-video carousels are a yt-dlp playlist whose entries all share
        // the post-level title ("Video by <user>") and uploader, so without a
        // per-entry discriminator every entry resolves to the SAME path —
        // yt-dlp downloads entry 1, skips the rest as "already downloaded",
        // and exits 0, silently losing videos 2..N (Twitter's exact trap).
        // The replacement uses yt-dlp's `{0}`-style string.Formatter syntax
        // (verified against yt-dlp 2026.7.4): nesting %(...)fmt inside the
        // conditional corrupts to null bytes and fails the whole download.
        outputTemplateSuffix: "%(playlist_index& [{0:02d}]|)s",
        extractorTitleIncludesUploader: false,
        detectsExternalRedirect: false,
        // gallery-dl Instagram args (keywords verified against gallery-dl
        // 1.32.6's instagram extractor): {description|''} substitutes an empty
        // string when the caption is missing — stories/highlights never set
        // `description`, and without the default the formatter prints a literal
        // "None"; !s:.100 then truncates safely (same trap as Twitter's
        // {content}); [{post_shortcode}] keeps filenames from different posts
        // unique; #{num} indexes carousel children, and the single-file " #1"
        // suffix is stripped after download like Twitter's.
        galleryDlArgs: [
            "-f", instagramFileStem + " #{num}.{extension}",
        ],
        imageSweepArgs: ["-o", "videos=false"],
        singleItemGuard: .init(
            turnsDown: { InstagramLink.shape(of: $0) == .notASingleItem },
            message: InstagramLink.notASingleItemMessage),
        galleryDlFolderFormat: instagramFileStem
    )

    /// A post's gallery-dl file name without its number and extension, as
    /// `twitterFileStem` is for a tweet.
    private static let instagramFileStem = "{username} - {description|''!s:.100} [{post_shortcode}]"

    /// Threads: neither yt-dlp nor gallery-dl can read it, so the in-app
    /// resolver is the only downloader and yt-dlp is skipped. (For a post
    /// Threads withholds from logged-out visitors the resolver has yt-dlp
    /// request the page once with the browser login; public posts need no
    /// tool.) Matching is by
    /// host, never by substring: a substring test claims "somethreads.com"
    /// and any link that merely carries a Threads address in its query, and
    /// misses an uppercase host.
    static let threads = SiteProfile(
        id: "threads",
        matches: { ThreadsService.isThreadsHost($0) },
        fallbacks: [.threads],
        supportsSubtitles: false,
        usesYouTubeFormatSelector: false,
        outputTemplateSuffix: "",
        extractorTitleIncludesUploader: false,
        detectsExternalRedirect: false,
        galleryDlArgs: [],
        imageSweepArgs: nil,
        usesYtDlp: false
    )

    /// Work pages whose preview clip is found in-app first: the page holds no
    /// media yt-dlp could read, so the clip's address is resolved and yt-dlp
    /// downloads that, logged out. Matching is by exact host, never by
    /// substring or suffix: the hosts that serve the files themselves, and
    /// every other host of the domain, stay with `other`, where their direct
    /// links have always downloaded.
    static let dmm = SiteProfile(
        id: "dmm",
        matches: { DmmPreviewResolver.isSiteHost($0) },
        fallbacks: [],
        supportsSubtitles: false,
        usesYouTubeFormatSelector: false,
        outputTemplateSuffix: "",
        extractorTitleIncludesUploader: false,
        detectsExternalRedirect: false,
        galleryDlArgs: [],
        imageSweepArgs: nil,
        resolvesAddressBeforeDownload: true,
        receivesBrowserCookies: false
    )

    /// Catch-all: the generic yt-dlp extractor with no fallbacks. The only
    /// profile that matches by default, so it must stay last.
    static let other = SiteProfile(
        id: "other",
        matches: { _ in true },
        fallbacks: [],
        supportsSubtitles: false,
        usesYouTubeFormatSelector: false,
        outputTemplateSuffix: "",
        extractorTitleIncludesUploader: false,
        detectsExternalRedirect: false,
        galleryDlArgs: [],
        imageSweepArgs: nil
    )

    static let all: [SiteProfile] = [threads, dmm, twitter, youtube, reddit, instagram, other]

    static func profile(for url: String) -> SiteProfile {
        all.first { $0.matches(url) } ?? other
    }

    /// The message `url` is turned down under, nil when it may run. Every
    /// profile is asked, not only the one the link is routed to: most
    /// profiles match by case-sensitive substring, so an Instagram link with
    /// an uppercase host is routed to `other`, and one whose username ends
    /// in "x.com" to `twitter` — and the tools would walk the account all
    /// the same. A guard only ever turns down links of its own site.
    static func refusalMessage(for url: String) -> String? {
        all.lazy.compactMap { $0.refusalMessage(for: url) }.first
    }

    /// True if `url` is Twitter content, including the twimg.com CDN. Used to
    /// detect whether yt-dlp followed a redirect *out* of the original tweet
    /// (distinct from `twitter.matches`, which routes only tweet page URLs).
    static func isTwitterContent(_ url: String) -> Bool {
        url.contains("x.com") || url.contains("twitter.com") || url.contains("twimg.com")
    }
}
