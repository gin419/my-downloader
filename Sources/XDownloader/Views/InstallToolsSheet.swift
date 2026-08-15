import AppKit
import SwiftUI

/// Pure copy/derivation helpers for the install sheet, split out so the
/// footer's adaptive primary-button label and the per-tool meta line are
/// testable without a view.
enum InstallSheetModel {
    /// Footer primary button: only missing → "Install Missing Tools"; only
    /// outdated → "Update Outdated Tools"; both → "Install Missing + Update
    /// Outdated"; neither → nil (Close is the only button).
    static func primaryActionLabel(missingCount: Int, outdatedCount: Int) -> String? {
        switch (missingCount > 0, outdatedCount > 0) {
        case (true, true): return "Install Missing + Update Outdated"
        case (true, false): return "Install Missing Tools"
        case (false, true): return "Update Outdated Tools"
        case (false, false): return nil
        }
    }

    /// Row meta line: "path · version · age", monospaced small type in the
    /// view; a missing tool explains itself instead.
    static func metaLine(for health: ToolHealth) -> String {
        guard let path = health.path else { return "not found in any search path" }
        switch health.status {
        case .missing:
            return "not found in any search path"
        case .ok(let version):
            return "\(path) · \(version)"
        case .outdated(let installed, let detail):
            var parts = [path, installed]
            if let detail { parts.append(detail) }
            return parts.joined(separator: " · ")
        }
    }

    static func pillLabel(for status: ToolStatus) -> String {
        switch status {
        case .missing: return "Missing"
        case .outdated: return "Outdated"
        case .ok: return "OK"
        }
    }
}

/// Per-tool health table (every tool, not just missing ones) + the combined
/// Homebrew repair flow: install what's missing, then upgrade what's
/// outdated, streaming into one log.
struct InstallToolsSheet: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var installState: InstallState = .idle
    @State private var log: [String] = []
    /// Friendly cause line shown above the log on failure (e.g. network);
    /// nil keeps the generic check-the-log pointer.
    @State private var failureSummary: String? = nil

    enum InstallState {
        case idle, running
        case done(success: Bool)
    }

    private var healths: [ToolHealth] { manager.toolHealths }
    private var missingHealths: [ToolHealth] {
        healths.filter { $0.status == .missing }
    }
    private var outdatedHealths: [ToolHealth] {
        healths.filter {
            if case .outdated = $0.status { return true } else { return false }
        }
    }
    private var isRunning: Bool {
        if case .running = installState { return true } else { return false }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    toolTable
                    if showsLogSection {
                        Divider()
                        logSection
                    }
                    if !manager.toolProblems.isEmpty {
                        Divider()
                        manualSection
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 500, height: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundColor(.orange)
            Text("Tool Health")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Tool health table

    private var toolTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TOOLS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ForEach(healths) { health in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(health.name)
                            .font(.system(size: 13, weight: .bold))
                        Text(InstallSheetModel.metaLine(for: health))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    statusPill(for: health.status)
                }
            }
        }
    }

    private func statusPill(for status: ToolStatus) -> some View {
        let color: Color
        switch status {
        case .missing: color = .red
        case .outdated: color = .orange
        case .ok: color = .green
        }
        return Text(InstallSheetModel.pillLabel(for: status))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Homebrew log

    private var showsLogSection: Bool {
        if case .idle = installState { return false } else { return true }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HOMEBREW")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if case .done(let success) = installState {
                HStack(spacing: 8) {
                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(success ? .green : .red)
                    Text(resultLine(success: success))
                        .font(.system(size: 12))
                }
            }

            logView
        }
    }

    private func resultLine(success: Bool) -> String {
        if success { return "All done — the statuses above are refreshed." }
        return failureSummary ?? "Some tools failed to install or update. Check the log below."
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line + String(log.count))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8)
            }
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            .onChange(of: log.count) {
                proxy.scrollTo("bottom")
            }
        }
    }

    // MARK: - Manual install

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MANUAL")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if RequirementsService.brewPath == nil {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Homebrew is not installed. Install it from brew.sh, then relaunch the app.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            ForEach(manager.toolProblems) { health in
                let command =
                    health.status == .missing
                    ? "brew install \(health.brewPackage)"
                    : "brew upgrade \(health.brewPackage)"
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(health.name)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if let docs = URL(string: health.docsURL) {
                            Link("Docs ↗", destination: docs)
                                .font(.system(size: 11))
                        }
                    }

                    HStack(spacing: 8) {
                        Text(command)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.clipboard")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button("Close") { dismiss() }

            if RequirementsService.brewPath != nil,
                let label = InstallSheetModel.primaryActionLabel(
                    missingCount: missingHealths.count,
                    outdatedCount: outdatedHealths.count)
            {
                Button(label, action: startRepair)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isRunning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func startRepair() {
        let missingTools = missingHealths.compactMap { RequirementsService.tool(withID: $0.id) }
        let outdatedTools = outdatedHealths.compactMap { RequirementsService.tool(withID: $0.id) }
        guard !(missingTools.isEmpty && outdatedTools.isEmpty) else { return }

        log = []
        failureSummary = nil
        withAnimation { installState = .running }

        Task {
            let code = await RequirementsService.repairWithBrew(
                missing: missingTools, outdated: outdatedTools
            ) { line in
                // "already installed" chatter would drown the signal — drop it.
                if !RequirementsService.isSuppressedBrewNoise(line) { log.append(line) }
            }
            // Re-probe so the pills above tell the post-repair truth.
            manager.toolHealth.refresh(force: true)
            if code != 0 { failureSummary = RequirementsService.friendlyBrewFailure(inLog: log) }
            withAnimation { installState = .done(success: code == 0) }
        }
    }
}
