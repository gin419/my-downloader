import Foundation

/// Everything that distinguishes one site from another, gathered in one place.
///
/// Goal of this abstraction: adding a site = add one profile to `SiteRegistry`;
/// changing a site = edit only its profile, without risking other sites. This
/// is the foundation (Phase 1) — it owns URL detection, the fallback-pipeline
/// declaration, and the capability flags that used to be scattered as
/// `SiteKind(url:) == .x` / `isYouTube` checks across the services. Later phases
/// move the per-site *argument construction* itself in here too.
struct SiteProfile {

    /// A tool tried after yt-dlp when it fails / finds no media.
    enum Fallback {
        case galleryDl   // image tweets, Reddit posts/galleries, …
        case fxTwitter   // X CDN direct download for spam-flagged/hidden tweets
    }

    /// Stable identifier, also used as the history "site" label.
    let id: String
    /// Whether this profile handles the given URL.
    let matches: (String) -> Bool
    /// Ordered fallbacks tried after yt-dlp. Declared here as the single source
    /// of truth; the orchestrator consumes the convenience flags below today and
    /// will drive its whole fallback loop from this list in a later phase.
    let fallbacks: [Fallback]

    // MARK: Capability flags (replace the old scattered site checks)

    /// Request subtitles via yt-dlp (`--write-sub`). YouTube only.
    let supportsSubtitles: Bool
    /// Use yt-dlp's DASH/avc YouTube format selector instead of the generic one.
    let usesYouTubeFormatSelector: Bool
    /// Suffix appended to the yt-dlp output template (before the extension).
    /// Twitter uses it for the multi-video playlist index; empty elsewhere
    /// (other extractors hit a yt-dlp template bug — see YtDlpService).
    let outputTemplateSuffix: String
    /// Kill yt-dlp if it follows a redirect *out* of the original page, so a
    /// fallback can handle it. Twitter only.
    let detectsExternalRedirect: Bool
    /// Extra gallery-dl args for this site (filename template, etc.); empty when
    /// gallery-dl's per-extractor defaults are fine.
    let galleryDlArgs: [String]

    var usesGalleryDlFallback: Bool { fallbacks.contains(.galleryDl) }
    var usesFxTwitterFallback: Bool { fallbacks.contains(.fxTwitter) }
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

    static let all: [SiteProfile] = [twitter, youtube, reddit, other]

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
