import Foundation

/// Where a row's files go. A row that produces two or more files gets a
/// folder of its own inside the download folder; a one-file row stays loose
/// there, as it always has. The folder is settled before the first file is
/// written and derives from what the post declares, not from what arrived,
/// so a partial run and its Retry meet in the same place and every writer's
/// own "already there" check does the dedupe. Nothing written before
/// folders existed is ever moved: a loose file stays where it is.
enum RowFolder {

    /// The folder `name` inside the download folder for a row of two or
    /// more files, nil for a one-file row, which stays loose. The count is
    /// the post's declared one, so a post that saved one file of three
    /// still gets its folder.
    static func folder(in root: URL, name: String, fileCount: Int) -> URL? {
        fileCount >= 2 ? root.appendingPathComponent(name, isDirectory: true) : nil
    }

    /// A folder name the app makes up from a file stem, safe to hand to a
    /// tool. yt-dlp expands "$VAR" in its output template and gallery-dl in
    /// its destination, and both inherit the app's environment (HOME, USER,
    /// TMPDIR…): a stem holding "$HOME" would send the files elsewhere. A
    /// "$" has no escape there, so it becomes its full-width twin, exactly
    /// as in the clip's own file name (`YtDlpService.literalTemplateText`).
    /// The stem is already sanitised, has no leading dot and is capped in
    /// bytes by the resolver that made it.
    static func appNamed(_ stem: String) -> String {
        stem.replacingOccurrences(of: "$", with: "＄")
    }

    /// False for a path a tool would expand an environment variable in. A
    /// folder the app did not name itself — one found on disk — is never
    /// handed to a tool when this is false: the tool picks its own.
    static func isToolSafe(_ path: String) -> Bool {
        !path.contains("$")
    }

    /// The directory part of a yt-dlp output template. "%" opens a field
    /// there, so a folder named "50% off" would be read as a broken one;
    /// doubled, it is a plain percent sign. A path without "%" comes out
    /// exactly as it went in.
    static func templateDirectory(_ url: URL) -> String {
        url.path.replacingOccurrences(of: "%", with: "%%")
    }

    /// A folder directly inside `root` whose name ends in " [<id>]" — the
    /// suffix every post folder carries — or nil. Files are ignored, and so
    /// is every longer id that merely ends in the same digits: the bracket
    /// must open right before it. One directory listing, no request.
    static func existing(in root: URL, id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        let suffix = " [\(id)]"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names.sorted() where name.hasSuffix(suffix) {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// Removes `url` when this run created it and nothing is in it: a tool
    /// can make its folder before the first byte arrives (yt-dlp does), and
    /// a run that then saved nothing must not leave an empty folder behind.
    /// Finder's own ".DS_Store" does not count as content. A folder that
    /// was there before the run is never touched, whatever it holds. The
    /// removal is a plain rmdir, which fails on anything that is not empty,
    /// so a file landing in the meantime is never lost. Returns true when
    /// the folder was removed.
    @discardableResult
    static func removeIfEmpty(_ url: URL, createdThisRun: Bool) -> Bool {
        guard createdThisRun else { return false }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        guard names.isEmpty || names == [finderMetadata] else { return false }
        if names == [finderMetadata] {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(finderMetadata))
        }
        return rmdir(url.path) == 0
    }

    private static let finderMetadata = ".DS_Store"

    /// A reported path with the doubled separator a template leaves when its
    /// folder segment is empty ("<root>//<name>.mp4"): the same file, and
    /// the same string the row recorded before folders existed.
    static func normalized(_ path: String) -> String {
        var result = path
        while result.contains("//") {
            result = result.replacingOccurrences(of: "//", with: "/")
        }
        return result
    }

    /// Points the row at `folder` (nil: the download folder itself) and
    /// notes whether the folder was already on disk, which is what decides
    /// whether the run may remove it again when it ends empty. Setting the
    /// same folder again within one run keeps the first note: a re-run of
    /// the same row (the subtitle retry, say) must not take a folder the
    /// first pass created for one that was there before.
    @MainActor
    static func use(_ folder: URL?, for item: DownloadItem) {
        guard folder?.standardizedFileURL != item.destination?.standardizedFileURL else { return }
        item.destination = folder
        item.destinationExistedAtStart = folder.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
}
