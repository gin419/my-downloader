# Changelog

All notable changes to XDownloader are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Entries before _Unreleased_ were back-filled from git history.

## [Unreleased]

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
