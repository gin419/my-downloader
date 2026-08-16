import Foundation

enum ToolRepairError: Error, Equatable {
    case downloadFailed
    case extractFailed
    case verifyFailed
    case pythonMissing
    case pipFailed
    case ioFailed
}

struct ToolRepairResult: Equatable {
    var processExitCode: Int32
    var rolledBack: Bool
    var failureMessage: String?
}

/// One confirmed plan as a transaction: snapshot → install/verify → replace,
/// and restore every snapshotted dest if anything fails.
struct ToolRepairRunner {
    struct Seams {
        var fileManager: FileManager = .default
        var toolsDirectory: URL
        var architecture: () -> String = { ToolSetupPlanner.currentArchitecture() }
        var brewPath: () -> String? = { RequirementsService.brewPath }
        var download: (URL, URL) async throws -> Void
        var extractZip: (URL, URL) throws -> Void
        var extractTarGz: (URL, URL) throws -> Void
        var verify: (String, [String]) async -> Bool
        var runProcess: (String, [String], [String: String]?) async -> Int32
        var resolvePython3: () async -> String?
        var runBrew:
            (
                [ToolRequirement], [ToolRequirement], [ToolRequirement],
                @escaping @MainActor @Sendable (String) -> Void
            ) async -> Int32
    }

    var seams: Seams

    func run(
        plan: ToolSetupPlan,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> ToolRepairResult {
        guard !plan.items.isEmpty else {
            return ToolRepairResult(processExitCode: 0, rolledBack: false, failureMessage: nil)
        }

        let fm = seams.fileManager
        try? fm.createDirectory(at: seams.toolsDirectory, withIntermediateDirectories: true)

        var session = RepairSession(toolsDirectory: seams.toolsDirectory, fileManager: fm)
        do {
            try session.snapshotAll(plan.items)
        } catch {
            await onLine("Couldn't snapshot current tools.")
            session.rollbackStandaloneFully()
            session.cleanupStaging()
            return ToolRepairResult(
                processExitCode: 1, rolledBack: true,
                failureMessage: RequirementsService.repairRolledBackMessage)
        }

        var failed = false
        var brewCode: Int32 = 0

        for item in plan.standaloneItems {
            await onLine("\(item.action.verb) \(item.name) via standalone download…")
            do {
                try await installStandalone(item, session: &session, onLine: onLine)
            } catch {
                failed = true
                await onLine("Failed: \(item.name) — \(describe(error)).")
                break
            }
        }

        if !failed, !plan.brewItems.isEmpty {
            let grouped = brewBuckets(plan.brewItems)
            await onLine("Installing via Homebrew…")
            brewCode = await seams.runBrew(grouped.missing, grouped.broken, grouped.outdated, onLine)
            if brewCode != 0 {
                failed = true
                await onLine("Homebrew exited \(brewCode).")
            }
        }

        if failed {
            await onLine("Restoring previous tools…")
            await rollback(session: session, brewItems: plan.brewItems)
            session.cleanupStaging()
            return ToolRepairResult(
                processExitCode: brewCode == 0 ? 1 : brewCode,
                rolledBack: true,
                failureMessage: RequirementsService.repairRolledBackMessage)
        }

        session.cleanupStaging()
        return ToolRepairResult(processExitCode: 0, rolledBack: false, failureMessage: nil)
    }

    // MARK: - Standalone install

    private func installStandalone(
        _ item: ToolSetupPlanItem,
        session: inout RepairSession,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        switch item.toolID {
        case "gallery-dl":
            try await installGalleryDl(item, session: &session, onLine: onLine)
        case "yt-dlp":
            try await installDirectBinary(item, session: &session, onLine: onLine)
        case "deno", "ffmpeg":
            try await installZippedBinary(item, session: &session, onLine: onLine)
        default:
            throw ToolRepairError.downloadFailed
        }
    }

    private func installDirectBinary(
        _ item: ToolSetupPlanItem,
        session: inout RepairSession,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        guard let url = ToolSetupPlanner.downloadURL(for: item.toolID, arch: seams.architecture())
        else { throw ToolRepairError.downloadFailed }
        let dest = URL(fileURLWithPath: item.destination)
        let partial = dest.appendingPathExtension("partial")
        session.forgetIfExists(partial)
        await onLine("Downloading \(item.name) from \(item.sourceHost ?? url.host ?? "the official URL")…")
        do {
            try await seams.download(url, partial)
        } catch {
            try? seams.fileManager.removeItem(at: partial)
            throw ToolRepairError.downloadFailed
        }
        try markExecutable(partial)
        guard await verifyItem(item, at: partial.path) else {
            try? seams.fileManager.removeItem(at: partial)
            throw ToolRepairError.verifyFailed
        }
        try atomicReplace(dest: dest, with: partial)
        session.recordCreatedIfAbsent(dest)
    }

    private func installZippedBinary(
        _ item: ToolSetupPlanItem,
        session: inout RepairSession,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        guard let url = ToolSetupPlanner.downloadURL(for: item.toolID, arch: seams.architecture())
        else { throw ToolRepairError.downloadFailed }
        let dest = URL(fileURLWithPath: item.destination)
        let zip = dest.appendingPathExtension("partial.zip")
        let extractDir = dest.appendingPathExtension("partial.d")
        let partial = dest.appendingPathExtension("partial")
        session.forgetIfExists(zip)
        session.forgetIfExists(extractDir)
        session.forgetIfExists(partial)
        await onLine("Downloading \(item.name) from \(item.sourceHost ?? url.host ?? "the official URL")…")
        do {
            try await seams.download(url, zip)
        } catch {
            try? seams.fileManager.removeItem(at: zip)
            throw ToolRepairError.downloadFailed
        }
        do {
            try seams.fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try seams.extractZip(zip, extractDir)
        } catch {
            try? seams.fileManager.removeItem(at: zip)
            try? seams.fileManager.removeItem(at: extractDir)
            throw ToolRepairError.extractFailed
        }
        guard let extracted = findExtractedBinary(named: item.toolID, in: extractDir) else {
            try? seams.fileManager.removeItem(at: zip)
            try? seams.fileManager.removeItem(at: extractDir)
            throw ToolRepairError.extractFailed
        }
        try? seams.fileManager.removeItem(at: partial)
        try seams.fileManager.copyItem(at: extracted, to: partial)
        try? seams.fileManager.removeItem(at: zip)
        try? seams.fileManager.removeItem(at: extractDir)
        try markExecutable(partial)
        guard await verifyItem(item, at: partial.path) else {
            try? seams.fileManager.removeItem(at: partial)
            throw ToolRepairError.verifyFailed
        }
        try atomicReplace(dest: dest, with: partial)
        session.recordCreatedIfAbsent(dest)
    }

    private func installGalleryDl(
        _ item: ToolSetupPlanItem,
        session: inout RepairSession,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        let dest = URL(fileURLWithPath: item.destination)
        // Honour an injected toolsDirectory so tests don't write into ~/Library.
        let pkgURL = seams.toolsDirectory.appendingPathComponent("gallery-dl-pkg", isDirectory: true)
        let pkgPartial = URL(fileURLWithPath: pkgURL.path + ".partial")
        let wrapperPartial = dest.appendingPathExtension("partial")
        session.forgetIfExists(pkgPartial)
        session.forgetIfExists(wrapperPartial)

        var python = await seams.resolvePython3()
        if python == nil {
            await onLine("No python3 with pip — downloading CPython from github.com/astral-sh…")
            python = try await bootstrapPython(session: &session)
        }
        guard let python else { throw ToolRepairError.pythonMissing }

        try? seams.fileManager.removeItem(at: pkgPartial)
        try seams.fileManager.createDirectory(at: pkgPartial, withIntermediateDirectories: true)
        await onLine("Installing gallery-dl from PyPI…")
        let pipCode = await seams.runProcess(
            python,
            [
                "-m", "pip", "install", "--disable-pip-version-check", "--no-cache-dir", "--upgrade",
                "--target", pkgPartial.path, "gallery-dl",
            ],
            nil)
        guard pipCode == 0 else {
            try? seams.fileManager.removeItem(at: pkgPartial)
            throw ToolRepairError.pipFailed
        }

        let wrapper = galleryDlWrapper(python: python, packageDir: pkgURL)
        try wrapper.write(to: wrapperPartial, atomically: true, encoding: .utf8)
        try markExecutable(wrapperPartial)
        guard await verifyItem(item, at: wrapperPartial.path) else {
            try? seams.fileManager.removeItem(at: pkgPartial)
            try? seams.fileManager.removeItem(at: wrapperPartial)
            throw ToolRepairError.verifyFailed
        }
        try atomicReplace(dest: pkgURL, with: pkgPartial)
        try atomicReplace(dest: dest, with: wrapperPartial)
        session.recordCreatedIfAbsent(dest)
        session.recordCreatedIfAbsent(pkgURL)
    }

    private func bootstrapPython(session: inout RepairSession) async throws -> String {
        let pythonDir = seams.toolsDirectory.appendingPathComponent("python", isDirectory: true)
        let existed = seams.fileManager.fileExists(atPath: pythonDir.path)
        if existed {
            let backup = URL(fileURLWithPath: pythonDir.path + ".pre-repair")
            try? seams.fileManager.removeItem(at: backup)
            try seams.fileManager.copyItem(at: pythonDir, to: backup)
        }
        let tarball = seams.toolsDirectory.appendingPathComponent("python.partial.tar.gz")
        let extractDir = seams.toolsDirectory.appendingPathComponent("python.partial.d", isDirectory: true)
        session.forgetIfExists(tarball)
        session.forgetIfExists(extractDir)
        let url = ToolSetupPlanner.pythonStandaloneURL(arch: seams.architecture())
        do {
            try await seams.download(url, tarball)
        } catch {
            try? seams.fileManager.removeItem(at: tarball)
            throw ToolRepairError.downloadFailed
        }
        do {
            try seams.fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try seams.extractTarGz(tarball, extractDir)
        } catch {
            try? seams.fileManager.removeItem(at: tarball)
            try? seams.fileManager.removeItem(at: extractDir)
            throw ToolRepairError.extractFailed
        }
        let extractedPython = extractDir.appendingPathComponent("python", isDirectory: true)
        guard seams.fileManager.fileExists(atPath: extractedPython.path) else {
            try? seams.fileManager.removeItem(at: tarball)
            try? seams.fileManager.removeItem(at: extractDir)
            throw ToolRepairError.extractFailed
        }
        if seams.fileManager.fileExists(atPath: pythonDir.path) {
            try seams.fileManager.removeItem(at: pythonDir)
        }
        try seams.fileManager.moveItem(at: extractedPython, to: pythonDir)
        try? seams.fileManager.removeItem(at: tarball)
        try? seams.fileManager.removeItem(at: extractDir)
        if !existed { session.createdPython = true }
        let binary = pythonDir.appendingPathComponent("bin/python3").path
        guard seams.fileManager.fileExists(atPath: binary) else { throw ToolRepairError.pythonMissing }
        return binary
    }

    private func galleryDlWrapper(python: String, packageDir: URL) -> String {
        """
        #!/bin/sh
        export PYTHONPATH="\(packageDir.path)${PYTHONPATH:+:$PYTHONPATH}"
        exec "\(python)" -m gallery_dl "$@"
        """
    }

    // MARK: - Verify / replace

    private func verifyItem(_ item: ToolSetupPlanItem, at path: String) async -> Bool {
        let args = RequirementsService.tool(withID: item.toolID)?.versionArguments ?? ["--version"]
        return await seams.verify(path, args)
    }

    private func markExecutable(_ url: URL) throws {
        try seams.fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func atomicReplace(dest: URL, with partial: URL) throws {
        let fm = seams.fileManager
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: partial, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: partial, to: dest)
        }
    }

    private func findExtractedBinary(named name: String, in dir: URL) -> URL? {
        let fm = seams.fileManager
        let direct = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) { return direct }
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for item in items {
            if item.lastPathComponent == name { return item }
            let nested = item.appendingPathComponent(name)
            if fm.fileExists(atPath: nested.path) { return nested }
        }
        return nil
    }

    private func brewBuckets(_ items: [ToolSetupPlanItem]) -> (
        missing: [ToolRequirement], broken: [ToolRequirement], outdated: [ToolRequirement]
    ) {
        var missing: [ToolRequirement] = []
        var broken: [ToolRequirement] = []
        var outdated: [ToolRequirement] = []
        for item in items {
            guard let tool = RequirementsService.tool(withID: item.toolID) else { continue }
            switch item.action {
            case .install: missing.append(tool)
            case .reinstall: broken.append(tool)
            case .update: outdated.append(tool)
            }
        }
        return (missing, broken, outdated)
    }

    private func describe(_ error: Error) -> String {
        if let repair = error as? ToolRepairError {
            switch repair {
            case .downloadFailed: return "download failed"
            case .extractFailed: return "couldn't extract the archive"
            case .verifyFailed: return "the new binary didn't run"
            case .pythonMissing: return "python3 is not available"
            case .pipFailed: return "pip install failed"
            case .ioFailed: return "couldn't write files"
            }
        }
        return error.localizedDescription
    }

    // MARK: - Rollback

    private func rollback(session: RepairSession, brewItems: [ToolSetupPlanItem]) async {
        session.rollbackStandaloneFully()
        for item in brewItems {
            guard let snap = session.snapshots.first(where: { $0.toolID == item.toolID }) else {
                continue
            }
            let dest = snap.dest
            let worse = await destIsWorse(dest)
            if case .file(let backup) = snap.previous, worse {
                try? restoreFile(from: backup, to: dest)
            } else if case .wasAbsent = snap.previous, worse {
                try? seams.fileManager.removeItem(at: dest)
            }
        }
    }

    private func destIsWorse(_ dest: URL) async -> Bool {
        guard seams.fileManager.fileExists(atPath: dest.path) else { return true }
        let id = dest.lastPathComponent
        let args = RequirementsService.tool(withID: id)?.versionArguments ?? ["--version"]
        return !(await seams.verify(dest.path, args))
    }

    private func restoreFile(from backup: URL, to dest: URL) throws {
        let fm = seams.fileManager
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try copyPreserving(from: backup, to: dest)
    }

    private func copyPreserving(from src: URL, to dst: URL) throws {
        try seams.fileManager.copyItem(at: src, to: dst)
        if let perms = try? seams.fileManager.attributesOfItem(atPath: src.path)[.posixPermissions] {
            try? seams.fileManager.setAttributes([.posixPermissions: perms], ofItemAtPath: dst.path)
        }
    }
}

// MARK: - Session (snapshots + staging)

private struct DestSnapshot {
    enum Previous {
        case wasAbsent
        case file(URL)
    }

    let toolID: String
    let dest: URL
    let installer: ToolInstallerKind
    let previous: Previous
    var extraBackups: [(dest: URL, backup: URL)]
    var extrasWereAbsent: [URL]
}

private struct RepairSession {
    let toolsDirectory: URL
    let fileManager: FileManager
    var snapshots: [DestSnapshot] = []
    var createdPython = false
    var staging: [URL] = []

    mutating func snapshotAll(_ items: [ToolSetupPlanItem]) throws {
        for item in items {
            try snapshot(item)
        }
    }

    mutating func snapshot(_ item: ToolSetupPlanItem) throws {
        let dest = URL(fileURLWithPath: item.destination)
        let previous: DestSnapshot.Previous
        if fileManager.fileExists(atPath: dest.path) {
            // Brew dests live outside Application Support — never write
            // siblings into /opt/homebrew/bin. Standalone dests keep a
            // sibling `.pre-repair` so tests can assert cleanup.
            let backup = backupURL(for: dest)
            try? fileManager.removeItem(at: backup)
            try copyContents(from: dest, to: backup)
            previous = .file(backup)
        } else {
            previous = .wasAbsent
        }

        var extraBackups: [(dest: URL, backup: URL)] = []
        var extrasWereAbsent: [URL] = []
        if item.toolID == "gallery-dl", item.installer == .standalone {
            let pkg = toolsDirectory.appendingPathComponent("gallery-dl-pkg", isDirectory: true)
            if fileManager.fileExists(atPath: pkg.path) {
                let backup = URL(fileURLWithPath: pkg.path + ".pre-repair")
                try? fileManager.removeItem(at: backup)
                try fileManager.copyItem(at: pkg, to: backup)
                extraBackups.append((pkg, backup))
            } else {
                extrasWereAbsent.append(pkg)
            }
        }
        snapshots.append(
            DestSnapshot(
                toolID: item.toolID, dest: dest, installer: item.installer, previous: previous,
                extraBackups: extraBackups, extrasWereAbsent: extrasWereAbsent))
    }

    mutating func forgetIfExists(_ url: URL) {
        staging.append(url)
        try? fileManager.removeItem(at: url)
    }

    mutating func recordCreatedIfAbsent(_ url: URL) {
        // Used only so rollback of a was-absent dest also knows extras; dest
        // itself is already in the snapshot.
        _ = url
    }

    func rollbackStandaloneFully() {
        for snap in snapshots.reversed() where snap.installer == .standalone {
            switch snap.previous {
            case .wasAbsent:
                try? fileManager.removeItem(at: snap.dest)
            case .file(let backup):
                try? fileManager.removeItem(at: snap.dest)
                try? copyContents(from: backup, to: snap.dest)
            }
            for extra in snap.extraBackups {
                try? fileManager.removeItem(at: extra.dest)
                try? fileManager.copyItem(at: extra.backup, to: extra.dest)
            }
            for extra in snap.extrasWereAbsent {
                try? fileManager.removeItem(at: extra)
            }
        }
        let pythonDir = toolsDirectory.appendingPathComponent("python", isDirectory: true)
        let pythonBackup = URL(fileURLWithPath: pythonDir.path + ".pre-repair")
        if createdPython {
            try? fileManager.removeItem(at: pythonDir)
        } else if fileManager.fileExists(atPath: pythonBackup.path) {
            try? fileManager.removeItem(at: pythonDir)
            try? fileManager.copyItem(at: pythonBackup, to: pythonDir)
        }
    }

    private func backupURL(for dest: URL) -> URL {
        let root = toolsDirectory.standardizedFileURL.path
        let path = dest.standardizedFileURL.path
        if path == root || path.hasPrefix(root + "/") {
            return dest.appendingPathExtension("pre-repair")
        }
        return toolsDirectory.appendingPathComponent(dest.lastPathComponent + ".pre-repair")
    }

    func cleanupStaging() {
        for snap in snapshots {
            try? fileManager.removeItem(at: snap.dest.appendingPathExtension("partial"))
            try? fileManager.removeItem(at: snap.dest.appendingPathExtension("partial.zip"))
            try? fileManager.removeItem(at: snap.dest.appendingPathExtension("partial.d"))
            try? fileManager.removeItem(at: snap.dest.appendingPathExtension("pre-repair"))
            if case .file(let backup) = snap.previous {
                try? fileManager.removeItem(at: backup)
            }
            for extra in snap.extraBackups {
                try? fileManager.removeItem(at: extra.backup)
            }
            for extra in snap.extrasWereAbsent {
                try? fileManager.removeItem(at: URL(fileURLWithPath: extra.path + ".partial"))
            }
        }
        for url in staging {
            try? fileManager.removeItem(at: url)
        }
        try? fileManager.removeItem(at: toolsDirectory.appendingPathComponent("python.partial.tar.gz"))
        try? fileManager.removeItem(
            at: toolsDirectory.appendingPathComponent("python.partial.d", isDirectory: true))
        try? fileManager.removeItem(
            at: URL(fileURLWithPath: toolsDirectory.appendingPathComponent("python").path + ".pre-repair"))
    }

    private func copyContents(from src: URL, to dst: URL) throws {
        var isDir: ObjCBool = false
        fileManager.fileExists(atPath: src.path, isDirectory: &isDir)
        if isDir.boolValue {
            try fileManager.copyItem(at: src, to: dst)
            return
        }
        let resolved = src.resolvingSymlinksInPath()
        try fileManager.copyItem(at: resolved, to: dst)
        if let perms = try? fileManager.attributesOfItem(atPath: resolved.path)[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: perms], ofItemAtPath: dst.path)
        }
    }
}

// MARK: - Production seams

extension ToolRepairRunner.Seams {
    static func production(toolsDirectory: URL = URL(fileURLWithPath: AppPaths.toolsDirectory()))
        -> ToolRepairRunner.Seams
    {
        ToolRepairRunner.Seams(
            toolsDirectory: toolsDirectory,
            download: { source, dest in
                try await Self.downloadFile(from: source, to: dest)
            },
            extractZip: { zip, dir in
                try Self.runAndWait(
                    "/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
            },
            extractTarGz: { tarball, dir in
                try Self.runAndWait(
                    "/usr/bin/tar", ["-xzf", tarball.path, "-C", dir.path])
            },
            verify: { path, arguments in
                guard FileManager.default.isExecutableFile(atPath: path) else { return false }
                guard
                    let line = await ToolHealthMonitor.probeVersionLine(
                        executablePath: path, arguments: arguments, timeout: 10)
                else { return false }
                return RequirementsService.parsedVersion(fromFirstLine: line) != nil
            },
            runProcess: { executable, arguments, environment in
                await Self.runProcess(executable, arguments, environment)
            },
            resolvePython3: {
                await Self.resolvePython3(toolsDirectory: toolsDirectory)
            },
            runBrew: { missing, broken, outdated, onLine in
                await RequirementsService.repairWithBrew(
                    missing: missing, broken: broken, outdated: outdated, onLine: onLine)
            })
    }

    static func downloadFile(from url: URL, to dest: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ToolRepairError.downloadFailed
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: temp, to: dest)
    }

    static func runAndWait(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw ToolRepairError.extractFailed }
    }

    static func runProcess(
        _ executable: String, _ arguments: [String], _ environment: [String: String]?
    ) async -> Int32 {
        await ProcessRunner.runRaw(
            executablePath: executable,
            arguments: arguments,
            environment: environment ?? ProcessInfo.processInfo.environment,
            onLine: { _ in })
    }

    static func resolvePython3(toolsDirectory: URL) async -> String? {
        let candidates = [
            toolsDirectory.appendingPathComponent("python/bin/python3").path,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        let fm = FileManager.default
        for path in candidates where fm.fileExists(atPath: path) {
            let version = await ProcessRunner.runRaw(
                executablePath: path,
                arguments: ["--version"],
                environment: ProcessInfo.processInfo.environment,
                onLine: { _ in })
            guard version == 0 else { continue }
            let pip = await ProcessRunner.runRaw(
                executablePath: path,
                arguments: ["-m", "pip", "--version"],
                environment: ProcessInfo.processInfo.environment,
                onLine: { _ in })
            if pip == 0 { return path }
        }
        return nil
    }
}
