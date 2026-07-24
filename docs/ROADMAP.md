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

## Shipped (current: v1.7.0)

All core features are live. Pillars 1 and 2 have landed (v1.5 closed the loop;
v1.6 put the app within reach via the menu bar, `xdownloader://`, and file
import — plus Instagram support), and pillar 3 is underway: **v1.7 shipped
auto-update** (Sparkle 2 — the app now checks, verifies, and installs new
releases itself). See [FEATURES.md](FEATURES.md) for the full list and
[CHANGELOG.md](../CHANGELOG.md) for release history.

---

## v1.7 — Zero setup

- **Auto-update** *(shipped v1.7.0)* — the app checks for, verifies (EdDSA), and
  installs new releases itself via Sparkle 2, replacing the manual trip to the
  Releases page. Feed is a cumulative appcast on GitHub Pages.
- **Signed & notarized releases** — no more right-click-Open on first launch;
  also gives updates a second trust anchor (Apple Developer ID alongside the
  Sparkle EdDSA signature) and unlocks Sparkle signing-key rotation
- **Primed hero button** *(carried from v1.6; design signed off)* — when the
  window gains focus (e.g. hovered via a focus-follows-mouse utility such as
  [AutoRaise](https://github.com/sbmpost/AutoRaise)), the hero button primes
  itself with a fresh clipboard URL, so a single click — no paste, no Enter —
  starts the download
- **Self-managed tools** — install and update `yt-dlp`/`gallery-dl` from
  inside the app; Homebrew becomes optional

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
