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

## Shipped (current: v1.6.0)

All core features are live, pillars 1 and 2 have landed (v1.5 closed the
loop; v1.6 put the app within reach via the menu bar, `xdownloader://`, and
file import — plus Instagram support). See [FEATURES.md](FEATURES.md) for the
full list and [CHANGELOG.md](../CHANGELOG.md) for release history.

---

## v1.7 — Zero setup

- **Primed hero button** *(carried from v1.6; design signed off)* — when the
  window gains focus (e.g. hovered via a focus-follows-mouse utility such as
  [AutoRaise](https://github.com/sbmpost/AutoRaise)), the hero button primes
  itself with a fresh clipboard URL, so a single click — no paste, no Enter —
  starts the download
- **Self-managed tools** — install and update `yt-dlp`/`gallery-dl` from
  inside the app; Homebrew becomes optional
- **Signed & notarized releases** — no more right-click-Open on first launch
- **Auto-update** — the app checks for new releases and downloads and installs
  them itself (Sparkle-style), replacing the manual trip to the Releases page

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
