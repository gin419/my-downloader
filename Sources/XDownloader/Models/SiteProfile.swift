import Foundation

/// Everything that distinguishes one site from another, gathered in one place.
///
/// Goal of this abstraction: adding a site = add one profile to `SiteRegistry`;
/// changing a site = edit only its profile, without risking other sites. It owns
/// URL detection, the fallback-pipeline declaration, the per-site argument
/// construction (`galleryDlArgs` / `outputTemplateSuffix`), and the capability
/// flags that used to be scattered as `SiteKind(url:) == .x` / `isYouTube` checks.
struct SiteProfile {

    /// A tool tried after yt-dlp when it fails / finds no media.
    enum Fallback {
        case galleryDl  // image tweets, Reddit posts/galleries, …
        case fxTwitter  // X CDN direct download for spam-flagged/hidden tweets
    }

    /// Stable identifier, also used as the history "site" label.
    let id: String
    /// Whether this profile handles the given URL.
    let matches: (String) -> Bool
    /// Ordered fallbacks tried after yt-dlp — the single source of truth; the
    /// orchestrator drives its whole fallback loop from this list.
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
    /// Kill yt-dlp if it follows a redirect *out* of the original page, so a
    /// fallback can handle it. Twitter only.
    let detectsExternalRedirect: Bool
    /// Extra gallery-dl args for this site (filename template, etc.); empty when
    /// gallery-dl's per-extractor defaults are fine.
    let galleryDlArgs: [String]

}

/// The single registry of known sites. Order matters: specific profiles first,
/// the `other` catch-all last (first match wins).
enum SiteRegistry {

    static let twitter = SiteProfile(
        id: "twitter",
        matches: { $0.contains("x.com/") || $0.contains("twitter.com/") },
        fallbacks: [.galleryDl, .fxTwitter],
        supportsSubtitles: false,
        usesYouTubeFormatSelector: false,
        outputTemplateSuffix: "%(playlist_index& [%(playlist_index)02d]|)s",
        detectsExternalRedirect: true,
        // gallery-dl Twitter args (hard-won against silent empty-success bugs):
        // quoted/retweets=true fetch media owned by quoted/retweeted tweets;
        // {content!s:.100} forces str(None) so no-text tweets don't raise on the
        // .100 precision spec; [{tweet_id}] keeps filenames unique so same-author
        // no-text tweets don't collide and get skipped as "already downloaded".
        galleryDlArgs: [
            "-o", "quoted=true",
            "-o", "retweets=true",
            "-f", "{author[nick]} - {content!s:.100} [{tweet_id}] #{num}.{extension}",
        ]
    )

    static let youtube = SiteProfile(
        id: "youtube",
        matches: { $0.contains("youtube.com/") || $0.contains("youtu.be/") },
        fallbacks: [],
        supportsSubtitles: true,
        usesYouTubeFormatSelector: true,
        outputTemplateSuffix: "",
        detectsExternalRedirect: false,
        galleryDlArgs: []
    )

    static let reddit = SiteProfile(
        id: "reddit",
        matches: { $0.contains("reddit.com/") || $0.contains("redd.it/") },
        fallbacks: [.galleryDl],
        supportsSubtitles: false,
        usesYouTubeFormatSelector: false,
        outputTemplateSuffix: "",
        detectsExternalRedirect: false,
        galleryDlArgs: []
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
            "-f", "{username} - {description|''!s:.100} [{post_shortcode}] #{num}.{extension}",
        ]
    )

    /// Catch-all: the generic yt-dlp extractor with no fallbacks.
    static let other = SiteProfile(
        id: "other",
        matches: { _ in true },
        fallbacks: [],
        supportsSubtitles: false,
        usesYouTubeFormatSelector: false,
        outputTemplateSuffix: "",
        detectsExternalRedirect: false,
        galleryDlArgs: []
    )

    static let all: [SiteProfile] = [twitter, youtube, reddit, instagram, other]

    static func profile(for url: String) -> SiteProfile {
        all.first { $0.matches(url) } ?? other
    }

    /// True if `url` is Twitter content, including the twimg.com CDN. Used to
    /// detect whether yt-dlp followed a redirect *out* of the original tweet
    /// (distinct from `twitter.matches`, which routes only tweet page URLs).
    static func isTwitterContent(_ url: String) -> Bool {
        url.contains("x.com") || url.contains("twitter.com") || url.contains("twimg.com")
    }
}
