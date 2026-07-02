# XDownloader — Roadmap

## The end state

XDownloader is done when you can hand it to someone who has never heard of
`yt-dlp` and they never notice it's there: a link goes in with one gesture —
paste, drag, share — and the file is in the folder. No Homebrew, no terminal,
no format questions. Everything below works backwards from that.

Four pillars, in the order they'll land:

1. **Close the loop** — the app tells you when it's done; many links queue as
   easily as one.
2. **Always within reach** — a URL never needs the main window: menu bar,
   automation hooks, zero-click capture.
3. **Zero setup** — the app manages its own downloader tools and updates
   itself; a signed bundle you download once.
4. **A library, not a log** — what you downloaded is browsable: thumbnails,
   preview, search, one-click re-download.

---

## Shipped (current: v1.4.2)

All core features are live. See [FEATURES.md](FEATURES.md) for the full list
and [CHANGELOG.md](../CHANGELOG.md) for release history.

---

## v1.5 — Close the loop

- **Finish notifications** — macOS notification when a download completes or
  fails while the app is in the background
- **Batch input** — paste text containing any number of URLs and queue them
  all at once (multi-line clipboard, whole "read later" lists)

## v1.6 — Always within reach

- **Menu bar presence** — live download count, paste-and-download without
  opening the main window
- **Zero-click download with AutoRaise** — when the window gains focus (e.g.
  via [AutoRaise](https://github.com/sbmpost/AutoRaise) hovering), auto-detect
  a fresh URL on the clipboard and start the download without any paste/Enter
  click. Goal: hover → done, no keyboard or mouse input.
- **URL scheme** — `xdownloader://` for Shortcuts, Raycast, and scripting
- **Import from file** — load a plain-text list of URLs and download them all

## v1.7 — Zero setup

- **Self-managed tools** — install and update `yt-dlp`/`gallery-dl` from
  inside the app; Homebrew becomes optional
- **Signed & notarized releases** — no more right-click-Open on first launch
- **Update check** — the app tells you when a new release is available

## v2.0 — A library, not a log

- **Thumbnails & in-app preview** for completed downloads
- **List density / view switcher** — compact vs. comfortable rows (and a gallery
  view) as a view control next to the filter bar, Finder-style — a view mode,
  not another Settings toggle
- **Per-download format override** — pick format/quality per URL, not globally
- **Search & re-download** across the full download history
- **Share Sheet / browser extension** — send URLs straight from Safari or
  Chrome
- **Localization** — 繁體中文 and English UI
