# XDownloader — Feature List

## URL Input
- **Paste & Download** button — one click reads the clipboard and downloads its links; with text in the URL field, the same button reads "Download" and downloads that instead (the label always says what the click does)
- **Type a URL** — type or paste into the input field and press Enter to review before downloading
- **Batch input** — text with any number of links (one per line, or mixed with prose) queues them all at once; works via paste, drop, and ⌘D
- **Drag & drop** — drag a URL from any app directly onto the window
- **`⌘D` shortcut** — "Paste and Download" from the menu bar
- **Import from file (`⌘O`)** — File → Import Links… reads a plain-text file (one link per line, or mixed with prose) and queues everything through the same capture flow
- **`xdownloader://` URL scheme** — for Shortcuts, Raycast, and scripts: `xdownloader://download?url=<percent-encoded link>` (repeat `url=` for batches, `urls=` works too); queues quietly in the background and only raises the window when something needs attention. There is deliberately no clipboard verb — webpages can fire scheme URLs, and clipboard reads stay tied to in-app gestures
- **Status line feedback** — every capture answers in place ("Queued 3 links", "No link found in the clipboard", "Already in your list — highlighted below") without shifting the layout; on macOS 15.4+ a denied clipboard permission is called out with a System Settings shortcut
- **Link cleanup** — wrapping punctuation is trimmed from pasted links, and a bare `x.com/…` link works without typing `https://`

## Menu Bar
- **Live status item** — download-arrow icon with a live count of unfinished downloads (capped at "9+"); a small warning triangle appears when a download fails while the app is in the background
- **Status menu** — Paste and Download, an activity summary ("2 downloading · 3 queued · 4.2 MB/s"), up to five live item rows with progress badges, paused and failed summaries with "Retry All Failed", plus Open / Settings… / Quit
- **Optional** — hide it via "Show XDownloader in menu bar" in Settings, or ⌘-drag the icon out of the menu bar

## Notifications
- **Finish notifications** — when the app is in the background, a macOS notification announces each completed or failed download (delivery is controlled per-app in System Settings → Notifications)

## Download Engine
- **X.com / Twitter Likes sync** — enter one `@handle` and manually sync all accessible native media from that account's Likes using the selected browser session or `cookies.txt`; later scans skip archived media and download only new or previously failed items
- **Durable sync summary** — Likes appears as one aggregate task with downloaded, skipped, no-media, failed, and ignored counts; failures can be expanded, copied, opened, retried, or ignored without filling the normal queue with thousands of rows
- **X.com / Twitter videos** — downloaded via yt-dlp using your browser's session cookies
- **X.com / Twitter images** — automatic fallback to gallery-dl when yt-dlp finds no video; supports multi-image tweets
- **Mixed video+photo posts** — after the video downloads, a follow-up gallery-dl pass collects the post's photos (X and Instagram)
- **Instagram** — Reels, video posts, and multi-video carousels via yt-dlp; image and mixed carousel posts via the gallery-dl fallback; requires being logged in to Instagram in the cookie-source browser
- **YouTube & general URLs** — any URL supported by yt-dlp works
- **Smart fallback** — detects when yt-dlp follows an external link out of a tweet and hands off to gallery-dl instead
- **Tracking parameter stripping** — removes `utm_*`, `?si=`, `?s=`, `&t=`, `&ref=`, `fbclid`, `gclid`, etc. before downloading
- **Concurrent downloads** — up to 5 simultaneous downloads (configurable in Settings)

## Download Formats
- **Video + Audio** — best quality MP4 with separate video and audio streams merged (default)
- **Video Only** — best pre-muxed MP4 that needs no merging step
- **Audio Only** — extracts audio as MP3 at highest quality

## Subtitles (YouTube)
- Subtitle language picker: English, Chinese (Traditional/Simplified), Japanese, Korean, Spanish, French
- **Embed** subtitles into the video file, or save as a sidecar `.srt`/`.vtt` file

## Download List UI
- **Live progress bar** with speed, ETA, and file size (progress is also read out to VoiceOver)
- **Status badges** — Queued / Fetching / Downloading / Done / Failed
- **Compact rows** — the URL appears once per row (folded into the meta line when the item has a title), and media counts live in the chip's tooltip
- **Click title to open** the downloaded file directly
- **Show in Finder** — reveals the file in Finder on completion
- **Retry** — re-queues a failed download
- **Copy Link** — copies the original URL to clipboard on failure
- **Cancel (✕) on every row** — including queued and in-progress items, so a mis-pasted batch is one click each to undo
- **Clear Done** — removes all completed items at once
- **Animated transitions** — rows slide in and fade out

## Download Control
- **Pause / Resume** — pause a running download and resume it on demand
- **Cancel** — remove an in-progress download outright with its row's ✕

## History & Deduplication
- **Cross-session history** — completed downloads are recorded in a local SQLite store
- **Duplicate detection** — re-adding a URL you already downloaded prompts before downloading it again; a batch containing several already-downloaded links asks once ("Download All Again / Skip All") instead of once per link
- **History toggle** — turn database recording on or off in Settings, with a live count/size readout, "Reveal in Finder", and "Clear History"
- **Import task list** — back-fill the completed and failed items already in the task list into the history database (safe to run repeatedly)

## Settings
- **Download folder** — folder picker with "Open in Finder" shortcut (defaults to `~/Downloads/X-Videos`)
- **Cookie browser** — pick Safari, Chrome, Firefox, or Edge (or None) for authenticated downloads
- **Cookies file** — point at an exported `cookies.txt` for stubborn authenticated content (e.g. X sensitive/NSFW media); takes precedence over the cookie browser
- **X account** — one normalized `@handle` for manual Likes sync, verified against the selected cookie source; no password or cookie contents are stored by XDownloader
- **Download format** — Video+Audio / Single File / Audio Only
- **Subtitle language & embed toggle**
- **Max concurrent downloads** — stepper from 1–5
- **Show download date & time** per row
- **Open completed file as** — prefer Video or Audio when both exist
