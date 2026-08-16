import Foundation

/// Wizard surface for first-run / repair setup. `choose` and `confirm` are
/// UI-only: dismissing them cancels. `running` / `result` survive dismiss so
/// a live run keeps going (same as today's sheet).
enum ToolSetupStep: Equatable {
    case health
    case choose(ToolSetupDraft)
    case confirm(ToolSetupPlan)
    case running
    case result(RequirementsService.RepairOutcome)
}

enum ToolInstallerKind: String, Equatable, Hashable, CaseIterable {
    case homebrew
    case standalone

    var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .standalone: return "standalone download"
        }
    }
}

enum ToolSetupAction: String, Equatable {
    case install
    case reinstall
    case update

    var verb: String {
        switch self {
        case .install: return "Install"
        case .reinstall: return "Reinstall"
        case .update: return "Update"
        }
    }
}

/// Mutable choice-step state. `isSelected` is ignored when `canAct` is false
/// (unmanaged existing binaries cannot be overwritten).
struct ToolSetupChoice: Equatable, Identifiable {
    var id: String { toolID }
    let toolID: String
    let name: String
    let action: ToolSetupAction
    let availableInstallers: [ToolInstallerKind]
    var selectedInstaller: ToolInstallerKind?
    var isSelected: Bool
    let currentPath: String?
    let currentVersion: String?
    let standaloneDestination: String
    let brewDestination: String?
    /// Set when a non-brew, non-app-managed binary is the resolved winner.
    let unmanagedPath: String?

    var canAct: Bool { unmanagedPath == nil && !availableInstallers.isEmpty }

    func destination(for installer: ToolInstallerKind) -> String {
        switch installer {
        case .homebrew: return brewDestination ?? standaloneDestination
        case .standalone: return standaloneDestination
        }
    }
}

struct ToolSetupDraft: Equatable {
    var choices: [ToolSetupChoice]

    var hasAnyActionable: Bool { choices.contains { $0.canAct } }

    var hasActionableSelection: Bool {
        choices.contains { $0.isSelected && $0.canAct && $0.selectedInstaller != nil }
    }

    mutating func setSelected(toolID: String, selected: Bool) {
        guard let i = choices.firstIndex(where: { $0.toolID == toolID }) else { return }
        guard choices[i].canAct else { return }
        choices[i].isSelected = selected
    }

    mutating func setInstaller(toolID: String, installer: ToolInstallerKind) {
        guard let i = choices.firstIndex(where: { $0.toolID == toolID }) else { return }
        guard choices[i].availableInstallers.contains(installer) else { return }
        choices[i].selectedInstaller = installer
    }
}

/// Frozen, user-confirmed plan. `startRepair` / standalone install may run
/// only when handed one of these.
struct ToolSetupPlan: Equatable {
    let items: [ToolSetupPlanItem]

    var brewItems: [ToolSetupPlanItem] { items.filter { $0.installer == .homebrew } }
    var standaloneItems: [ToolSetupPlanItem] { items.filter { $0.installer == .standalone } }
}

struct ToolSetupPlanItem: Equatable, Identifiable {
    var id: String { toolID }
    let toolID: String
    let name: String
    let action: ToolSetupAction
    let installer: ToolInstallerKind
    let destination: String
    let currentPath: String?
    let currentVersion: String?
    let sourceHost: String?
    let brewPackage: String
}

struct ToolSetupConfirmationLine: Equatable {
    let actionAndInstaller: String
    let destination: String
    let replacing: String?
    let source: String?
}

/// Pure plan builder + confirmation copy. No I/O.
enum ToolSetupPlanner {
    static let rollbackNotice = "A failed run will restore the previous files."

    static func makeDraft(
        problems: [ToolHealth],
        resolvedPath: (ToolRequirement) -> String?,
        brewPath: String?,
        toolsDirectory: String = AppPaths.toolsDirectory()
    ) -> ToolSetupDraft {
        var choices: [ToolSetupChoice] = []
        for problem in problems {
            guard let tool = RequirementsService.tool(withID: problem.id) else { continue }
            let resolved = resolvedPath(tool)
            let action = action(for: problem.status, resolved: resolved)
            let appManaged = resolved.map { isAppManaged($0, toolsDirectory: toolsDirectory) } ?? false
            let brewManaged = resolved.map { RequirementsService.isBrewManagedPath($0) } ?? false
            let unmanaged = resolved != nil && !appManaged && !brewManaged

            var installers: [ToolInstallerKind] = []
            if resolved == nil {
                if brewPath != nil { installers.append(.homebrew) }
                installers.append(.standalone)
            } else if unmanaged {
                // Leave installers empty — pipx / MacPorts / ~/.local stay theirs.
            } else if brewManaged, brewPath != nil {
                installers.append(.homebrew)
            } else if appManaged {
                installers.append(.standalone)
            }

            let canAct = !unmanaged && !installers.isEmpty
            choices.append(
                ToolSetupChoice(
                    toolID: tool.id,
                    name: tool.name,
                    action: action,
                    availableInstallers: installers,
                    selectedInstaller: installers.first,
                    isSelected: canAct,
                    currentPath: resolved,
                    currentVersion: installedVersion(problem.status),
                    standaloneDestination: (toolsDirectory as NSString).appendingPathComponent(tool.id),
                    brewDestination: brewPath.map {
                        RequirementsService.brewBinDestination(toolID: tool.id, brewPath: $0)
                    },
                    unmanagedPath: unmanaged ? resolved : nil))
        }
        return ToolSetupDraft(choices: choices)
    }

    /// Freeze the user's current selection. Nil when nothing actionable is
    /// checked — the confirm step must not open on an empty plan.
    static func freeze(_ draft: ToolSetupDraft) -> ToolSetupPlan? {
        var items: [ToolSetupPlanItem] = []
        for choice in draft.choices {
            guard choice.isSelected, choice.canAct, let installer = choice.selectedInstaller else {
                continue
            }
            items.append(
                ToolSetupPlanItem(
                    toolID: choice.toolID,
                    name: choice.name,
                    action: choice.action,
                    installer: installer,
                    destination: choice.destination(for: installer),
                    currentPath: choice.currentPath,
                    currentVersion: choice.currentVersion,
                    sourceHost: installer == .standalone ? sourceHost(for: choice.toolID) : nil,
                    brewPackage: RequirementsService.tool(withID: choice.toolID)?.brewPackage
                        ?? choice.toolID))
        }
        return items.isEmpty ? nil : ToolSetupPlan(items: items)
    }

    static func confirmationLines(for plan: ToolSetupPlan) -> [ToolSetupConfirmationLine] {
        plan.items.map { item in
            let replacing: String?
            if let current = item.currentPath {
                if let version = item.currentVersion {
                    replacing = "Current: \(current) · \(version)"
                } else {
                    replacing = "Current: \(current)"
                }
            } else {
                replacing = nil
            }
            return ToolSetupConfirmationLine(
                actionAndInstaller:
                    "\(item.action.verb) \(item.name) via \(item.installer.displayName)",
                destination: item.destination,
                replacing: replacing,
                source: item.installer == .standalone ? sourceDescription(for: item.toolID) : nil)
        }
    }

    static func sourceHost(for toolID: String) -> String {
        switch toolID {
        case "yt-dlp": return "github.com/yt-dlp"
        case "deno": return "github.com/denoland"
        case "ffmpeg": return "evermeet.cx"
        case "gallery-dl": return "PyPI"
        default: return "the official site"
        }
    }

    static func sourceDescription(for toolID: String) -> String {
        switch toolID {
        case "yt-dlp":
            return "The file comes from github.com/yt-dlp (official release)."
        case "deno":
            return "The file comes from github.com/denoland (official release)."
        case "ffmpeg":
            return "The file comes from evermeet.cx (known macOS build)."
        case "gallery-dl":
            return "The package comes from PyPI. If python3 is missing, a CPython runtime is downloaded from github.com/astral-sh."
        default:
            return "The file comes from the official/known URL."
        }
    }

    static func downloadURL(for toolID: String, arch: String) -> URL? {
        switch toolID {
        case "yt-dlp":
            return URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")
        case "deno":
            let triple = appleDarwinTriple(arch)
            return URL(string: "https://github.com/denoland/deno/releases/latest/download/deno-\(triple).zip")
        case "ffmpeg":
            return URL(string: "https://evermeet.cx/ffmpeg/getrelease/zip")
        default:
            return nil
        }
    }

    static func pythonStandaloneURL(arch: String) -> URL {
        let triple = appleDarwinTriple(arch)
        return URL(
            string:
                "https://github.com/astral-sh/python-build-standalone/releases/download/20260814/cpython-3.12.14+20260814-\(triple)-install_only.tar.gz"
        )!
    }

    static func appleDarwinTriple(_ arch: String) -> String {
        arch == "x86_64" ? "x86_64-apple-darwin" : "aarch64-apple-darwin"
    }

    static func currentArchitecture() -> String {
        #if arch(x86_64)
            return "x86_64"
        #else
            return "arm64"
        #endif
    }

    private static func isAppManaged(_ path: String, toolsDirectory: String) -> Bool {
        if RequirementsService.isAppManagedPath(path) { return true }
        let root = URL(fileURLWithPath: toolsDirectory).standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized == root || standardized.hasPrefix(root + "/")
    }

    private static func action(for status: ToolStatus, resolved: String?) -> ToolSetupAction {
        if resolved == nil { return .install }
        switch status {
        case .missing: return .install
        case .broken: return .reinstall
        case .outdated, .ok: return .update
        }
    }

    private static func installedVersion(_ status: ToolStatus) -> String? {
        switch status {
        case .ok(let version): return version
        case .outdated(let installed, _): return installed
        case .missing, .broken: return nil
        }
    }
}
