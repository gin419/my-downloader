import AppKit
import Combine
import Foundation

/// Probes the tool catalogue's health — existence (shared resolver) +
/// `<tool> --version` + Homebrew's local outdated index — and publishes the
/// result. Never blocks UI: probes run in a Task and land as one published
/// array. Cadence: app launch (`activate()`), every
/// NSApplication.didBecomeActiveNotification, and each queue-drain start —
/// the latter two through a ≥`cacheInterval` cache.
///
/// All inputs are injectable so tests can drive the probe deterministically
/// without spawning processes.
@MainActor
final class ToolHealthMonitor: ObservableObject {

    @Published private(set) var healths: [ToolHealth] = []

    private let tools: [ToolRequirement]
    private let pathResolver: (ToolRequirement) -> String?
    private let versionLineProvider: (String) async -> String?
    private let brewOutdatedProvider: ([String]) async -> Set<String>
    private let now: () -> Date
    private let cacheInterval: TimeInterval

    private var activated = false
    private var lastProbeAt: Date?
    private var probeTask: Task<Void, Never>?
    private var activationObserver: AnyCancellable?

    init(
        tools: [ToolRequirement] = RequirementsService.all,
        pathResolver: @escaping (ToolRequirement) -> String? = { RequirementsService.resolvedPath(for: $0) },
        versionLineProvider: ((String) async -> String?)? = nil,
        brewOutdatedProvider: (([String]) async -> Set<String>)? = nil,
        now: @escaping () -> Date = Date.init,
        cacheInterval: TimeInterval = 60
    ) {
        self.tools = tools
        self.pathResolver = pathResolver
        self.versionLineProvider = versionLineProvider ?? Self.liveVersionLine
        self.brewOutdatedProvider = brewOutdatedProvider ?? { await RequirementsService.brewOutdatedNames(packages: $0) }
        self.now = now
        self.cacheInterval = cacheInterval
        // Seed from existence alone so the missing/ok split is right the
        // instant the banner first renders; versions arrive with the probe.
        healths = tools.map { tool in
            let path = pathResolver(tool)
            return ToolHealth(
                id: tool.id, name: tool.name, brewPackage: tool.brewPackage,
                docsURL: tool.docsURL, path: path,
                status: path == nil ? .missing : .ok(version: "unknown"))
        }
    }

    /// Problems only, missing first — the banner's input.
    var problems: [ToolHealth] { RequirementsService.orderedProblems(healths) }

    func health(for id: String) -> ToolHealth? { healths.first { $0.id == id } }

    /// App-launch hook: starts the probe cadence (initial probe + a
    /// didBecomeActive subscription). Deliberately separate from init so unit
    /// tests can construct a DownloadManager without spawning `--version`
    /// processes.
    func activate() {
        guard !activated else { return }
        activated = true
        activationObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                // AppKit posts application notifications on the main thread.
                MainActor.assumeIsolated { self?.refreshIfStale() }
            }
        refresh(force: true)
    }

    /// Cache-respecting refresh — queue-drain start and app activation call
    /// this; a probe younger than `cacheInterval` is reused. No-op before
    /// `activate()` so app-independent code paths (and tests) stay quiet.
    func refreshIfStale() {
        guard activated else { return }
        refresh(force: false)
    }

    /// Launches a probe unless one is already in flight or (force off) the
    /// cache is still fresh.
    func refresh(force: Bool) {
        guard probeTask == nil else { return }
        if !force, let last = lastProbeAt, now().timeIntervalSince(last) < cacheInterval { return }
        probeTask = Task { [weak self] in
            await self?.performProbe()
            self?.probeTask = nil
        }
    }

    /// One full probe pass. Internal (not private) so tests can await it
    /// directly instead of racing the fire-and-forget Task above.
    func performProbe() async {
        lastProbeAt = now()
        let resolved = tools.map { ($0, pathResolver($0)) }
        // Only tools that exist get asked about — brew errors on names it
        // does not manage, and a missing tool's fix is install, not upgrade.
        let installedPackages = resolved.compactMap { pair -> String? in
            pair.1 == nil ? nil : pair.0.brewPackage
        }
        let brewOutdated = await brewOutdatedProvider(installedPackages)
        var next: [ToolHealth] = []
        for (tool, path) in resolved {
            var versionLine: String?
            if let path { versionLine = await versionLineProvider(path) }
            let status = RequirementsService.deriveStatus(
                toolID: tool.id,
                brewPackage: tool.brewPackage,
                installedPath: path,
                versionLine: versionLine,
                brewOutdated: brewOutdated,
                now: now())
            next.append(
                ToolHealth(
                    id: tool.id, name: tool.name, brewPackage: tool.brewPackage,
                    docsURL: tool.docsURL, path: path, status: status))
        }
        if next != healths { healths = next }
    }

    /// Live probe: first line of `<tool> --version`, via the existing
    /// ProcessRunner machinery (Homebrew-first PATH, like real downloads).
    @MainActor
    private static func liveVersionLine(_ executablePath: String) async -> String? {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Homebrew.fullPATH
        var firstLine: String?
        _ = await ProcessRunner.runRaw(
            executablePath: executablePath,
            arguments: ["--version"],
            environment: env,
            onLine: { line in
                if firstLine == nil { firstLine = line }
            }
        )
        return firstLine
    }
}
