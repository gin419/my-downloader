import SwiftUI

struct DownloadRowView: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject var manager: DownloadManager
    let onReveal: () -> Void
    let onRemove: () -> Void
    let onRetry: () -> Void
    let onCopyLink: () -> Void
    let onOpen: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void

    @State private var titleHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusIcon
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)

                titleView

                Spacer()

                if item.mediaCategory != .unknown {
                    mediaCategoryChip
                }
                statusBadge

                // Queued/fetching rows have no action row, so their cancel —
                // the undo for a bad batch paste — lives inline.
                if isWaiting {
                    removeButton()
                }
            }

            if let meta = metaLine {
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 30)
            }

            if case .downloading = item.status {
                progressSection
            } else if item.status == .paused {
                progressSection
            }

            if item.status == .completed || isFailed || item.status == .paused {
                actionRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
    }

    /// One meta line, one URL per row: with a real title the URL folds in
    /// here ("Jun 1, 02:27 · https://…"); when the title IS the URL, nothing
    /// prints it a second time.
    private var metaLine: String? {
        var parts: [String] = []
        if manager.showDownloadDate {
            parts.append(
                item.addedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        }
        if hasTitle { parts.append(item.url) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var hasTitle: Bool { !(item.title ?? "").isEmpty }

    private var isWaiting: Bool {
        switch item.status {
        case .queued, .fetching: return true
        default: return false
        }
    }

    // MARK: - Sub-views

    private var titleView: some View {
        Group {
            if item.status == .completed, item.outputPath != nil {
                Button(action: onOpen) {
                    Text(item.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .underline(titleHovered)
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                .help("Open file")
                .onHover { hovering in
                    titleHovered = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .onDisappear {
                    // A row removed mid-hover never gets the exit event —
                    // without this the pushed cursor leaks and the arrow
                    // stays a pointing hand.
                    if titleHovered {
                        NSCursor.pop()
                        titleHovered = false
                    }
                }
            } else {
                Text(item.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var statusIcon: some View {
        Group {
            switch item.status {
            case .queued:
                Image(systemName: "clock").foregroundColor(.secondary)
            case .fetching:
                Image(systemName: "magnifyingglass").foregroundColor(.orange)
            case .downloading:
                Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue).symbolEffect(.pulse)
            case .paused:
                Image(systemName: "pause.circle.fill").foregroundColor(.yellow)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
            }
        }
    }

    private var mediaCategoryChip: some View {
        let cat = item.mediaCategory
        return HStack(spacing: 4) {
            Text(cat.icon).font(.system(size: 11))
            Text(mediaCategoryLabel).font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(cat.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(cat.color.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(cat.color.opacity(0.25), lineWidth: 0.5))
        .help(mediaCountTooltip)
    }

    /// Full media counts live in the chip's tooltip so the row itself stays
    /// one line shorter.
    private var mediaCountTooltip: String {
        var parts: [String] = []
        if let v = item.videoCount, v > 0 { parts.append("\(v) video\(v == 1 ? "" : "s")") }
        if let i = item.imageCount, i > 0 { parts.append("\(i) image\(i == 1 ? "" : "s")") }
        return parts.isEmpty ? item.mediaCategory.label : parts.joined(separator: " · ")
    }

    private var mediaCategoryLabel: String {
        switch item.mediaCategory {
        case .image:
            if let c = item.imageCount, c > 1 { return "Image · \(c)" }
            return "Image"
        case .video:
            if let c = item.videoCount, c > 1 { return "Video · \(c)" }
            return "Video"
        case .audio:
            return "Audio"
        case .mixed:
            let imgs = item.imageCount.map { "\($0)" } ?? ""
            let vids = item.videoCount.map { "\($0)" } ?? ""
            return "Mixed · \(imgs)+\(vids)"
        case .unknown:
            return "?"
        }
    }

    private var statusBadge: some View {
        Text(item.status.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(item.status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(item.status.color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.progressGradient)
                        .frame(width: geo.size.width * item.progress, height: 6)
                        .animation(.linear(duration: 0.3), value: item.progress)
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("Download progress")
            .accessibilityValue("\(Int((item.progress * 100).rounded())) percent")

            HStack {
                if let size = item.totalSize {
                    Text(size).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
                Spacer()
                if let speed = item.speed {
                    Text(speed).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
                if let eta = item.eta {
                    Text("ETA \(eta)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
                if item.status == .downloading, item.isLargeDownload {
                    Button(action: onPause) {
                        HStack(spacing: 4) {
                            Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold))
                            Text("Pause").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.yellow.opacity(0.15)))
                        .overlay(Capsule().strokeBorder(Color.yellow.opacity(0.35), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Pause download — resume anytime")
                }
                if item.status == .downloading {
                    removeButton(help: "Cancel download")
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if item.status == .completed {
                Button(action: onReveal) {
                    Label("Show in Finder", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }

            if item.status == .paused {
                Button(action: onResume) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        Text("Resume").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(.plain)
            }

            if case .failed(let msg) = item.status {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.orange)

                Button(action: onCopyLink) {
                    Label("Copy Link", systemImage: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)

                let displayMsg = msg == "external_redirect" ? "" : msg
                if !displayMsg.isEmpty {
                    Text(displayMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            removeButton()
        }
    }

    private func removeButton(help: String = "Remove") -> some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Helpers

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var rowBackground: some ShapeStyle {
        if item.status == .completed { return AnyShapeStyle(Color.green.opacity(0.05)) }
        if item.status == .paused { return AnyShapeStyle(Color.yellow.opacity(0.06)) }
        if isFailed { return AnyShapeStyle(Color.red.opacity(0.05)) }
        return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
    }

    private var borderColor: Color {
        if item.status == .completed { return .green.opacity(0.2) }
        if item.status == .paused { return .yellow.opacity(0.25) }
        if isFailed { return .red.opacity(0.2) }
        return Color.primary.opacity(0.08)
    }

    private static let progressGradient = LinearGradient(
        colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing
    )
}
