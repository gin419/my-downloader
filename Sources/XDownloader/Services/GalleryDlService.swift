import Foundation

enum GalleryDlService {

    // MARK: - Download

    @MainActor
    static func run(
        item: DownloadItem,
        executablePath: String,
        outputDirectory: URL,
        cookieBrowser: CookieBrowser,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void
    ) async {
        let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? [])

        var args = cookieArgs(cookieBrowser)
        args += [
            "--dest", outputDirectory.path,
            "-D", ".",
            "-f", "{author[nick]} - {content:.100} #{num}.{extension}",
            "--no-mtime",
            item.url,
        ]

        let exitCode = await runProcess(
            executablePath: executablePath,
            arguments: args,
            item: item,
            register: register,
            unregister: unregister,
            lineParser: { line, item in parseLine(line, item: item) }
        )

        guard exitCode == 0 else {
            if case .failed = item.status { } else {
                item.status = .failed("gallery-dl exit code \(exitCode)")
            }
            return
        }

        // Detect newly created media files since the download started.
        let imageExts = Set(["jpg", "jpeg", "png", "webp", "gif", "avif"])
        let videoExts = Set(["mp4", "mov", "webm", "mkv", "m4v"])
        let afterFiles = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []

        func ext(_ name: String) -> String { URL(fileURLWithPath: name).pathExtension.lowercased() }
        let newImages = afterFiles.filter { !beforeFiles.contains($0) && imageExts.contains(ext($0)) }.sorted()
        let newVideos = afterFiles.filter { !beforeFiles.contains($0) && videoExts.contains(ext($0)) }.sorted()

        if item.outputPath == nil {
            let candidate = newImages.first ?? newVideos.first
            if let first = candidate {
                item.outputPath = outputDirectory.appendingPathComponent(first).path
            } else {
                // File already existed (gallery-dl skipped it) — resolve path via dry run.
                item.outputPath = await dryRunPath(
                    executablePath: executablePath,
                    item: item,
                    outputDirectory: outputDirectory,
                    cookieBrowser: cookieBrowser,
                    register: register,
                    unregister: unregister
                )
            }
        }

        if !newImages.isEmpty { item.imageCount = newImages.count }
        if !newVideos.isEmpty { item.videoCount = newVideos.count }

        // "File already existed" path: parseLine never fired, so infer count from outputPath extension.
        if newImages.isEmpty && newVideos.isEmpty, let path = item.outputPath {
            let e = ext(path)
            if imageExts.contains(e) && (item.imageCount ?? 0) == 0 { item.imageCount = 1 }
            if videoExts.contains(e) && (item.videoCount ?? 0) == 0 { item.videoCount = 1 }
        }

        // Sync category from final counts (overrides whatever parseLine may have set).
        let hasImg = (item.imageCount ?? 0) > 0
        let hasVid = (item.videoCount ?? 0) > 0
        if hasImg && hasVid       { item.mediaCategory = .mixed }
        else if hasImg            { item.mediaCategory = .image }
        else if hasVid            { item.mediaCategory = .video }

        // Rename single-image files: strip trailing " #1" suffix.
        if newImages.count == 1, let path = item.outputPath {
            let u = URL(fileURLWithPath: path)
            let stem = u.deletingPathExtension().lastPathComponent
            if stem.hasSuffix(" #1") {
                let clean = String(stem.dropLast(3))
                let newPath = u.deletingLastPathComponent()
                    .appendingPathComponent(clean + "." + u.pathExtension).path
                if (try? FileManager.default.moveItem(atPath: path, toPath: newPath)) != nil {
                    item.outputPath = newPath
                    item.title = clean
                }
            }
        }

        if item.title == nil, let path = item.outputPath {
            item.title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }

        item.status   = .completed
        item.progress = 1.0
        item.speed    = nil
        item.eta      = nil
    }

    // MARK: - Output parsing

    @MainActor
    static func parseLine(_ line: String, item: DownloadItem) {
        guard !line.isEmpty else { return }

        // gallery-dl prints the downloaded file path on its own line.
        // Filter out Python/urllib3 warning lines (they also start with "/" but contain ": ").
        if line.hasPrefix("/") || line.hasPrefix("~") {
            let ext = (line as NSString).pathExtension.lowercased()
            let knownMedia = ["jpg", "jpeg", "png", "webp", "gif", "avif", "mp4", "mov", "webm", "m4a", "mp3"]
            guard knownMedia.contains(ext) else { return }

            let isImage = ["jpg", "jpeg", "png", "webp", "gif", "avif"].contains(ext)
            let isVideo = ["mp4", "mov", "webm", "mkv", "m4v"].contains(ext)
            item.status     = .downloading
            item.outputPath = line
            if isImage {
                item.imageCount = (item.imageCount ?? 0) + 1
            } else if isVideo {
                item.videoCount = (item.videoCount ?? 0) + 1
            }
            // Update category progressively
            let hasImg = (item.imageCount ?? 0) > 0
            let hasVid = (item.videoCount ?? 0) > 0
            if hasImg && hasVid       { item.mediaCategory = .mixed }
            else if hasImg            { item.mediaCategory = .image }
            else if hasVid            { item.mediaCategory = .video }

            if item.title == nil {
                var stem = URL(fileURLWithPath: line).deletingPathExtension().lastPathComponent
                if let r = stem.range(of: #"_\d+$"#, options: .regularExpression) {
                    stem = String(stem[..<r.lowerBound])
                }
                item.title = stem
            }
            return
        }

        if line.lowercased().contains("error") {
            if case .failed = item.status { return }
            item.status = .failed(line)
        }
    }

    // MARK: - Private helpers

    /// Run gallery-dl in print-only mode to discover the expected output path
    /// without re-downloading. Used when a file was already present and skipped.
    @MainActor
    private static func dryRunPath(
        executablePath: String,
        item: DownloadItem,
        outputDirectory: URL,
        cookieBrowser: CookieBrowser,
        register: @escaping (Process) -> Void,
        unregister: @escaping () -> Void
    ) async -> String? {
        var args = cookieArgs(cookieBrowser)
        args += [
            "--dest", outputDirectory.path,
            "-D", ".",
            "-f", "{author[nick]} - {content:.100} #{num}.{extension}",
            "--print", "filepath",
            item.url,
        ]

        var foundPath: String?
        await runProcess(
            executablePath: executablePath,
            arguments: args,
            item: item,
            register: register,
            unregister: unregister,
            lineParser: { line, _ in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("/"), foundPath == nil { foundPath = trimmed }
            }
        )

        guard let p = foundPath else { return nil }

        // Prefer the renamed (no " #1") version when it exists.
        let u = URL(fileURLWithPath: p)
        let stem = u.deletingPathExtension().lastPathComponent
        if stem.hasSuffix(" #1") {
            let clean = u.deletingLastPathComponent()
                .appendingPathComponent(String(stem.dropLast(3)) + "." + u.pathExtension).path
            if FileManager.default.fileExists(atPath: clean) { return clean }
        }
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    private static func cookieArgs(_ browser: CookieBrowser) -> [String] {
        browser != .none ? ["--cookies-from-browser", browser.rawValue] : []
    }
}
