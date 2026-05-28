import SwiftUI

struct DownloadRowView: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject var manager: DownloadManager
    let onReveal:   () -> Void
    let onRemove:   () -> Void
    let onRetry:    () -> Void
    let onCopyLink: () -> Void
    let onOpen:     () -> Void

    @State private var titleHovered = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusIcon
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    titleView

                    Text(item.url)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if manager.showDownloadDate {
                        Text(DownloadRowView.dateFormatter.string(from: item.addedAt))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }

                Spacer()

                if item.mediaCategory != .unknown {
                    mediaCategoryChip
                }
                statusBadge
            }

            if case .downloading = item.status {
                progressSection
            }

            if item.status == .completed || isFailed {
                actionRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
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

                if let count = item.videoCount, count > 1 {
                    Text("\(count) videos")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if let count = item.imageCount, count > 0 {
                    Text("\(count) image\(count > 1 ? "s" : "")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
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

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
    }

    // MARK: - Helpers

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var rowBackground: some ShapeStyle {
        if item.status == .completed { return AnyShapeStyle(Color.green.opacity(0.05)) }
        if isFailed                  { return AnyShapeStyle(Color.red.opacity(0.05)) }
        return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
    }

    private var borderColor: Color {
        if item.status == .completed { return .green.opacity(0.2) }
        if isFailed                  { return .red.opacity(0.2) }
        return Color.primary.opacity(0.08)
    }

    private static let progressGradient = LinearGradient(
        colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing
    )
}
