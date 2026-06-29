import AppKit
import SwiftUI

struct InstallToolsSheet: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    let tools: [ToolRequirement]

    @State private var installState: InstallState = .idle
    @State private var log: [String] = []
    @State private var scrollProxy: ScrollViewProxy? = nil

    enum InstallState {
        case idle, running
        case done(success: Bool)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    toolStatusSection
                    Divider()
                    autoInstallSection
                    Divider()
                    manualInstallSection
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 500)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundColor(.orange)
            Text("Set Up Missing Tools")
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

    // MARK: - Tool status list

    private var toolStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MISSING TOOLS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ForEach(tools) { tool in
                HStack(spacing: 10) {
                    Image(systemName: iconFor(tool))
                        .foregroundColor(colorFor(tool))
                        .font(.system(size: 13))
                        .frame(width: 18)

                    Text(tool.name)
                        .font(.system(size: 13, weight: .medium))

                    Spacer()

                    Text(statusLabel(for: tool))
                        .font(.system(size: 11))
                        .foregroundColor(colorFor(tool))
                }
            }
        }
    }

    // MARK: - Auto install

    private var autoInstallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AUTOMATIC")
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
            } else {
                switch installState {
                case .idle:
                    Button(action: startInstall) {
                        Label("Install all with Homebrew", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                case .running:
                    logView
                        .transition(.opacity)

                case .done(let success):
                    VStack(alignment: .leading, spacing: 8) {
                        logView

                        HStack(spacing: 8) {
                            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(success ? .green : .red)
                            Text(success ? "All tools installed successfully." : "Some tools failed to install. Check the log above.")
                                .font(.system(size: 12))
                        }

                        if success {
                            Button("Done") { dismiss() }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
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

    private var manualInstallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MANUAL")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ForEach(tools) { tool in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(tool.name)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Link("Docs ↗", destination: URL(string: tool.docsURL)!)
                            .font(.system(size: 11))
                    }

                    HStack(spacing: 8) {
                        Text("brew install \(tool.brewPackage)")
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install \(tool.brewPackage)", forType: .string)
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

    // MARK: - Actions

    private func startInstall() {
        let stillMissing = tools.filter { !$0.isInstalled }
        guard !stillMissing.isEmpty else {
            dismiss()
            return
        }

        log = []
        withAnimation { installState = .running }

        Task {
            let code = await RequirementsService.installWithBrew(tools: stillMissing) { line in
                log.append(line)
            }
            manager.checkRequirements()
            withAnimation { installState = .done(success: code == 0) }
        }
    }

    // MARK: - Helpers

    private func iconFor(_ tool: ToolRequirement) -> String {
        if case .done(true) = installState, !manager.missingTools.contains(where: { $0.id == tool.id }) {
            return "checkmark.circle.fill"
        }
        return "xmark.circle.fill"
    }

    private func colorFor(_ tool: ToolRequirement) -> Color {
        if case .done(true) = installState, !manager.missingTools.contains(where: { $0.id == tool.id }) {
            return .green
        }
        return .red
    }

    private func statusLabel(for tool: ToolRequirement) -> String {
        if case .done(true) = installState, !manager.missingTools.contains(where: { $0.id == tool.id }) {
            return "Installed"
        }
        return "Not found"
    }
}
