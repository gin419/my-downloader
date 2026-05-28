# XDownloader v1.0 — Feature List

## URL Input
- **Paste URL** — type or paste any URL into the input field and press Enter or click Download
- **Paste from Clipboard** button — one-click grab from clipboard
- **Drag & drop** — drag a URL from any app directly onto the window
- **`⌘D` shortcut** — "Paste and Download" from the menu bar
- **Auto-download on paste** — optional setting to start downloading immediately on clipboard paste (no confirmation step)

## Download Engine
- **X.com / Twitter videos** — downloaded via yt-dlp using your browser's session cookies
- **X.com / Twitter images** — automatic fallback to gallery-dl when yt-dlp finds no video; supports multi-image tweets
- **YouTube & general URLs** — any URL supported by yt-dlp works
- **Smart fallback** — detects when yt-dlp follows an external link out of a tweet and hands off to gallery-dl instead
- **Tracking parameter stripping** — removes `utm_*`, `?si=`, `?s=`, `&ref=`, `fbclid`, `gclid`, etc. before downloading
- **Concurrent downloads** — up to 5 simultaneous downloads (configurable in Settings)

## Download Formats
- **Video + Audio** — best quality MP4 with separate video and audio streams merged (default)
- **Video Only** — best pre-muxed MP4 that needs no merging step
- **Audio Only** — extracts audio as MP3 at highest quality

## Subtitles (YouTube)
- Subtitle language picker: English, Chinese (Traditional/Simplified), Japanese, Korean, Spanish, French
- **Embed** subtitles into the video file, or save as a sidecar `.srt`/`.vtt` file

## Download List UI
- **Live progress bar** with speed, ETA, and file size
- **Status badges** — Queued / Fetching / Downloading / Done / Failed
- **Click title to open** the downloaded file directly
- **Show in Finder** — reveals the file in Finder on completion
- **Image count** — shows how many images were saved from a tweet
- **Retry** — re-queues a failed download
- **Copy Link** — copies the original URL to clipboard on failure
- **Remove** button on each row
- **Clear Done** — removes all completed items at once
- **Animated transitions** — rows slide in and fade out

## Settings
- **Download folder** — folder picker with "Open in Finder" shortcut (defaults to `~/Downloads/X-Videos`)
- **Cookie browser** — pick Safari, Chrome, Firefox, or Edge (or None) for authenticated downloads
- **Download format** — Video+Audio / Single File / Audio Only
- **Subtitle language & embed toggle**
- **Max concurrent downloads** — stepper from 1–5
- **Auto-download on paste** toggle
- **Show download date & time** per row
- **Open completed file as** — prefer Video or Audio when both exist
