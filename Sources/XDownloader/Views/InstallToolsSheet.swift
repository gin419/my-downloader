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

    /// The manual fix-it command per problem kind. A tool resolved OUTSIDE a
    /// Homebrew prefix gets an honest pointer instead of a brew command —
    /// brew only touches its own cellar, so "brew reinstall" would succeed
    /// while the pipx/MacPorts copy the app actually runs stays broken.
    static func manualCommand(for health: ToolHealth) -> String {
        if let path = health.path, !RequirementsService.isBrewManagedPath(path) {
            return "update \(health.name) with the tool that installed \(path) (not managed by Homebrew)"
        }
        switch health.status {
        case .broken: return "brew reinstall \(health.brewPackage)"
        case .outdated: return "brew upgrade \(health.brewPackage)"
        default: return "brew install \(health.brewPackage)"
        }
    }
}

/// Per-tool health table (every tool, not just missing ones) + the two-step
/// setup wizard (choose tools/installer, then confirm) and the combined
/// repair run. The run's state lives on the monitor, so dismissing and
/// reopening the sheet shows the live run.
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
            switch monitor.setupStep {
            case .choose(let draft):
                chooseBody(draft)
            case .confirm(let plan):
                confirmBody(plan)
            case .health, .running, .result:
                healthBody
            }
            Divider()
            footer
        }
        .frame(width: 540, height: 560)
        .onDisappear { monitor.cancelSetup() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: headerIcon)
                .foregroundColor(.orange)
            Text(headerTitle)
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

    private var headerTitle: String {
        switch monitor.setupStep {
        case .choose: return "Choose tools"
        case .confirm: return "Confirm setup"
        default: return "Tool Health"
        }
    }

    private var headerIcon: String {
        switch monitor.setupStep {
        case .choose, .confirm: return "square.and.arrow.down.on.square"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    // MARK: - Health table

    private var healthBody: some View {
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
    }

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

    // MARK: - Choose

    private func chooseBody(_ draft: ToolSetupDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Select which tools to act on and how to install them. Homebrew is preferred when it is already installed.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                ForEach(draft.choices) { choice in
                    chooseRow(choice)
                }
            }
            .padding(20)
        }
    }

    private func chooseRow(_ choice: ToolSetupChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    monitor.setChoiceSelected(toolID: choice.toolID, selected: !choice.isSelected)
                } label: {
                    Image(systemName: choice.isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(choice.canAct ? .orange : .secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .disabled(!choice.canAct)

                Text(choice.name)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(choice.action.verb)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }

            if let unmanaged = choice.unmanagedPath {
                Text("\(unmanaged) is not managed by this app. Update it with the tool that installed it.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if choice.availableInstallers.count > 1 {
                Picker(
                    "Installer",
                    selection: Binding(
                        get: { choice.selectedInstaller ?? .standalone },
                        set: { monitor.setChoiceInstaller(toolID: choice.toolID, installer: $0) })
                ) {
                    ForEach(choice.availableInstallers, id: \.self) { installer in
                        let label =
                            installer == .homebrew
                            ? "Homebrew (preferred)"
                            : "Standalone download"
                        Text(label).tag(installer)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .font(.system(size: 12))
                .disabled(!choice.isSelected)

                Text(destinationHint(for: choice))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else if let installer = choice.selectedInstaller {
                Text(installer == .homebrew ? "Homebrew" : "Standalone download")
                    .font(.system(size: 12))
                Text(destinationHint(for: choice))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func destinationHint(for choice: ToolSetupChoice) -> String {
        guard let installer = choice.selectedInstaller else { return "" }
        return choice.destination(for: installer)
    }

    // MARK: - Confirm

    private func confirmBody(_ plan: ToolSetupPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review the plan. Nothing is downloaded or installed until you confirm.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                ForEach(ToolSetupPlanner.confirmationLines(for: plan), id: \.actionAndInstaller) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.actionAndInstaller)
                            .font(.system(size: 13, weight: .semibold))
                        Text("Destination: \(line.destination)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        if let replacing = line.replacing {
                            Text(replacing)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        if let source = line.source {
                            Text(source)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                }

                Text(ToolSetupPlanner.rollbackNotice)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(20)
        }
    }

    // MARK: - Homebrew / standalone log

    private var showsLogSection: Bool {
        if case .idle = monitor.repairState { return false } else { return true }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LOG")
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
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Homebrew is not installed. You can still install tools from inside the app, or install Homebrew from brew.sh.")
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

            switch monitor.setupStep {
            case .choose(let draft):
                Button("Cancel") { monitor.cancelSetup() }
                Button("Continue") { monitor.reviewPlan() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(!draft.hasActionableSelection)
            case .confirm:
                Button("Cancel") { monitor.backToChoice() }
                Button("Confirm and start") { monitor.confirmAndStart() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            case .health, .running, .result:
                Button("Close") { dismiss() }

                if let label = InstallSheetModel.primaryActionLabel(
                    missingCount: redFamilyCount,
                    outdatedCount: outdatedCount),
                    monitor.hasActionableSetup
                {
                    Button(label) { monitor.beginChoice() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(isRunning)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
