import AppKit
import Combine
import Foundation

/// Resumes a continuation exactly once when exit and timeout race.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

/// Probes the tool catalogue's health — existence (shared resolver) +
/// `<tool> --version` + Homebrew's local outdated index — and publishes the
/// result. Never blocks UI: probes run in a Task and land as one published
/// array. Cadence: app launch (`activate()`), every
/// NSApplication.didBecomeActiveNotification, and each queue-drain start —
/// the latter two through a ≥`cacheInterval` cache.
///
/// Also owns the shared repair-run state (log, outcome): the install sheet
/// is a window onto a run that keeps going when the sheet is dismissed.
///
/// All inputs are injectable so tests can drive the probe deterministically
/// without spawning processes.
@MainActor
final class ToolHealthMonitor: ObservableObject {

    @Published private(set) var healths: [ToolHealth] = []

    /// Shared repair-run state — deliberately NOT view @State, so dismissing
    /// and reopening the sheet shows the live run, and only one repair can be
    /// active globally.
    enum RepairState: Equatable {
        case idle, running
        case done(RequirementsService.RepairOutcome)
    }
    @Published private(set) var repairState: RepairState = .idle
    @Published private(set) var repairLog: [String] = []

    /// Choice/confirm live here so tests can drive the two-step gate without
    /// a view. Dismissing the sheet while in choose/confirm returns to `.health`.
    @Published private(set) var setupStep: ToolSetupStep = .health

    private let tools: [ToolRequirement]
    private let pathResolver: (ToolRequirement) -> String?
    private let versionLineProvider: (String, [String]) async -> String?
    private let brewOutdatedProvider: ([String]) async -> Set<String>
    private let now: () -> Date
    private let cacheInterval: TimeInterval
    private let brewPathProvider: () -> String?
    private let toolsDirectory: URL
    private let executePlan: ((ToolSetupPlan, @escaping @MainActor @Sendable (String) -> Void) async -> ToolRepairResult)?
    private var lastDraft: ToolSetupDraft?

    private var activated = false
    private var lastProbeAt: Date?
    private var probeTask: Task<Void, Never>?
    /// A forced refresh that lands while a probe is in flight queues exactly
    /// ONE follow-up probe — a post-repair refresh must never be dropped.
    private var followUpQueued = false
    private var repairTask: Task<Void, Never>?
    private var activationObserver: AnyCancellable?

    /// Hard deadline for one `<tool> --version` run — a hung binary must
    /// never wedge tool health for the session.
    static let probeTimeout: TimeInterval = 10

    init(
        tools: [ToolRequirement] = RequirementsService.all,
        pathResolver: @escaping (ToolRequirement) -> String? = { RequirementsService.resolvedPath(for: $0) },
        versionLineProvider: ((String, [String]) async -> String?)? = nil,
        brewOutdatedProvider: (([String]) async -> Set<String>)? = nil,
        now: @escaping () -> Date = Date.init,
        cacheInterval: TimeInterval = 60,
        brewPathProvider: @escaping () -> String? = { RequirementsService.brewPath },
        toolsDirectory: URL = URL(fileURLWithPath: AppPaths.toolsDirectory()),
        executePlan: (
            (ToolSetupPlan, @escaping @MainActor @Sendable (String) -> Void) async -> ToolRepairResult
        )? = nil
    ) {
        self.tools = tools
        self.pathResolver = pathResolver
        self.versionLineProvider =
            versionLineProvider
            ?? { await Self.probeVersionLine(executablePath: $0, arguments: $1, timeout: Self.probeTimeout) }
        self.brewOutdatedProvider = brewOutdatedProvider ?? { await RequirementsService.brewOutdatedNames(packages: $0) }
        self.now = now
        self.cacheInterval = cacheInterval
        self.brewPathProvider = brewPathProvider
        self.toolsDirectory = toolsDirectory
        self.executePlan = executePlan
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

    /// Problems only, missing → broken → outdated — the banner's input.
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

    /// Launches a probe. Cache-fresh non-forced calls are dropped; a FORCED
    /// call during an in-flight probe queues exactly one follow-up probe so
    /// post-change state is always observed.
    func refresh(force: Bool) {
        if probeTask != nil {
            if force { followUpQueued = true }
            return
        }
        if !force, let last = lastProbeAt, now().timeIntervalSince(last) < cacheInterval { return }
        launchProbe()
    }

    private func launchProbe() {
        probeTask = Task { [weak self] in
            await self?.performProbe()
            guard let self else { return }
            self.probeTask = nil
            if self.followUpQueued {
                self.followUpQueued = false
                self.launchProbe()
            }
        }
    }

    /// Waits until no probe is running or queued — used by the repair flow
    /// before judging the post-repair truth, and by tests.
    func awaitProbesSettled() async {
        while let task = probeTask { _ = await task.value }
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
            if let path { versionLine = await versionLineProvider(path, tool.versionArguments) }
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
        // A finished repair's verdict only describes the problem set it was
        // judged against — when the probe finds a different one, the sheet
        // must return to its neutral state instead of rendering a stale
        // "All done" (or failure) over new problems.
        if case .done = repairState, judgedProblems != problems {
            repairState = .idle
            judgedProblems = nil
            if case .result = setupStep { setupStep = .health }
        }
    }

    // MARK: - Repair flow (shared state)

    /// The click-time brew plan: statuses drive the verb, but a fresh
    /// existence re-resolve drops "missing" tools that appeared on disk since
    /// the sheet rendered (e.g. a pipx install done in Terminal) — they must
    /// not trigger a duplicate brew install. Broken/outdated tools whose
    /// resolved binary is NOT under a Homebrew prefix go to `unmanaged`
    /// instead of a brew bucket: brew only touches its own cellar, so a
    /// reinstall/upgrade would "succeed" while the actually-resolved pipx or
    /// MacPorts copy stays broken — those tools are served by the sheet's
    /// manual-command line. Pure for tests.
    static func repairPlan(
        problems: [ToolHealth],
        resolvedPath: (ToolRequirement) -> String?
    ) -> (
        missing: [ToolRequirement], broken: [ToolRequirement],
        outdated: [ToolRequirement], unmanaged: [ToolRequirement]
    ) {
        var missing: [ToolRequirement] = []
        var broken: [ToolRequirement] = []
        var outdated: [ToolRequirement] = []
        var unmanaged: [ToolRequirement] = []
        for problem in problems {
            guard let tool = RequirementsService.tool(withID: problem.id) else { continue }
            switch problem.status {
            case .missing:
                if resolvedPath(tool) == nil { missing.append(tool) }
            case .broken, .outdated:
                guard let path = resolvedPath(tool) else {
                    // The binary vanished since the probe — install is the
                    // honest verb now.
                    missing.append(tool)
                    continue
                }
                guard RequirementsService.isBrewManagedPath(path) else {
                    unmanaged.append(tool)
                    continue
                }
                if case .broken = problem.status {
                    broken.append(tool)
                } else {
                    outdated.append(tool)
                }
            case .ok:
                break
            }
        }
        return (missing, broken, outdated, unmanaged)
    }

    /// The problem set a finished repair's outcome was judged against. When a
    /// later probe derives a DIFFERENT problem set, the stale `.done` verdict
    /// must not keep rendering ("All done" against new problems) — the state
    /// returns to `.idle`.
    private var judgedProblems: [ToolHealth]?

    /// Current problems that the wizard can actually act on (not unmanaged).
    var hasActionableSetup: Bool {
        currentDraft().hasAnyActionable
    }

    func currentDraft() -> ToolSetupDraft {
        ToolSetupPlanner.makeDraft(
            problems: problems,
            resolvedPath: pathResolver,
            brewPath: brewPathProvider(),
            toolsDirectory: toolsDirectory.path)
    }

    /// Opens the choice step. No installer is invoked.
    func beginChoice() {
        guard repairState != .running else { return }
        let draft = currentDraft()
        lastDraft = draft
        setupStep = .choose(draft)
    }

    func setChoiceSelected(toolID: String, selected: Bool) {
        guard case .choose(var draft) = setupStep else { return }
        draft.setSelected(toolID: toolID, selected: selected)
        lastDraft = draft
        setupStep = .choose(draft)
    }

    func setChoiceInstaller(toolID: String, installer: ToolInstallerKind) {
        guard case .choose(var draft) = setupStep else { return }
        draft.setInstaller(toolID: toolID, installer: installer)
        lastDraft = draft
        setupStep = .choose(draft)
    }

    /// Choice → confirm. No-op unless at least one actionable tool is checked.
    func reviewPlan() {
        guard case .choose(let draft) = setupStep, let plan = ToolSetupPlanner.freeze(draft) else {
            return
        }
        lastDraft = draft
        setupStep = .confirm(plan)
    }

    func backToChoice() {
        guard case .confirm = setupStep else { return }
        setupStep = .choose(lastDraft ?? currentDraft())
    }

    /// Dismiss / cancel on choose or confirm: drop the wizard, start nothing.
    /// A run already in flight is left alone.
    func cancelSetup() {
        switch setupStep {
        case .choose, .confirm:
            setupStep = .health
        default:
            break
        }
    }

    func confirmAndStart() {
        guard case .confirm(let plan) = setupStep else { return }
        startRepair(plan: plan)
    }

    /// No-plan entry: never installs. Clears a stale verdict (used by tests
    /// and as a safe idle reset). The sheet no longer calls this to repair.
    func startRepair() {
        guard repairState != .running else { return }
        repairState = .idle
        judgedProblems = nil
        setupStep = .health
        refresh(force: true)
    }

    /// The only entry that downloads or invokes brew. `plan` is the frozen
    /// confirmation — callers must not invent work outside `ToolSetupPlanner.freeze`.
    func startRepair(plan: ToolSetupPlan) {
        guard repairState != .running else { return }
        guard !plan.items.isEmpty else {
            startRepair()
            return
        }
        repairLog = []
        repairState = .running
        setupStep = .running
        repairTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.execute(plan)
            self.refresh(force: true)
            await self.awaitProbesSettled()
            let outcome: RequirementsService.RepairOutcome
            if result.rolledBack {
                outcome = .failed(
                    result.failureMessage ?? RequirementsService.repairRolledBackMessage)
            } else {
                outcome = RequirementsService.repairOutcome(
                    exitCode: result.processExitCode,
                    remainingProblems: self.problems,
                    log: self.repairLog)
            }
            self.repairState = .done(outcome)
            self.setupStep = .result(outcome)
            self.judgedProblems = self.problems
            self.repairTask = nil
        }
    }

    func awaitRepairSettled() async {
        while let task = repairTask { _ = await task.value }
    }

    private func execute(_ plan: ToolSetupPlan) async -> ToolRepairResult {
        let sink: @MainActor @Sendable (String) -> Void = { [weak self] line in
            self?.repairLog.append(line)
        }
        if let executePlan {
            return await executePlan(plan, sink)
        }
        let runner = ToolRepairRunner(seams: .production(toolsDirectory: toolsDirectory))
        return await runner.run(plan: plan, onLine: sink)
    }

    /// Test seam: `repairState` is private(set); the reset-to-idle rules need
    /// a planted finished verdict to be exercisable without running brew.
    func plantRepairOutcomeForTesting(
        _ outcome: RequirementsService.RepairOutcome, judgedAgainst: [ToolHealth]
    ) {
        repairState = .done(outcome)
        judgedProblems = judgedAgainst
    }

    // MARK: - Live probe

    /// First stdout line of `<tool> <versionArguments>` (per-tool: ffmpeg
    /// only accepts `-version`; the GNU-style default covers the rest).
    /// Stderr is drained but IGNORED for version parsing — Python deprecation
    /// warnings must never become the "version". Nil on exec failure,
    /// non-zero exit, empty stdout, or timeout (the process is killed so a
    /// hung binary can't wedge health). Internal (not private) so tests can
    /// drive it with fake tools.
    nonisolated static func probeVersionLine(
        executablePath: String, arguments: [String] = ["--version"], timeout: TimeInterval
    ) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Homebrew.fullPATH
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Drain stderr so a chatty tool can't fill the pipe and stall; the
        // contents are deliberately discarded.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        defer { stderrPipe.fileHandleForReading.readabilityHandler = nil }

        do { try process.run() } catch { return nil }

        let once = ResumeOnce()
        let exited: Bool = await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                if once.claim() { continuation.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
        guard exited else {
            process.terminate()  // kill the hung probe; health derives `broken`
            return nil
        }
        guard process.terminationStatus == 0, process.terminationReason == .exit else { return nil }

        let data = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let firstLine = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstLine, !firstLine.isEmpty else { return nil }
        return firstLine
    }
}
