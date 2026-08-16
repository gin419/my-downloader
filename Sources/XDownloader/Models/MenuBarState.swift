import Foundation

/// Snapshot of everything the menu bar extra renders — recomputed as a value
/// so the label and menu observe ONE `@Published` property instead of every
/// `DownloadItem` (which are their own ObservableObjects the scene would
/// otherwise never hear from).
struct MenuBarState: Equatable {
    struct Row: Equatable, Identifiable {
        enum Detail: Equatable {
            case downloading(percent: Int?)  // nil → progress unknown (no bar data)
            case fetching
            case queued
        }

        let id: UUID
        let title: String
        let detail: Detail
    }

    var downloadingCount = 0  // downloading + fetching
    var queuedCount = 0
    var pausedCount = 0
    var failedCount = 0
    /// Head of the newest failure's message, for the "⚠ N failed — …" row.
    var firstFailureMessage: String? = nil
    /// Sum of the parseable per-item speeds ("3.2 MB/s"); nil when nothing
    /// reports a usable speed.
    var aggregateSpeed: String? = nil
    var rows: [Row] = []
    /// Items beyond the visible rows ("N more…"). 0 when fully expanded.
    var overflowCount = 0
    /// Hysteresis memory: collapse at ≥6 unfinished, expand at ≤4, hold at 5.
    var isOverflowing = false
    /// Unseen-failure attention flag (shape in the label, never color).
    var showsAttention = false

    /// Paused excluded by design — paused work isn't "in flight".
    var unfinishedCount: Int { downloadingCount + queuedCount }

    /// Text shown next to the label icon; nil when idle (icon only).
    var countLabel: String? {
        guard unfinishedCount > 0 else { return nil }
        return unfinishedCount > 9 ? "9+" : "\(unfinishedCount)"
    }

    static let empty = MenuBarState()
    private static let likesRowID = UUID(uuidString: "4C494B45-532D-5359-4E43-000000000001")!

    /// Pure recompute. `wasOverflowing` carries the hysteresis memory from the
    /// previous state so the "N more…" row doesn't flap at the boundary.
    @MainActor
    static func compute(
        items: [DownloadItem],
        likesStatus: LikesSyncRunStatus = .idle,
        likesHandle: String? = nil,
        showsAttention: Bool,
        wasOverflowing: Bool
    ) -> MenuBarState {
        var state = MenuBarState()
        state.showsAttention = showsAttention

        var active: [Row] = []  // downloading/fetching first…
        var waiting: [Row] = []  // …then queued, both in list (newest-first) order
        var speedBytesPerSec = 0.0
        var sawSpeed = false

        for item in items {
            switch item.status {
            case .downloading:
                state.downloadingCount += 1
                // Progress-less rows (gallery-dl/fxtwitter) show no percent.
                let percent = item.progress > 0 ? Int((item.progress * 100).rounded()) : nil
                active.append(Row(id: item.id, title: item.displayTitle, detail: .downloading(percent: percent)))
                if let speed = item.speed, let bps = parseSpeed(speed) {
                    speedBytesPerSec += bps
                    sawSpeed = true
                }
            case .fetching:
                state.downloadingCount += 1
                active.append(Row(id: item.id, title: item.displayTitle, detail: .fetching))
            case .queued:
                state.queuedCount += 1
                waiting.append(Row(id: item.id, title: item.displayTitle, detail: .queued))
            case .paused:
                state.pausedCount += 1
            case .failed(let message):
                state.failedCount += 1
                if state.firstFailureMessage == nil, !message.isEmpty,
                    message != DownloadStatus.externalRedirectSentinel
                {
                    state.firstFailureMessage = message
                }
            case .completed:
                break
            }
        }

        if likesStatus.isActive {
            state.downloadingCount += 1
            active.append(
                Row(
                    id: likesRowID,
                    title: "X Likes Sync\(likesHandle.map { " · \($0)" } ?? "")",
                    detail: .fetching))
        } else if likesStatus.needsAttention {
            state.failedCount += 1
            if state.firstFailureMessage == nil {
                state.firstFailureMessage = "X Likes sync needs attention"
            }
        }

        if sawSpeed { state.aggregateSpeed = formatSpeed(bytesPerSecond: speedBytesPerSec) }

        let unfinishedRows = active + waiting
        // Hysteresis: ≥6 collapses, ≤4 expands, exactly 5 keeps the last mode.
        state.isOverflowing =
            unfinishedRows.count >= 6 ? true : unfinishedRows.count <= 4 ? false : wasOverflowing
        if state.isOverflowing {
            state.rows = Array(unfinishedRows.prefix(4))
            state.overflowCount = unfinishedRows.count - state.rows.count
        } else {
            state.rows = Array(unfinishedRows.prefix(5))
            state.overflowCount = max(0, unfinishedRows.count - state.rows.count)
        }
        return state
    }

    /// Parses yt-dlp speed strings ("3.21MiB/s", "512.00KiB/s", "1.2MB/s")
    /// into bytes/second. "Unknown" and other noise return nil and are simply
    /// left out of the aggregate.
    static func parseSpeed(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let pattern = #"^~?([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)/s$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            m.numberOfRanges == 3,
            let numRange = Range(m.range(at: 1), in: s),
            let unitRange = Range(m.range(at: 2), in: s),
            let value = Double(s[numRange])
        else { return nil }
        let multiplier: Double
        switch s[unitRange].uppercased() {
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
        return value * multiplier
    }

    /// "4.2 MB/s" above 1 MB/s, "740 KB/s" below — matches the mockup's
    /// decimal units. The unit rolls over at the ROUNDED value so 999,500 B/s
    /// reads "1.0 MB/s", never "1000 KB/s".
    static func formatSpeed(bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1_000
        if kb.rounded() >= 1_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        return String(format: "%.0f KB/s", kb)
    }
}
