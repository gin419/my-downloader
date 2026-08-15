import SwiftUI

/// Pure banner derivation: problems → state/copy/severity/signature, so the
/// approved mockup's states A–D are testable without a view. The view below
/// stays a thin renderer.
///
/// - State A: no problems → `make` returns nil (banner hidden).
/// - State B (missing only, red): "Missing: <tools>" + affected-sites sub.
/// - State C (outdated only, amber): "<tool> is outdated (<version> · <age>)"
///   — version + humanized age when derivable, version alone otherwise.
/// - State D (mixed, red wins): "Missing: … · Outdated: …".
struct RequirementsBannerModel: Equatable {
    enum Severity: Equatable {
        case missing  // red stripe (states B and D)
        case outdated  // amber stripe (state C)
    }

    let headline: String
    let subtitle: String
    let buttonTitle: String
    let severity: Severity
    let signature: String

    /// nil = State A (no problems → hidden).
    static func make(problems: [ToolHealth]) -> RequirementsBannerModel? {
        nil  // stub — implemented in the follow-up commit
    }

    /// Dismissal key: sorted "kind:id" components joined with "|"
    /// (e.g. "missing:deno|outdated:yt-dlp"). The ✕ hides the banner for the
    /// session, but only for THIS signature — when the problem set changes,
    /// the banner reappears.
    static func signature(for problems: [ToolHealth]) -> String {
        ""  // stub — implemented in the follow-up commit
    }
}

struct RequirementsBannerView: View {
    let tools: [ToolRequirement]
    let onSetup: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 13))

            Text("Missing: \(tools.map(\.name).joined(separator: ", "))")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            Spacer()

            Button("Set up…", action: onSetup)
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.orange)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss warning")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.orange.opacity(0.2)),
            alignment: .bottom
        )
    }
}
