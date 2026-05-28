# XDownloader

A minimal macOS app for downloading videos and images from X.com, YouTube, and other sites supported by yt-dlp.

## Requirements

- macOS 14+
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — `brew install yt-dlp`
- [gallery-dl](https://github.com/mikf/gallery-dl) — `brew install gallery-dl` *(for X.com images)*
- [ffmpeg](https://ffmpeg.org) — `brew install ffmpeg` *(for merging video + audio streams)*

## Build & Run

```bash
# Build release app bundle (default)
./build.sh

# Build debug app bundle
./build.sh debug

# Run directly via SPM (no app bundle)
swift run
```

After `./build.sh`, open the resulting `XDownloader.app` or move it to `/Applications/`.

## Features

See [FEATURES.md](FEATURES.md).

## Roadmap

See [ROADMAP.md](ROADMAP.md).

## Project structure

```
Sources/XDownloader/
├── App/            Entry point (XDownloaderApp)
├── Models/         DownloadItem, enums (formats, languages, etc.)
├── Services/       ProcessRunner, YtDlpService, GalleryDlService
├── ViewModels/     DownloadManager (queue, settings, coordination)
└── Views/          ContentView, DownloadRowView, SettingsView
Resources/          Info.plist, AppIcon.icns
```
