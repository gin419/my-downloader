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

    /// True for a folder found on disk that a later run may write into:
    /// its path is tool-safe, and gallery-dl, handed the name, writes to
    /// exactly that folder. gallery-dl drops control characters from a
    /// folder name and trims whitespace around it, so a name holding
    /// either would send the post's files into a second folder of the
    /// cleaned name. Such a folder is passed over like one whose name
    /// holds a "$", and the tools pick their own.
    static func isReusable(_ folder: URL) -> Bool {
        let name = folder.lastPathComponent
        guard isToolSafe(folder.path), let first = name.unicodeScalars.first, let last = name.unicodeScalars.last
        else { return false }
        let edges = CharacterSet.whitespacesAndNewlines
        return !name.unicodeScalars.contains(where: isControl) && !edges.contains(first) && !edges.contains(last)
    }

    /// The characters gallery-dl removes from every path segment it makes
    /// (its "path-remove" default): U+0000 to U+001F and U+007F.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
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
        all(in: root, id: id).first
    }

    /// Every folder directly inside `root` whose name ends in " [<id>]", in
    /// name order: `existing` takes the first, and the end of a run looks
    /// for any the run made and left empty.
    static func all(in root: URL, id: String) -> [URL] {
        guard !id.isEmpty else { return [] }
        let suffix = " [\(id)]"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().filter { $0.hasSuffix(suffix) }.compactMap { name in
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return nil }
            return candidate
        }
    }

    /// The id an X or Instagram post's folder ends in, " [<id>]", read off
    /// the link: the tweet id, or the post's code. Nil for every other link,
    /// and for an Instagram share link, which carries no code. yt-dlp,
    /// gallery-dl and the fxtwitter rescue spell the rest of the name each
    /// their own way, so the id is what lets a later run find the folder.
    static func postID(of link: String) -> String? {
        switch SiteRegistry.profile(for: link).id {
        case SiteRegistry.twitter.id: return FxTwitterService.tweetID(from: link)
        case SiteRegistry.instagram.id: return InstagramLink.postCode(of: link)
        default: return nil
        }
    }

    /// Moves `file` into `folder` under its own name and returns where it
    /// went, or nil when it stayed where it was: the folder is not there,
    /// the name is taken in it, or the move failed. One rename that refuses
    /// to replace anything, so no file is ever overwritten, and a failure
    /// leaves the file untouched at its old path.
    static func moveIn(_ file: URL, to folder: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        let target = folder.appendingPathComponent(file.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        // RENAME_EXCL: the check above and the rename are not one step, and
        // a file arriving in between must fail the rename, not be replaced.
        guard renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) == 0 else { return nil }
        return target
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
