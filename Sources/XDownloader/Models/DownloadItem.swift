import Foundation
import SwiftUI

enum MediaCategory: String, Equatable, Codable {
    case image
    case video
    case audio
    case mixed  // image + video in the same tweet
    case unknown

    var icon: String {
        switch self {
        case .image: return "🖼️"
        case .video: return "🎬"
        case .audio: return "🎵"
        case .mixed: return "🖼️🎬"
        case .unknown: return "?"
        }
    }

    var label: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .mixed: return "Mixed"
        case .unknown: return "?"
        }
    }

    var color: Color {
        switch self {
        case .image: return .purple
        case .video: return .blue
        case .audio: return .orange
        case .mixed: return .indigo
        case .unknown: return .secondary
        }
    }
}

enum DownloadStatus: Equatable, Codable {
    case queued
    case fetching
    case downloading
    case paused
    case completed
    case failed(String)

    private enum CodingKeys: String, CodingKey { case kind, message }
    private enum Kind: String, Codable { case queued, fetching, downloading, paused, completed, failed }

    /// Substituted when a persisted failed status decodes with a missing or
    /// empty message — without it the row renders as a blank red row after
    /// relaunch, with nothing to explain the state.
    static let decodedFailureFallbackMessage =
        "Download failed before a reason was recorded — Retry."

    /// Internal control-flow marker set by YtDlpService when yt-dlp follows a
    /// link out of a tweet: it drives the fallback chain and is replaced with
    /// `externalRedirectMessage` before it can reach a renderer. One shared
    /// constant — every site that sets or compares it must use this.
    static let externalRedirectSentinel = "external_redirect"

    /// User-facing copy replacing the sentinel. Nonisolated home so the
    /// Codable decode path below can also substitute it (the detected URL is
    /// transient, so a decode-time substitution has no host to name).
    static func externalRedirectMessage(detectedURL: String?) -> String {
        if let detectedURL, let host = URL(string: detectedURL)?.host {
            return "This tweet links to external content (\(host)) — paste that link directly to download it."
        }
        return "This tweet links to external content — paste that link directly to download it."
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .queued, .fetching, .downloading: self = .queued
        case .paused: self = .paused
        case .completed: self = .completed
        case .failed:
            let m = (try? c.decode(String.self, forKey: .message)) ?? ""
            if m.isEmpty {
                self = .failed(Self.decodedFailureFallbackMessage)
            } else if m == Self.externalRedirectSentinel {
                // A quit mid-fallback can persist the internal sentinel —
                // without this, relaunch shows a blank red row.
                self = .failed(Self.externalRedirectMessage(detectedURL: nil))
            } else {
                self = .failed(m)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued: try c.encode(Kind.queued, forKey: .kind)
        case .fetching: try c.encode(Kind.fetching, forKey: .kind)
        case .downloading: try c.encode(Kind.downloading, forKey: .kind)
        case .paused: try c.encode(Kind.paused, forKey: .kind)
        case .completed: try c.encode(Kind.completed, forKey: .kind)
        case .failed(let m):
            try c.encode(Kind.failed, forKey: .kind)
            try c.encode(m, forKey: .message)
        }
    }

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .fetching: return "Fetching info..."
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .queued: return .secondary
        case .fetching: return .orange
        case .downloading: return .blue
        case .paused: return .yellow
        case .completed: return .green
        case .failed: return .red
        }
    }
}

/// Why YouTube formats went missing this attempt, recorded from yt-dlp
/// WARNING-line evidence: a yt-dlp build too old for current YouTube
/// (signature/nsig extraction failed, only images offered) or a missing
/// JavaScript runtime.
enum ExtractorBreakage {
    case none
    case staleTool
    case missingJSRuntime
}

@MainActor
class DownloadItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: String
    let addedAt: Date

    @Published var title: String?
    @Published var progress: Double = 0
    @Published var status: DownloadStatus = .queued
    @Published var speed: String?
    @Published var eta: String?
    @Published var totalSize: String?
    @Published var outputPath: String?
    @Published var videoPath: String?
    @Published var audioPath: String?
    @Published var imageCount: Int?
    @Published var videoCount: Int?
    @Published var mediaCategory: MediaCategory = .unknown
    /// In-memory only (NOT persisted). True once the auto-retry for an
    /// "empty success" — yt-dlp/gallery-dl exit 0 with no media — has fired
    /// for this item. Prevents infinite retry loops for tweets that are
    /// genuinely unreachable.
    var autoRetryAttempted: Bool = false
    /// In-memory only (NOT persisted). Most recent diagnostic line the
    /// downloader printed for this attempt — a "[warning]" or the "No results"
    /// info line — used to explain empty-success failures (age-restricted,
    /// media unavailable, tweet temporarily limited, …) instead of guessing.
    var lastToolWarning: String?
    /// In-memory only (NOT persisted). Set by YtDlpService.parseLine when a
    /// "Unable to download video subtitles" line appears — YouTube heavily
    /// rate-limits (HTTP 429) its subtitle endpoint, and yt-dlp aborts the
    /// whole item on that error before the video is saved. Signals
    /// DownloadManager to retry the video with subtitles disabled.
    var subtitleDownloadFailed: Bool = false
    /// In-memory only (NOT persisted). True once we've re-run this item with
    /// subtitles forced off. Tells buildArguments to skip subtitle flags and
    /// guards against an infinite subtitle-retry loop.
    var subtitlesDisabled: Bool = false
    /// In-memory only (NOT persisted). Set by YtDlpService.parseLine from
    /// WARNING-line evidence; consumed when "Requested format is not
    /// available" fires to name the real cause (stale yt-dlp / missing JS
    /// runtime) instead of claiming a transient hiccup. Cleared with the
    /// other per-attempt parse state in resetForReattempt(); deliberately
    /// kept across the subtitles-disabled re-run — the same binary re-runs,
    /// so the same WARNINGs re-fire anyway.
    var extractorBreakage: ExtractorBreakage = .none
    /// In-memory only (NOT persisted). Set by YtDlpService.parseLine when
    /// yt-dlp warns that a merge-requiring format selection ran with no
    /// ffmpeg installed — it then writes the streams separately (video-only
    /// + audio-only files) and still exits 0, so without this flag the run
    /// reads as success while the user's "video" plays silent. Consumed by
    /// DownloadManager's success-branch guard; cleared with the other
    /// per-attempt parse state in resetForReattempt().
    var ffmpegMissingForMerge: Bool = false
    /// In-memory only (NOT persisted). The off-site URL yt-dlp was following
    /// when the external-redirect sentinel fired — lets DownloadManager name
    /// the destination host in the final user-facing failure message.
    /// Deliberately NOT cleared in resetForReattempt(): it must survive the
    /// gallery-dl fallback and auto-retry resets within one attempt so the
    /// final message can name the destination. Cleared by retryItem() with
    /// the other cross-attempt flags.
    var externalRedirectURL: String?

    init(url: String, addedAt: Date = Date()) {
        self.url = url
        self.addedAt = addedAt
    }

    /// Re-derive `mediaCategory` from the current image/video counts. Audio is
    /// set explicitly elsewhere, so this only handles the image / video / mixed case.
    func recomputeMediaCategory() {
        let hasImg = (imageCount ?? 0) > 0
        let hasVid = (videoCount ?? 0) > 0
        if hasImg && hasVid { mediaCategory = .mixed } else if hasImg { mediaCategory = .image } else if hasVid { mediaCategory = .video }
    }

    /// Clear all per-attempt media-result state so a re-run starts fresh. Keeps
    /// url/addedAt and the retry/subtitle flags; callers set `status` as needed.
    func resetForReattempt() {
        progress = 0
        speed = nil
        eta = nil
        totalSize = nil
        outputPath = nil
        videoPath = nil
        audioPath = nil
        title = nil
        imageCount = nil
        videoCount = nil
        mediaCategory = .unknown
        lastToolWarning = nil
        extractorBreakage = .none
        ffmpegMissingForMerge = false
    }

    /// Mark this item finished: completed status, full progress, no live speed/eta.
    func markCompleted() {
        status = .completed
        progress = 1.0
        speed = nil
        eta = nil
    }

    init(persisted p: PersistedDownloadItem) {
        self.url = p.url
        self.addedAt = p.addedAt
        self.title = p.title
        self.progress = p.progress
        self.status = p.status
        self.totalSize = p.totalSize
        self.outputPath = p.outputPath
        self.videoPath = p.videoPath
        self.audioPath = p.audioPath
        self.imageCount = p.imageCount
        self.videoCount = p.videoCount
        self.mediaCategory = p.mediaCategory
    }

    func toPersisted() -> PersistedDownloadItem {
        let persistedProgress: Double = {
            switch status {
            case .completed: return 1.0
            case .paused: return progress
            default: return 0.0
            }
        }()
        return PersistedDownloadItem(
            url: url,
            addedAt: addedAt,
            title: title,
            progress: persistedProgress,
            status: status,
            totalSize: totalSize,
            outputPath: outputPath,
            videoPath: videoPath,
            audioPath: audioPath,
            imageCount: imageCount,
            videoCount: videoCount,
            mediaCategory: mediaCategory
        )
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return url
    }

    /// Parses yt-dlp's totalSize strings ("15.42MiB", "120.5MB", "1.2GiB", "850KiB"…) into bytes.
    var totalBytes: Int64? {
        guard let raw = totalSize else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            m.numberOfRanges == 3,
            let numRange = Range(m.range(at: 1), in: s),
            let unitRange = Range(m.range(at: 2), in: s),
            let value = Double(s[numRange])
        else { return nil }
        let unit = s[unitRange].uppercased()
        let multiplier: Double
        switch unit {
        case "B": multiplier = 1
        case "KB": multiplier = 1_000
        case "KIB": multiplier = 1_024
        case "MB": multiplier = 1_000_000
        case "MIB": multiplier = 1_048_576
        case "GB": multiplier = 1_000_000_000
        case "GIB": multiplier = 1_073_741_824
        case "TB": multiplier = 1_000_000_000_000
        case "TIB": multiplier = 1_099_511_627_776
        default: return nil
        }
        let bytes = value * multiplier
        guard bytes.isFinite, bytes >= 0 else { return nil }
        return Int64(exactly: bytes.rounded())
    }

    /// True when total size is known and ≥ 100 MB — gates the Stop/Resume controls.
    var isLargeDownload: Bool {
        (totalBytes ?? 0) >= 100 * 1024 * 1024
    }
}

struct PersistedDownloadItem: Codable {
    let url: String
    let addedAt: Date
    let title: String?
    let progress: Double
    let status: DownloadStatus
    let totalSize: String?
    let outputPath: String?
    let videoPath: String?
    let audioPath: String?
    let imageCount: Int?
    let videoCount: Int?
    let mediaCategory: MediaCategory
}
