import AppKit
import SwiftUI

struct LikesSyncCardView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openSettings) private var openSettings
    @State private var failuresExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .font(.system(size: 16, weight: .semibold))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                if snapshot.status.isActive {
                    ProgressView().controlSize(.small)
                    Button(snapshot.status == .cancelling ? "Cancelling…" : "Cancel") {
                        manager.cancelLikesSync()
                    }
                    .disabled(snapshot.status == .cancelling)
                } else if snapshot.handle == nil && manager.twitterHandle.isEmpty {
                    Button("Set Account…") { openSettings() }
                } else {
                    Button("Sync Likes") { manager.startLikesSync() }
                        .buttonStyle(.borderedProminent)
                }
            }

            if shouldShowCounts {
                HStack(spacing: 14) {
                    count("Found", counts.discovered)
                    count("Downloaded", counts.downloaded)
                    count("Already saved", counts.skipped)
                    count("No media", counts.noMedia)
                    count("Failed", counts.failed, color: counts.failed > 0 ? .red : .secondary)
                    count("Ignored", counts.ignored)
                    Spacer(minLength: 0)
                }
            }

            if !snapshot.failures.isEmpty || counts.ignored > 0 {
                Divider().opacity(0.45)
                HStack {
                    if !snapshot.failures.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { failuresExpanded.toggle() }
                        } label: {
                            Label(
                                "\(snapshot.failures.count) failure\(snapshot.failures.count == 1 ? "" : "s")",
                                systemImage: failuresExpanded ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))

                        Button("Retry All") { manager.retryAllLikesFailures() }
                            .font(.system(size: 11))
                            .disabled(snapshot.status.isActive)
                    }
                    Spacer()
                    if counts.ignored > 0 {
                        Button("Restore \(counts.ignored) Ignored") {
                            manager.restoreIgnoredLikesFailures()
                        }
                        .font(.system(size: 11))
                    }
                    if snapshot.outputDirectory != nil {
                        Button("Open Folder") { manager.openLikesFolder() }
                            .font(.system(size: 11))
                    }
                }

                if failuresExpanded {
                    VStack(spacing: 6) {
                        ForEach(snapshot.failures) { failure in
                            failureRow(failure)
                        }
                    }
                }
            } else if snapshot.outputDirectory != nil, !snapshot.status.isActive {
                HStack {
                    Spacer()
                    Button("Open Likes Folder") { manager.openLikesFolder() }
                        .font(.system(size: 11))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
        )
    }

    private var snapshot: LikesSyncSnapshot { manager.likesSyncSnapshot }
    private var counts: LikesSyncCounts { snapshot.counts }

    private var title: String {
        "X Likes Sync" + (snapshot.handle.map { " · \($0.displayName)" } ?? "")
    }

    private var statusText: String {
        if let message = snapshot.message { return message }
        switch snapshot.status {
        case .idle: return "Download all accessible liked images, videos, and GIFs."
        case .running: return "Scanning all accessible Likes…"
        case .cancelling: return "Cancelling after the current file…"
        case .completed: return "Up to date."
        case .partial: return "Completed with items that need attention."
        case .failed: return "Sync failed."
        case .cancelled: return "Cancelled; completed files are kept."
        case .interrupted: return "Interrupted; start again to resume safely."
        }
    }

    private var shouldShowCounts: Bool {
        snapshot.status != .idle || counts != LikesSyncCounts()
    }

    private var borderColor: Color {
        snapshot.status.needsAttention ? .orange.opacity(0.55) : .primary.opacity(0.1)
    }

    private func count(_ label: String, _ value: Int, color: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }

    private func failureRow(_ failure: LikesSyncFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: failureSymbol(failure.category))
                .foregroundColor(.orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(failure.message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let rawURL = failure.url, let url = URL(string: rawURL) {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .font(.system(size: 10))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rawURL, forType: .string)
                }
                .font(.system(size: 10))
            }
            Button(failure.retryActionTitle) { manager.retryLikesFailure(failure) }
                .font(.system(size: 10))
                .disabled(snapshot.status.isActive)
            Button("Ignore") { manager.ignoreLikesFailure(failure) }
                .font(.system(size: 10))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    private func failureSymbol(_ category: LikesSyncFailureCategory) -> String {
        switch category {
        case .authentication: return "person.crop.circle.badge.exclamationmark"
        case .rateLimited: return "clock.badge.exclamationmark"
        case .network: return "wifi.exclamationmark"
        case .disk: return "externaldrive.badge.exclamationmark"
        case .unavailable: return "eye.slash"
        case .tool, .parse, .unknown: return "exclamationmark.triangle"
        }
    }
}
