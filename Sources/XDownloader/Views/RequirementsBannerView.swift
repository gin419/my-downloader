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
        let missing = problems.filter { $0.status == .missing }
        let broken = problems.filter {
            if case .broken = $0.status { return true } else { return false }
        }
        let outdated = problems.filter {
            if case .outdated = $0.status { return true } else { return false }
        }
        guard !(missing.isEmpty && broken.isEmpty && outdated.isEmpty) else { return nil }
        let sig = signature(for: problems)

        if broken.isEmpty && outdated.isEmpty {
            // State B
            return RequirementsBannerModel(
                headline: "Missing: \(missing.map(\.name).joined(separator: ", "))",
                subtitle: "\(sitesPhrase(for: missing)) need \(missing.count == 1 ? "it" : "them").",
                buttonTitle: "Set Up…",
                severity: .missing,
                signature: sig)
        }
        if missing.isEmpty && broken.isEmpty {
            // State C
            let headline: String
            if outdated.count == 1, let tool = outdated.first,
                case .outdated(let installed, let detail) = tool.status
            {
                let tag = detail.map { "\(installed) · \($0)" } ?? installed
                headline = "\(tool.name) is outdated (\(tag))"
            } else {
                headline = "Outdated: \(outdated.map(versionTag).joined(separator: ", "))"
            }
            return RequirementsBannerModel(
                headline: headline,
                subtitle: "\(sitesPhrase(for: outdated)) likely fail until \(outdated.count == 1 ? "it's" : "they're") updated.",
                buttonTitle: "Update…",
                severity: .outdated,
                signature: sig)
        }
        if missing.isEmpty && outdated.isEmpty {
            // Broken only — red family: an unrunnable tool fails downloads
            // exactly like a missing one.
            let headline: String
            if broken.count == 1, let tool = broken.first, case .broken(let detail) = tool.status {
                headline = "\(tool.name) is broken (\(detail)) — reinstall it."
            } else {
                headline = "Broken: \(broken.map(\.name).joined(separator: ", ")) — reinstall them."
            }
            return RequirementsBannerModel(
                headline: headline,
                subtitle: "\(sitesPhrase(for: broken)) need \(broken.count == 1 ? "it" : "them").",
                buttonTitle: "Set Up…",
                severity: .missing,
                signature: sig)
        }
        // State D — mixed categories, red wins; outdated entries show the
        // version only (the age would crowd out the rest).
        var segments: [String] = []
        if !missing.isEmpty { segments.append("Missing: \(missing.map(\.name).joined(separator: ", "))") }
        if !broken.isEmpty { segments.append("Broken: \(broken.map(\.name).joined(separator: ", "))") }
        if !outdated.isEmpty { segments.append("Outdated: \(outdated.map(versionTag).joined(separator: ", "))") }
        return RequirementsBannerModel(
            headline: segments.joined(separator: " · "),
            subtitle: "Downloads will fail or degrade until both are fixed.",
            buttonTitle: "Set Up…",
            severity: .missing,
            signature: sig)
    }

    /// The banner the window should actually show: nil when there are no
    /// problems OR the current problem set's signature was dismissed. The
    /// dismissal lives on DownloadManager (session-scoped), so closing and
    /// reopening the window cannot resurrect a dismissed banner.
    static func visibleModel(problems: [ToolHealth], dismissedSignature: String?) -> RequirementsBannerModel? {
        guard let model = make(problems: problems), model.signature != dismissedSignature
        else { return nil }
        return model
    }

    /// Dismissal key: sorted "kind:id" components joined with "|"
    /// (e.g. "missing:deno|outdated:yt-dlp"). The ✕ hides the banner for the
    /// session, but only for THIS signature — when the problem set changes,
    /// the banner reappears.
    static func signature(for problems: [ToolHealth]) -> String {
        problems
            .compactMap { health -> String? in
                switch health.status {
                case .missing: return "missing:\(health.id)"
                case .broken: return "broken:\(health.id)"
                case .outdated: return "outdated:\(health.id)"
                case .ok: return nil
                }
            }
            .sorted()
            .joined(separator: "|")
    }

    // MARK: - Copy helpers

    private static func versionTag(_ health: ToolHealth) -> String {
        if case .outdated(let installed, _) = health.status {
            return "\(health.name) (\(installed))"
        }
        return health.name
    }

    /// What actually breaks for the user, per tool — the sub-line names the
    /// affected downloads, not the tool internals.
    private static let siteOrder = ["YouTube", "X", "Instagram", "Reddit"]
    private static let affectedSites: [String: [String]] = [
        "yt-dlp": ["YouTube", "X"],
        "gallery-dl": ["X", "Instagram", "Reddit"],
        "ffmpeg": ["YouTube", "X"],
        "deno": ["YouTube"],
    ]

    private static func sitesPhrase(for tools: [ToolHealth]) -> String {
        let hit = Set(tools.flatMap { affectedSites[$0.id] ?? [] })
        let ordered = siteOrder.filter(hit.contains)
        guard !ordered.isEmpty else { return "Downloads" }
        return "\(naturalJoin(ordered)) downloads"
    }

    private static func naturalJoin(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}

struct RequirementsBannerView: View {
    let model: RequirementsBannerModel
    let onAction: () -> Void
    let onDismiss: () -> Void

    private var stripeColor: Color {
        model.severity == .missing ? .red : .orange
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(stripeColor)
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 1) {
                Text(model.headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Text(model.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer()

            Button(model.buttonTitle, action: onAction)
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(stripeColor)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide until the problem set changes")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(stripeColor.opacity(0.08))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(stripeColor.opacity(0.2)),
            alignment: .bottom
        )
    }
}
