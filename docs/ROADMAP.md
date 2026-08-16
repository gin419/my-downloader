# XDownloader — Roadmap

## The end state

XDownloader is done when you can hand it to someone who has never heard of
`yt-dlp` and they never notice it's there: a link goes in with one gesture —
paste, drag, share — and the file is in the folder. No Homebrew, no terminal,
no format questions. Everything below works backwards from that.

Four pillars, in the order they'll land:

1. **Close the loop** — *shipped v1.5* — the app tells you when it's done;
   many links queue as easily as one.
2. **Always within reach** — *shipped v1.6* — a URL never needs the main
   window: menu bar, automation hooks, zero-click capture.
3. **Zero setup** — *mostly shipped v1.7–v1.10* — the app updates itself and
   can install or upgrade its downloader tools from the UI. Homebrew is still
   the installer backend; a brew-free first launch is the remaining gap.
4. **A library, not a log** — *next* — what you downloaded is browsable:
   thumbnails, preview, search, one-click re-download.

See [FEATURES.md](FEATURES.md) for the live feature list and
[CHANGELOG.md](../CHANGELOG.md) for release history.

---

## Shipped (current: v1.10.0)

Compared with the last roadmap snapshot (which still said "current: v1.7.0"),
everything in pillars 1 and 2 is live, and pillar 3 is one step short of the
end-state wording ("no Homebrew"). Several items that were never on the
roadmap also shipped and are recorded below so this file stays the plan, not
a fossil.

### Pillar 1 — Close the loop (v1.5.0)

- **Finish notifications** — a macOS notification for each completed or
  failed download while the app is in the background.
- **Batch input** — paste, drop, or ⌘D text containing any number of links
  and they all queue at once.

### Pillar 2 — Always within reach (v1.6.0)

- **Menu bar extra** — live unfinished count (capped at "9+"), failure
  triangle, Paste and Download, activity summary, up to five live rows,
  Retry All Failed, Open / Settings / Quit. Optional: hide in Settings or
  ⌘-drag the icon out.
- **`xdownloader://` URL scheme** — `xdownloader://download?url=…` (repeat
  `url=`, or `urls=`) for Shortcuts, Raycast, and scripts. Quiet background
  queue; the window rises only when something needs attention. No clipboard
  verb — webpages can fire scheme URLs.
- **Import from file (`⌘O`)** — File → Import Links… reads a plain-text
  file through the same capture flow.
- **Quiet Funnel hero button** — one click reads the clipboard and
  downloads; with text in the field the same slot becomes **Download**.
  Status-line feedback answers every capture without shifting the layout.

Also landed in v1.6 (not originally pillar work): **Instagram** (Reels,
videos, carousels via yt-dlp; images / mixed posts via gallery-dl).

### Pillar 3 — Zero setup (v1.7.0 – v1.10.0)

- **Auto-update** *(shipped v1.7.0)* — Sparkle 2 daily background check
  against the cumulative GitHub Pages appcast. Standard update window
  (Install / Remind Me Later / Skip This Version). Settings → Updates has
  current version, Check Now, and an automatic-check toggle. A quiet
  "Update Available" menu bar row exists only while an update is pending.
  Updates are EdDSA-signed. Development builds (`0.0.0` or bare `swift run`)
  disable checking. Updates are never installed without a click.
- **Signed & notarized releases** *(shipped v1.8.0)* — Developer ID + Apple
  notarization (stapled). Double-click opens; no right-click → Open. Sparkle
  nested helpers are re-signed under the same team. The notarized zip is
  the exact GitHub Release artifact.
- **Universal binaries** *(shipped v1.9.3)* — arm64 + x86_64. Intel Macs
  run official releases again; CI fails a bundle missing either slice.
- **Honest Toolbox** *(shipped v1.10.0)* — this is the in-app half of
  "self-managed tools". At launch and on return to the app, it probes
  yt-dlp, gallery-dl, ffmpeg, and deno. Amber banner = outdated (yt-dlp
  older than ~90 days, or Homebrew's index says behind). Red = missing or
  broken. The Set Up sheet is a per-tool health table; one button installs
  the missing and upgrades the outdated via Homebrew. deno is a first-class
  requirement. Banner and download engine share one path list, so "looks
  healthy" and "actually runs" cannot disagree.

Homebrew is **not** optional yet. The app can drive `brew install` /
`brew upgrade` for you, and it will detect pipx / MacPorts copies without
trying to overwrite them — but a machine with no Homebrew still cannot
finish first-run setup from inside the app.

### Shipped off the original plan

These were not on the v1.7 / v2.0 lists. They are live and stay out of the
"next" column.

- **X / Twitter Likes sync** *(v1.9.0–v1.9.2)* — one `@handle`, reuse the
  selected browser session (or `cookies.txt`), manually sync accessible
  liked images / videos / GIFs. One aggregate task with durable counts and
  an expandable failure list. Chrome / Edge profile picker so the
  authenticated session is the one that actually runs.
- **Truthful outcomes** *(v1.10.0)* — failure copy names the real cause
  (stale tool, missing deno/ffmpeg, private / age-gated, cookies, Instagram
  checkpoint) instead of a generic hiccup. Partial multi-file posts say
  "Saved N files — Retry fetches the rest". Rate-limit sleeps show
  "resuming in …" instead of looking hung.

---

## Still open on pillar 3

- **Primed hero button** *(design signed off in the v1.6 cycle; not built)*
  — when the window gains focus (e.g. hovered via a focus-follows-mouse
  utility such as [AutoRaise](https://github.com/sbmpost/AutoRaise)), the
  hero button would prime itself with a fresh clipboard URL so a single
  click — no paste, no Enter — starts the download.

  Constraint: clipboard reads are deliberately gesture-only (Paste &
  Download, ⌘D, menu bar) and never run on a timer or focus change, so the
  macOS 15.4+ pasteboard-privacy prompt stays tied to a click the user just
  made. Any implementation has to keep that invariant — priming the *label*
  without a silent `NSPasteboard` read, or finding another consent-safe
  moment.

- **Homebrew-optional / bundled tools** — install and update yt-dlp /
  gallery-dl / ffmpeg / deno without requiring Homebrew on the machine.
  Until this lands, first-run still means "install brew, then let the app
  do the rest" (or install the tools some other way and point the health
  probe at them).

---

## v2.0 — A library, not a log

Nothing below has shipped. History is still a SQLite log with dedup, not a
browsable library.

- **Thumbnails & in-app preview** for completed downloads
- **List density / view switcher** — compact vs. comfortable rows (and a
  gallery view) as a view control next to the filter bar, Finder-style — a
  view mode, not another Settings toggle
- **Per-download format override** — pick format/quality per URL, not
  globally
- **Search & re-download** across the full download history
- **Share Sheet / browser extension** — send URLs straight from Safari or
  Chrome
- **Localization** — 繁體中文 and English UI
