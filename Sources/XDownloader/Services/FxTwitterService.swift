import Foundation

/// Last-resort Twitter fallback. X's GraphQL endpoints sometimes hide tweets
/// from (typically spam-flagged) accounts — TweetDetail returns an empty
/// conversation and both yt-dlp and gallery-dl come up empty — while the
/// media itself stays publicly served from the twimg CDN. The fxtwitter
/// resolver (the same class of service Telegram/Discord downloader bots use)
/// still returns direct media URLs for those tweets, so fetch them with
/// URLSession. Only the tweet id is sent to fxtwitter.
enum FxTwitterService {

    /// Attempts to resolve and download the tweet's media. On success sets the
    /// item to .completed and returns true. On any failure restores the item's
    /// prior status (keeping the more informative gallery-dl failure message)
    /// and returns false.
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

        for (index, entry) in urls.enumerated() {
            // Stop cancels the wrapping Task (see DownloadManager) — bail out
            // between files; an in-flight URLSession download throws
            // CancellationError and falls through the try? below.
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
                guard let tmp = try? await URLSession.shared.download(from: entry.url).0,
                    (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
                else {
                    continue
                }
            }
            savedPaths.append(dest.path)
            if entry.isVideo { videoCount += 1 } else { imageCount += 1 }
        }

        guard !Task.isCancelled, let first = savedPaths.first else {
            item.status = priorStatus
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
        item.status = .completed
        item.progress = 1.0
        item.speed = nil
        item.eta = nil
        return true
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
