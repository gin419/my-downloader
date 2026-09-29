# Changelog

All notable changes to XDownloader are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Entries before _Unreleased_ were back-filled from git history.

## [Unreleased]

### Changed
- **Posts of two or more files now get their own folder.** This covers X,
  Instagram and Threads posts with several pictures, or pictures and one
  video, and every Threads post of two or more files. X and Instagram
  posts with several videos, playlists and Reddit galleries still save
  their files loose. An Instagram profile's files go into a folder
  named after the account. Files downloaded before this change are not
  moved.

## [1.12.2] — 2026-09-28

### Added
- **Instagram profiles** — paste a link to an Instagram profile (or its
  posts or reels tab) and the account's newest posts download, reels
  included: 100 by default, set under Settings → Instagram Profiles
  (1 to 1000). The number counts posts, so a carousel is one post however
  many pictures it holds. The row reads "<username> - newest <N> posts",
  its progress bar follows the posts reached, and the Image and Video
  chips count the files as they arrive. Files already saved are skipped,
  so pasting the same profile again later only fetches what is missing.
  The download runs gallery-dl with your browser login and gallery-dl's
  own pause between requests; yt-dlp is not used. One profile downloads
  at a time whatever the concurrency setting — other profile links wait
  as "Queued" and can be removed while they wait — and single posts and
  other sites are not held up.

### Changed
- **Instagram links that are still turned down** — tagged, saved and
  highlights tabs, saved collections, hashtag, explore, location and audio
  pages, a stories link without a story id, and the site's own pages. The
  message now says the link isn't a single post, reel, story or profile,
  and asks for one of those instead.

## [1.12.1] — 2026-09-28

### Changed
- **Sample pictures** — when a page offers free sample pictures, they are
  now downloaded along with its preview, or on their own when there is no
  preview.

## [1.12.0] — 2026-09-28

### Added
- **Threads** — paste a link to a public Threads post (threads.com or
  threads.net) and its photos and videos download: single images, videos,
  and multi-item posts in their original order. The app reads the post
  itself, so no extra tool is involved and yt-dlp is skipped for these
  links. Files are named like X downloads —
  `<author> - <text> [<post code>]`, numbered for multi-file posts — and
  files already in the folder are not fetched again. The row shows a live
  progress bar with size and speed. A post with no media of its own that
  quotes or reposts another post downloads that post's media, named after
  its original author.
- **Threads failures say what happened** — a profile or search link is
  turned down (the app never downloads a whole account), and a deleted
  post, a post without photo or video, and a post Threads only shows to
  signed-in visitors each get their own message.
- **Threads posts that need sign-in** — every Threads download starts
  logged out. Only when Threads answers that the post is limited to
  signed-in visitors does the app try a second time with the login of the
  browser (or cookies.txt) chosen in Settings → Cookies: one signed-in
  try, never repeated automatically, asked at the post's own address so
  that Threads answers it with a single page request. A short link
  (`/t/…`) that Threads doesn't resolve to the post's address is not tried
  with the login; the message asks for the full link instead. yt-dlp makes
  the request and hands the page back, so XDownloader never holds cookie
  contents and, with a browser as the source, no cookie file is written
  (a cookies.txt chosen in Settings is updated by yt-dlp, as it is for
  every other site); the photos and videos themselves are fetched without
  cookies. Threads needs its own sign-in at threads.com — an Instagram
  sign-in alone is not enough — and the message says so when it is
  missing. Public posts never use the login and still need no tool.
  Signed-in requests go out one at a time with a pause of about three
  seconds between them, whatever the concurrency setting: several
  restricted links pasted together wait their turn as "Queued" and can be
  removed while they wait. Public posts and other sites are not held up.

### Changed
- **Instagram links must name a single post, reel or story** — a profile,
  a profile tab, a hashtag or explore page, an audio page, a highlights
  link or a stories link without a story id used to be handed to the
  download tools, which could fetch everything the link named — a whole
  account or a whole page of posts — with your browser login. Such a link
  now fails at once with a message asking for the single post's own link;
  no tool is started and nothing is requested from Instagram. A story
  shared out of a highlight (an `/s/…` link) is turned down as well.
- **Share-link cleanup** — Threads share parameters (`xmt`, `slof`) are
  stripped like the other tracking parameters, so a shared link is
  recognised as the same post as its plain link.

### Fixed
- **A percent sign in a file name no longer reads as a failure** — when
  the saved file's name contained `%`, yt-dlp's line naming the file was
  mistaken for a progress line, so the path was lost and a download that
  had finished was shown as having found nothing.

## [1.11.0] — 2026-08-17

### Added
- **Homebrew-optional tool setup** — first-run no longer requires brew.sh.
  When Homebrew is missing, Set Up can install and update yt-dlp, gallery-dl,
  ffmpeg, and deno from official standalone downloads into Application
  Support. Homebrew stays the default installer when it is already on the
  machine; pipx / MacPorts / `~/.local` copies are never overwritten.
- **Two-step confirmation** — Set Up now opens a wizard: pick which tools
  to act on and which installer (Homebrew or standalone), then review the
  plan (action, destination, current version, official source, rollback
  notice). Nothing is downloaded or brew-installed until **Confirm and
  start**.
- **Transactional rollback** — a failed confirmed run restores the previous
  binaries (or deletes files this run created) and cleans leftover
  `.partial` / `.pre-repair` staging. The sheet says the previous tools
  were restored; it never claims "All done" after a rolled-back failure.

## [1.10.0] — 2026-08-16

### Added
- **Tool health ("Honest Toolbox")** — the app now probes the versions of yt-dlp,
  gallery-dl, ffmpeg, and deno at launch and on return to the app: an amber
  banner flags outdated tools (a yt-dlp older than ~90 days, or anything
  Homebrew's index says is behind), red flags missing or broken ones, and the
  Set Up sheet became a per-tool health table whose one button installs the
  missing and updates the outdated in a single run. deno is now a first-class
  requirement (yt-dlp needs it as its JavaScript runtime for YouTube). The
  banner and the download engine resolve tools through one shared path list,
  so "looks healthy" and "actually runs" can never disagree (#60).
- **Rate-limit waits are visible** — while gallery-dl sleeps through an X rate
  limit or CDN backoff, the row shows "rate limited — resuming in …" instead of
  looking hung (#58, #60).

### Changed
- **Failure messages tell the truth** — an audit of every user-facing error
  across yt-dlp, gallery-dl, Likes sync, and the fxtwitter fallback rewrote the
  misleading ones. Highlights: a yt-dlp too old for current YouTube now says
  "update it (brew upgrade yt-dlp)" instead of "usually a brief YouTube hiccup,
  click Retry" — and a missing deno gets its own guidance (#57); private,
  age-restricted, and members-only videos, YouTube bot checks, unreadable
  browser cookies, protected and NSFW posts, Instagram security checks,
  unsupported URLs, and bare gallery-dl exit codes all map to plain language
  naming the fix in Settings instead of raw tool output (#58); in Likes sync, a
  stale gallery-dl no longer masquerades as "verify your login" or "the post may
  be deleted" — outdated-tool failures now say exactly that (#64).
- **Partial results are reported honestly** — a multi-file post where one file
  fails now says "Saved N files — Retry fetches the rest" instead of a bare
  failure that hides the files already on disk; a full or unwritable download
  folder is told apart from problems with the post itself (#63).

### Fixed
- **Green "Done" on a silent video** — with ffmpeg missing, yt-dlp downloads
  video and audio as separate unmerged files and still reports success; the row
  showed Done while "Open" revealed the audio file. It now fails truthfully with
  install guidance, and Retry after installing ffmpeg completes the merge (#59).
- **cookies.txt silent degradation** — a moved, deleted, or unwritable
  cookies.txt no longer fails an otherwise-successful download with a raw
  Python traceback, and the app says so once instead of silently falling back
  to browser cookies while later errors advise exporting the cookies.txt you
  already had (#61).
- **Likes sync sticky states** — one failed run no longer shows "needs
  attention" forever across later flawless syncs; a rate-limit wait during a
  successful sync is no longer recorded as a failure; Settings "Verify" and
  "Up to date — no new media." are only claimed when likes were actually
  visible to the selected session (#62).
- **Likes event counting** — the app parsed gallery-dl's `--Print` event lines
  with a prefix the real tool never emits, so synced tweets were never counted;
  real runs now count correctly (#64).
- The fxtwitter fallback no longer saves a CDN 404 error page as if it were a
  media file (#63).

## [1.9.3] — 2026-08-16

### Fixed
- **Universal binaries — Intel Macs can run releases again** — published builds
  were arm64-only because CI's `swift build -c release` compiled only the Apple
  Silicon runner's host architecture, so the app could not launch on Intel Macs
  at all. Release builds (CI and `./build.sh release`) are now universal
  (arm64 + x86_64), and CI fails any bundle whose app binary or embedded Sparkle
  framework is missing either slice. The macOS 14.0 support floor is unchanged.

## [1.9.2] — 2026-08-09

### Fixed
- **Likes verification false failure** — successful Chrome/Edge cookie extraction messages are no longer misclassified as authentication errors. A valid selected browser profile can now verify and sync without requiring a plaintext `cookies.txt` export.

## [1.9.1] — 2026-08-09

### Fixed
- **Authenticated browser-profile selection** — Chrome and Edge users can now choose the exact browser profile containing their X session. Likes verification, Likes sync, and ordinary downloads pass that profile directly to gallery-dl or yt-dlp, avoiding the unsafe plaintext `cookies.txt` workaround when automatic profile selection chooses an unauthenticated profile.

## [1.9.0] — 2026-08-09

### Added
- **X/Twitter Likes media sync** — configure one `@handle`, reuse the selected browser session or `cookies.txt`, and manually sync every accessible image, video, and GIF from the account's Likes. Each sync is one aggregate task with durable counts and an expandable failure list; a per-account gallery-dl archive skips media already saved on earlier runs while failed and newly liked posts remain retryable.

### Changed
- Likes sync keeps its own SQLite state and download archive, separate from the ordinary URL queue and download history. Cancelling or restarting never rolls back completed files, and unliking or losing access to a post never deletes local media.

## [1.8.0] — 2026-07-25

### Added
- **Developer ID signing + notarization** — release builds are now code-signed with an Apple Developer ID and notarized (and stapled) by Apple, so the app opens with a normal double-click instead of the old right-click → **Open** Gatekeeper workaround. The build runs under the hardened runtime; Sparkle's nested helpers (XPC services, Autoupdate, Updater.app, the framework) are re-signed under the same team, so library validation stays on (no `disable-library-validation`). Signing and notarization run in CI on tag push via `scripts/sign-notarize.sh`; the notarized, stapled zip is the exact artifact published to the GitHub Release and EdDSA-signed into the appcast, so auto-update delivers the notarized build. A local `./build.sh` does a full Developer ID sign when a cert is present and falls back to an ad-hoc signature otherwise.

## [1.7.0] — 2026-07-24

### Added
- **Auto-update (Sparkle 2)** — the app keeps itself up to date: a daily background check against GitHub Releases, Sparkle's standard update window (Install / Remind Me Later / Skip This Version) with the release notes linked in, an "Updates" section in Settings (current version, Check Now, automatic-check toggle), and a quiet "Update Available" menu bar row that exists only while an update is pending. Updates are EdDSA-signed in CI and served from a cumulative appcast on GitHub Pages, so the newest version is always advertised regardless of release order. Development builds (0.0.0 sentinel or bare `swift run`) disable checking entirely (#48, #49).

### Changed
- `CFBundleVersion` now derives from the release tag (`MAJOR*10000 + MINOR*100 + PATCH`, e.g. 1.7.0 → 10700) instead of the git commit distance, which collapsed to "1" on every exact-tag CI build. Sparkle compares this number to decide whether an update is newer, so it must rise monotonically across releases (#48).

## [1.6.0] — 2026-07-23

### Added
- **Instagram support** — Reels, video posts, and multi-video carousels download via yt-dlp with your browser cookies; image and mixed carousel posts fall back to gallery-dl automatically. Instagram's `igsh` and `igshid` share-link tracking params are stripped so shared links dedup (#44).
- **`xdownloader://` URL scheme** — `xdownloader://download?url=…` (repeatable, `urls=` alias) queues links for Shortcuts, Raycast, and scripts; success is quiet and background, and the window is raised only for outcomes that need attention. No clipboard verb by design — webpages can fire scheme URLs (#40).
- **Import from file** — File → Import Links… (⌘O) reads a plain-text file and queues every link in it through the capture flow (#40).
- **Menu bar extra** — a status item with a live count of unfinished downloads ("9+" capped) and a warning triangle for failures that happened while the app was in the background; its menu offers Paste and Download, an activity summary with aggregate speed, up to five live progress rows, "Retry All Failed", and quick access to the window and Settings. Hide it in Settings or by ⌘-dragging the icon out (#39).
- **Quiet Funnel main window** — hero "Paste & Download" button reads the clipboard and downloads in one click; with text in the URL field the same slot morphs to "Download" (#36).
- **Status-line feedback** — a fixed line under the capture row answers every capture ("Queued 3 links", "No link found in the clipboard", "Already in your list" with scroll-and-pulse) without shifting the layout; a macOS 15.4+ clipboard-permission denial is called out with a System Settings shortcut (#36).
- **Cancel on every row** — queued and in-progress downloads can be removed with their ✕, and cancelling genuinely stops the download: no fallback resurrection, no history entry (#36).

### Changed
- The main window is single-instance: the menu bar and Dock always raise the same window instead of spawning a second queue view (#39).
- **The paste button always downloads** — the "Auto-download on paste" setting is removed; the button label is the behavior. The review-first flow remains: click the field, ⌘V, Enter (#36).
- A batch containing several already-downloaded links asks once ("Download All Again / Skip All") instead of once per link (#36).
- Rows are more compact: the URL appears once per row, media counts moved into the chip's tooltip, and "Stop" is renamed "Pause" (#36).
- Notification permission is requested at the first finished download (chained into delivery) instead of the first enqueue, keeping it clear of the clipboard consent prompt (#36).
- Link hygiene: wrapping punctuation is trimmed from pasted links, a lone bare `x.com/…` works without `https://`, and `t` joined the tracking-param strip list so x.com share links dedup (#36).

### Fixed
- Progress bars expose their value to VoiceOver, and the mouse cursor no longer sticks as a pointing hand when a hovered row is removed (#36).
- Re-adding a link whose file already exists on disk completes again instead of failing with "yt-dlp reported success but found no media to download" — yt-dlp's "has already been downloaded" skip line now counts as the download's output (#43).
- Media counts now reflect final deliverables: pre-merge yt-dlp streams (e.g. Twitter HLS video + audio both as `.mp4`) no longer inflate `Video · N` — only the merged file (or each real playlist entry) is counted, and titles no longer keep intermediate format codes like `.fhls-230`.
- Twitter downloads flow through yt-dlp again (with live progress): the filename template's nested playlist-index form has never been valid on yt-dlp's template engine — every tweet crashed filename preparation and was silently served by the gallery-dl fallback instead. Filenames no longer double the author name, and the photos of mixed video+photo posts (Twitter and Instagram) are still collected by a follow-up gallery-dl pass (#45).

## [1.5.0] — 2026-07-02

### Added
- **Finish notifications** — a macOS notification announces a completed or failed download while the app is in the background (#35).
- **Batch input** — paste, drop, or ⌘D text containing any number of links and they all queue at once; multiple "already downloaded" warnings are shown one after another (#35).
- **cookies.txt file support** — point Settings at an exported `cookies.txt` for stubborn authenticated content (e.g. X sensitive/NSFW media); it takes precedence over the cookie-browser setting and is accessed under a sandbox security-scoped bookmark (#13).
- Test suite — a `XDownloaderTests` target run on CI (#16, #18).
- App-icon generator tracked at `scripts/make_icon.swift`, so the icon is reproducible from source (#17).

### Changed
- Relicensed **MIT → AGPL-3.0** (copyleft) (#15).
- Repository restructure: gitleaks config under `.github/gitleaks/`, docs under `docs/`, build output to a gitignored `build/` (#16).
- Internal hardening wave (#19–#31): back-filled CHANGELOG, version single-sourced from the git tag, swift-format + test + bundle-smoke CI gates, and `DownloadManager` decomposed into `QueueStore`/`CookieAccessManager`/`SettingsStore` services.

### Fixed
- The **⌘D "Paste and Download"** menu command was wired to nothing and had never worked; it now pastes and downloads immediately (#33).
- FxTwitter fallback no longer strands temp files when the move to the download folder fails (#33).
- CI Security Scan false positive: gitleaks' community rules self-matched their own literal patterns in the repo's history (#32).
- Media-extension classification: the image/video extension lists had drifted apart across services — yt-dlp's image check omitted `gif`/`avif`, and gallery-dl's known-media set omitted `mkv`/`m4v` (a dead branch). Unified into `MediaExtensions` (#18).

## [1.4.2] — 2026-06-22

### Changed
- `SiteProfile`/`SiteRegistry` are now the single source of truth for per-site behavior, with per-site argument construction (Phases 1–3) (#10, #11, #12).

### Fixed
- Twitter large-file download timeout (#12).

## [1.4.1] — 2026-06-22

### Fixed
- YouTube Shorts: survive a subtitle HTTP 429 instead of aborting the whole download, and match saved-file titles (#9).

## [1.4.0] — 2026-06-13

### Fixed
- Recover tweet media that was silently skipped, with an fxtwitter CDN fallback for hidden/spam-flagged tweets (#8).
- Handle "empty-success" Twitter downloads (exit 0 with no media) (#7).

## [1.3.1] — 2026-06-01

### Fixed
- Harden the yt-dlp format selector with a `bv*+ba/b` catch-all (#4).
- Align the `Info.plist` version and auto-stamp local builds from the git tag (#3).

### Changed
- Rewrote the README as a landing page with screenshots (#6).

## [1.3.0] — 2026-06-01

### Added
- SQLite download history with cross-session de-duplication (#2).

## [1.2] — 2026-06-01

### Added
- Status filter bar and Stop/Resume for in-progress downloads (#1).
- Persist the download queue across launches; centralize site routing.

### Fixed
- Include the Homebrew `PATH` when launching yt-dlp/gallery-dl (so `ffmpeg`/`deno` resolve).

## [1.0.1] — 2026-05-29

### Added
- Duplicate-download guard, multi-video tweet support, and the media-category chip.

### Fixed
- Set `mediaCategory` across all gallery-dl download paths.
- Renamed the "Single File" format label to "Video Only".

## [1.1] — 2026-05-28

### Added
- Automated GitHub release workflow; made the security scan a reusable workflow.

## [1.0] — 2026-05-28

### Added
- Initial release — a native macOS (SwiftUI) downloader for X/Twitter and YouTube, driving `yt-dlp` and `gallery-dl`.
