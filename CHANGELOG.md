# Changelog

All notable changes to XDownloader are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Entries before _Unreleased_ were back-filled from git history.

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
