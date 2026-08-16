import Foundation

extension FileManager {
    /// `~/Library/Application Support/XDownloader`, created if needed. The single
    /// source of the app-support directory (used by QueueStore + HistoryStore).
    func xdownloaderAppSupportDir() -> URL {
        let base =
            urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("XDownloader", isDirectory: true)
        try? createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Path strings under Application Support. These do not create directories —
/// catalogue search paths must not mkdir as a side effect of being read.
enum AppPaths {
    static func applicationSupportDirectory(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        "\(home)/Library/Application Support/XDownloader"
    }

    static func toolsDirectory(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        applicationSupportDirectory(home: home) + "/tools"
    }

    static func appManagedToolPath(
        _ toolID: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        toolsDirectory(home: home) + "/\(toolID)"
    }

    /// pip `--target` dir for the app-managed gallery-dl install. Separate
    /// from the wrapper at `appManagedToolPath("gallery-dl")`.
    static func galleryDlPackageDirectory(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        toolsDirectory(home: home) + "/gallery-dl-pkg"
    }

    static func bundledPythonDirectory(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        toolsDirectory(home: home) + "/python"
    }
}

/// Homebrew locations, shared so ProcessRunner and RequirementsService don't drift.
enum Homebrew {
    /// Homebrew bin/sbin prefixes (Apple Silicon + Intel).
    static let binPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
    /// A full PATH with Homebrew first, then the standard system dirs.
    static let fullPATH = "\(binPaths):/usr/bin:/bin:/usr/sbin:/sbin"

    /// PATH truth for child processes: Homebrew dirs, then the parent
    /// directory of every RESOLVED catalogue tool (deduped, order-stable),
    /// then the inherited PATH (or the standard system dirs when it's empty).
    /// The probe certifies tools wherever the shared resolver finds them
    /// (pipx, MacPorts, ~/.deno/bin, python framework bins); without this,
    /// yt-dlp/gallery-dl child processes could not exec the SAME deno/ffmpeg
    /// the banner just called healthy.
    static func launchPATH(toolPaths: [String], existingPath: String) -> String {
        var dirs = binPaths.split(separator: ":").map(String.init)
        var seen = Set(dirs)
        for toolPath in toolPaths {
            let dir = (toolPath as NSString).deletingLastPathComponent
            guard !dir.isEmpty, seen.insert(dir).inserted else { continue }
            dirs.append(dir)
        }
        let prefix = dirs.joined(separator: ":")
        return existingPath.isEmpty
            ? "\(prefix):/usr/bin:/bin:/usr/sbin:/sbin"
            : "\(prefix):\(existingPath)"
    }
}
