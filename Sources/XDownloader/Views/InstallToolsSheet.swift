import AppKit
import SwiftUI

/// Pure copy/derivation helpers for the install sheet, split out so the
/// footer's adaptive primary-button label and the per-tool meta line are
/// testable without a view.
enum InstallSheetModel {
    /// Footer primary button: only missing → "Install Missing Tools"; only
    /// outdated → "Update Outdated Tools"; both → "Install Missing + Update
    /// Outdated"; neither → nil (Close is the only button). Broken tools
    /// count in the missing bucket — the repair flow treats them alike.
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
        case .broken(let detail):
            return "\(path) · \(detail)"
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
        case .broken: return "Broken"
        case .outdated: return "Outdated"
        case .ok: return "OK"
        }
    }

    /// The manual fix-it command per problem kind.
    static func manualCommand(for health: ToolHealth) -> String {
        switch health.status {
        case .broken: return "brew reinstall \(health.brewPackage)"
        case .outdated: return "brew upgrade \(health.brewPackage)"
        default: return "brew install \(health.brewPackage)"
        }
    }
}

/// Per-tool health table (every tool, not just missing ones) + the combined
/// Homebrew repair flow: install missing → reinstall broken → upgrade
/// outdated, streaming into one log. The run's state lives on the monitor,
/// so dismissing and reopening the sheet shows the live run.
struct InstallToolsSheet: View {
    @ObservedObject var monitor: ToolHealthMonitor
    @Environment(\.dismiss) private var dismiss

    private var healths: [ToolHealth] { monitor.healths }
    private var redFamilyCount: Int {
        healths.filter {
            switch $0.status {
            case .missing, .broken: return true
            case .outdated, .ok: return false
            }
        }.count
    }
    private var outdatedCount: Int {
        healths.filter {
            if case .outdated = $0.status { return true } else { return false }
        }.count
    }
    private var isRunning: Bool { monitor.repairState == .running }

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
                    if !monitor.problems.isEmpty {
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
        case .missing, .broken: color = .red
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
        if case .idle = monitor.repairState { return false } else { return true }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HOMEBREW")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if case .done(let outcome) = monitor.repairState {
                resultRow(for: outcome)
            }

            logView
        }
    }

    /// Post-repair truth, judged AFTER the forced re-probe: "All done" only
    /// when no problem remains; an exit-0 run that left a problem standing
    /// names the likely index lag instead.
    private func resultRow(for outcome: RequirementsService.RepairOutcome) -> some View {
        let icon: String
        let color: Color
        let text: String
        switch outcome {
        case .success:
            icon = "checkmark.circle.fill"
            color = .green
            text = "All done — the statuses above are refreshed."
        case .indexMayLag(let copy):
            icon = "exclamationmark.triangle.fill"
            color = .orange
            text = copy
        case .failed(let friendly):
            icon = "xmark.circle.fill"
            color = .red
            text = friendly ?? "Some tools failed to install or update. Check the log below."
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).font(.system(size: 12))
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(monitor.repairLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line + String(monitor.repairLog.count))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8)
            }
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            .onChange(of: monitor.repairLog.count) {
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

            ForEach(monitor.problems) { health in
                let command = InstallSheetModel.manualCommand(for: health)
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
                    missingCount: redFamilyCount,
                    outdatedCount: outdatedCount)
            {
                Button(label) { monitor.startRepair() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isRunning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
