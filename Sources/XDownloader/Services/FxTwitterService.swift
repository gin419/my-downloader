import Foundation

/// Last-resort Twitter fallback. X's GraphQL endpoints sometimes hide tweets
/// from (typically spam-flagged) accounts — TweetDetail returns an empty
/// conversation and both yt-dlp and gallery-dl come up empty — while the
/// media itself stays publicly served from the twimg CDN. The fxtwitter
/// resolver (the same class of service Telegram/Discord downloader bots use)
/// still returns direct media URLs for those tweets, so fetch them with
/// URLSession. Only the tweet id is sent to fxtwitter.
enum FxTwitterService {

    /// Attempts to resolve and download the tweet's media. On full success
    /// sets the item to .completed and returns true. When it can't help at
    /// all it restores the item's prior status (keeping the more informative
    /// gallery-dl failure message) and returns false — with two truthful
    /// exceptions: some files saved but not all → a partial failure naming
    /// the counts and the reason (the saved files stay on the row); zero
    /// files saved because the destination disk is full or unwritable → a
    /// disk failure, because restoring the prior "No media found…" message
    /// would blame the tweet for a local problem.
    @MainActor
    static func run(item: DownloadItem, outputDirectory: URL) async -> Bool {
        guard let id = tweetID(from: item.url) else { return false }

        let priorStatus = item.status
        item.status = .fetching

        guard let tweet = await fetchTweet(id: id) else {
            item.status = priorStatus
            return false
        }

        let nick = (tweet["author"] as? [String: Any])?["name"] as? String ?? "twitter"
        let text = tweet["text"] as? String ?? ""
        let media = ((tweet["media"] as? [String: Any])?["all"] as? [[String: Any]]) ?? []

        var urls: [(url: URL, isVideo: Bool)] = []
        for m in media {
            guard let type = m["type"] as? String,
                var raw = m["url"] as? String
            else { continue }
            let isVideo = (type == "video" || type == "gif")
            // pbs.twimg.com photo URLs default to a downscaled variant;
            // ?name=orig requests the original resolution.
            if !isVideo && !raw.contains("?") { raw += "?name=orig" }
            if let u = URL(string: raw) { urls.append((u, isVideo)) }
        }
        guard !urls.isEmpty else {
            item.status = priorStatus
            return false
        }

        // Mirror gallery-dl's filename scheme (see GalleryDlService.formatArgs)
        // so re-downloads of the same tweet dedupe across both backends.
        let stemBase = sanitize("\(nick) - \(String(text.prefix(100))) [\(id)]")

        var savedPaths: [String] = []
        var imageCount = 0
        var videoCount = 0
        // A per-file failure must not silently shrink the file count under a
        // green "Done" — remember the last one so the final message can name
        // a concrete reason.
        var lastFailure: FileFailure?

        for (index, entry) in urls.enumerated() {
            // Stop cancels the wrapping Task (see DownloadManager) — bail out
            // between files; an in-flight URLSession download throws
            // CancellationError and is caught below.
            if Task.isCancelled {
                item.status = priorStatus
                return false
            }
            let ext =
                entry.isVideo
                ? "mp4"
                : (entry.url.pathExtension.isEmpty ? "jpg" : entry.url.pathExtension.lowercased())
            let name = "\(stemBase) #\(index + 1).\(ext)"
            let dest = outputDirectory.appendingPathComponent(name)

            if !FileManager.default.fileExists(atPath: dest.path) {
                item.status = .downloading
                let tmp: URL
                do {
                    let (downloaded, response) = try await URLSession.shared.download(from: entry.url)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // The CDN answered with an error page, not the file —
                        // saving it would masquerade as media (e.g. a twimg
                        // 404 for since-removed media).
                        try? FileManager.default.removeItem(at: downloaded)
                        lastFailure = .httpStatus(http.statusCode)
                        continue
                    }
                    tmp = downloaded
                } catch {
                    lastFailure = .transport(error)
                    continue
                }
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                } catch {
                    // Don't strand the downloaded bytes in the temp dir when the
                    // move fails (e.g. destination volume full or unwritable).
                    try? FileManager.default.removeItem(at: tmp)
                    lastFailure = .move(error)
                    continue
                }
            }
            savedPaths.append(dest.path)
            if entry.isVideo { videoCount += 1 } else { imageCount += 1 }
        }

        guard !Task.isCancelled, let first = savedPaths.first else {
            if !Task.isCancelled, let message = Self.zeroSavedFailureMessage(lastFailure: lastFailure) {
                // Every file failed on a LOCAL disk problem: restoring the
                // prior "No media found…" message would blame the tweet.
                // This failure owns the outcome — a leftover empty-success
                // flag must not arm the auto-retry for a disk that a re-run
                // cannot fix.
                item.emptySuccessFailure = false
                item.status = .failed(message)
            } else {
                item.status = priorStatus
            }
            return false
        }

        item.outputPath = savedPaths.first { !MediaExtensions.image.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) } ?? first
        item.imageCount = imageCount > 0 ? imageCount : nil
        item.videoCount = videoCount > 0 ? videoCount : nil
        item.recomputeMediaCategory()
        if item.title == nil {
            let t = "\(nick) - \(String(text.prefix(100)))".trimmingCharacters(in: .whitespacesAndNewlines)
            item.title = t.hasSuffix("-") ? String(t.dropLast()).trimmingCharacters(in: .whitespaces) : t
        }
        if let lastFailure {
            // Some files failed: keep the saved ones on the row, but the run
            // must not read as a clean "Done" with a silently smaller count.
            // This partial failure owns the outcome, so a leftover
            // empty-success flag must not arm the auto-retry — its reset
            // would wipe the saved counts off the row.
            item.emptySuccessFailure = false
            item.status = .failed(
                Self.partialFailureMessage(
                    saved: savedPaths.count, attempted: urls.count, lastFailure: lastFailure))
            return false
        }
        item.markCompleted()
        return true
    }

    // MARK: - Per-file outcome truth

    /// Why one file of the tweet's media set failed to reach the download
    /// folder. The loop keeps the LAST one: with several failed files it is
    /// the freshest evidence, and a disk-full cascade fails every move the
    /// same way.
    enum FileFailure {
        /// The CDN answered, but not with the file (e.g. a twimg 404 for
        /// since-removed media).
        case httpStatus(Int)
        /// The transfer itself failed (offline, timeout, dropped connection).
        case transport(Error)
        /// The downloaded bytes couldn't be moved into the download folder.
        case move(Error)
    }

    /// True for the CocoaError codes `moveItem` throws when the destination
    /// volume is full or not writable — a LOCAL cause no retry against the
    /// CDN can fix, and one the tweet must never be blamed for.
    static func isDiskWriteError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == CocoaError.fileWriteOutOfSpace.rawValue
            || nsError.code == CocoaError.fileWriteNoPermission.rawValue
    }

    /// Zero files saved AND every byte already downloaded had nowhere to go:
    /// name the disk, not the tweet.
    static let diskUnwritableMessage =
        "The download folder's disk is full or not writable — free space or fix permissions, then Retry."

    /// Short human-readable cause embedded in the partial-failure message.
    static func shortReason(for failure: FileFailure) -> String {
        switch failure {
        case .httpStatus(let code):
            return "the server returned HTTP \(code)"
        case .transport(let error):
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain else {
                return "a network error interrupted the transfer"
            }
            switch nsError.code {
            case NSURLErrorTimedOut: return "the connection timed out"
            case NSURLErrorNotConnectedToInternet: return "the network is offline"
            case NSURLErrorNetworkConnectionLost: return "the connection was lost mid-transfer"
            default: return "a network error interrupted the transfer"
            }
        case .move(let error):
            return isDiskWriteError(error)
                ? "the download folder's disk is full or not writable"
                : "the file couldn't be saved to the download folder"
        }
    }

    /// Some files landed, some didn't. Retry is dedup-safe — existing files
    /// are skipped — so it only fetches the rest.
    static func partialFailureMessage(saved: Int, attempted: Int, lastFailure: FileFailure) -> String {
        "Downloaded \(saved) of \(attempted) files — \(shortReason(for: lastFailure)). Retry fetches the rest."
    }

    /// Zero files saved: only a disk write error is a LOCAL cause that must
    /// replace the restored (tweet-blaming) prior message; anything else
    /// returns nil and keeps the prior, more informative failure.
    static func zeroSavedFailureMessage(lastFailure: FileFailure?) -> String? {
        guard case .move(let error)? = lastFailure, isDiskWriteError(error) else { return nil }
        return diskUnwritableMessage
    }

    // MARK: - Private

    private static func tweetID(from url: String) -> String? {
        guard let r = url.range(of: #"/status/(\d+)"#, options: .regularExpression) else { return nil }
        return String(url[r]).components(separatedBy: "/").last
    }

    private static func fetchTweet(id: String) async -> [String: Any]? {
        guard let url = URL(string: "https://api.fxtwitter.com/i/status/\(id)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("XDownloader/1.4 (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["code"] as? Int == 200,
            let tweet = json["tweet"] as? [String: Any]
        else { return nil }
        return tweet
    }

    /// Keep filenames in step with what gallery-dl produces for the same
    /// tweet: path separators become "_", newlines collapse to spaces.
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
