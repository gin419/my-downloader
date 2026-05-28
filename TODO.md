# XDownloader — Planned Features

## 1. Strip Privacy Info from URL
Remove tracking/referral query parameters (e.g. `?s=`, `&ref=`, `?si=`, `utm_*`) from a URL
before it is stored in `DownloadItem` and passed to yt-dlp / gallery-dl.

**Scope:** `DownloadManager.addDownload()` — sanitize the URL string before creating the item.

---

## 2. Retry Failed Downloads + Copy Link
On a failed `DownloadItem`, expose two actions in `DownloadRowView`:
- **Retry** — re-queue the item (reset status to `.queued`, push back into `downloadQueue`).
- **Copy Link** — write `item.url` to the clipboard.

**Scope:** `DownloadItem` (add `retryCount`), `DownloadManager` (add `retryItem(_:)`),
`DownloadRowView` (show buttons when `status == .failed`).

---

## 3. YouTube Audio / Video Format + Subtitle Language
Expose per-download (or global-default) options for YouTube:
- **Format** — Video (MP4 best), Audio only (M4A/MP3).
- **Subtitle language** — e.g. `en`, `zh-Hant`, `ja`; embed or write as `.srt`/`.vtt` sidecar.

**Scope:** new `YouTubeOptions` struct on `DownloadItem`; `DownloadManager.runDownload()`
builds `--format`, `--extract-audio`, `--write-sub`, `--sub-lang`, `--embed-subs` args
based on those options.

---

## 4. Configurable Default Download Location
Let the user pick a persistent download folder via a folder picker in `SettingsView`,
stored in `UserDefaults` (key `outputDirectory`).

**Note:** `DownloadManager` already reads/writes this key — the setting just needs a proper
UI control (currently a text path; upgrade to `NSOpenPanel` folder picker button).

**Scope:** `SettingsView` — replace or augment the existing path field with a "Choose…" button.
