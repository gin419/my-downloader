import Foundation

/// What the in-app resolvers share once they hold direct media addresses:
/// the per-file outcome wording, the file name sanitizer, and a download
/// routine with live progress. It started life inside FxTwitterService; a
/// second resolver (Threads) needs the same truth about partial results, so
/// it lives here and both go through it.
enum DirectDownload {

    // MARK: - Per-file outcome truth

    /// Why one file of a post's media set failed to reach the download
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
    /// CDN can fix, and one the post must never be blamed for.
    static func isDiskWriteError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == CocoaError.fileWriteOutOfSpace.rawValue
            || nsError.code == CocoaError.fileWriteNoPermission.rawValue
    }

    /// Zero files saved AND every byte already downloaded had nowhere to go:
    /// name the disk, not the post.
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

    /// Some of the post's files are on disk, some aren't. `saved` counts
    /// what is ON DISK (this run's downloads AND dedupe-skipped files from
    /// earlier runs) — so the verb is "Saved", never "Downloaded": a retry
    /// that skipped 3 existing files and failed the 4th downloaded nothing.
    /// Retry is dedup-safe — existing files are skipped — so it only fetches
    /// the rest.
    static func partialFailureMessage(saved: Int, attempted: Int, lastFailure: FileFailure) -> String {
        "Saved \(saved) of \(attempted) files — \(shortReason(for: lastFailure)). Retry fetches the rest."
    }

    /// Zero files saved: only a disk write error is a LOCAL cause that must
    /// replace whatever the resolver would otherwise say about the post;
    /// anything else returns nil and leaves the message to the caller.
    static func zeroSavedFailureMessage(lastFailure: FileFailure?) -> String? {
        guard case .move(let error)? = lastFailure, isDiskWriteError(error) else { return nil }
        return diskUnwritableMessage
    }

    // MARK: - File names

    /// Keep filenames in step with what gallery-dl produces for the same
    /// post: path separators become "_", newlines collapse to spaces.
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The file a previous run saved under `baseName`, whatever its
    /// extension. The extension is only known once the server has answered
    /// (see `fileExtension`), so the re-download check can't test one fixed
    /// name.
    static func existingFile(baseName: String, in directory: URL) -> URL? {
        for ext in MediaExtensions.all.sorted() {
            let candidate = directory.appendingPathComponent("\(baseName).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Extension for a downloaded file: the response's content type first,
    /// then the file's leading bytes, nil when neither is recognised. Never
    /// taken from the address — an image served from a ".jpg" path can
    /// arrive as WebP, and a wrong extension mislabels the file for every
    /// viewer that trusts it.
    static func fileExtension(contentType: String?, leadingBytes: Data) -> String? {
        if let contentType {
            // "image/webp; charset=binary" → "image/webp"
            let mime = (contentType.split(separator: ";").first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            if let ext = extensionsByContentType[mime] { return ext }
        }
        return fileExtension(leadingBytes: leadingBytes)
    }

    private static let extensionsByContentType: [String: String] = [
        "image/jpeg": "jpg",
        "image/jpg": "jpg",
        "image/png": "png",
        "image/webp": "webp",
        "image/gif": "gif",
        "image/avif": "avif",
        "video/mp4": "mp4",
        "video/quicktime": "mov",
        "video/webm": "webm",
    ]

    /// How many leading bytes `fileExtension` needs: the longest signature
    /// (WebP, and the brand of an MP4-family file) ends at byte 12.
    static let signatureLength = 12

    private static func fileExtension(leadingBytes: Data) -> String? {
        let bytes = [UInt8](leadingBytes.prefix(signatureLength))
        func ascii(_ range: Range<Int>) -> String? {
            guard bytes.count >= range.upperBound else { return nil }
            return String(bytes: bytes[range], encoding: .ascii)
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        if ascii(0..<4) == "GIF8" { return "gif" }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" { return "webp" }
        if ascii(4..<8) == "ftyp", let brand = ascii(8..<12) {
            // One container family, told apart by the brand that follows.
            switch brand {
            case "avif", "avis": return "avif"
            case "qt  ": return "mov"
            default: return "mp4"
            }
        }
        return nil
    }

    // MARK: - Progress text

    /// Byte count in the text form yt-dlp prints ("15.42MiB"), which is what
    /// `DownloadItem.totalBytes` and the row already read — a second format
    /// would need a second parser.
    static func sizeText(_ bytes: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(max(bytes, 0))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%.2f", value) + units[unit]
    }

    /// Transfer rate in the text form yt-dlp prints ("1.23MiB/s"), read back
    /// by `MenuBarState.parseSpeed` for the menu bar total.
    static func speedText(bytesPerSecond: Double) -> String {
        let rate = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        return sizeText(Int64(rate.rounded())) + "/s"
    }

    // MARK: - Download

    /// How one file's download ended.
    enum Outcome {
        /// The file is in the download folder under this name.
        case saved(URL)
        case failed(FileFailure)
        /// The wrapping Task was cancelled (Stop / remove). Nothing was
        /// saved, and it is not a failure to report.
        case cancelled
    }

    /// Longest silence tolerated from the server, waiting for the response
    /// or between two pieces of the file. Without it a stalled transfer
    /// holds one of the few download slots for good.
    static let requestTimeout: TimeInterval = 30

    /// Seconds between two progress updates: about 4 per second, enough for
    /// a smooth bar without redrawing the row on every network packet.
    static let progressInterval: TimeInterval = 0.25

    /// The session downloads use unless one is injected. It keeps nothing
    /// and sends nothing of the user's: media addresses are signed and need
    /// no login, so no cookie may ever travel to a CDN host.
    static let session: URLSession = URLSession(configuration: sessionConfiguration())

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        return configuration
    }

    static func request(for url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpShouldHandleCookies = false
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    /// Downloads one file of a post into `directory` as
    /// "<baseName>.<extension>" and reports progress on `item`.
    ///
    /// The bytes go to a temporary file that is moved into place only when
    /// the transfer is complete: a partial file at the final name would be
    /// counted as already saved by the next run's re-download check. The
    /// temporary file is removed on every other exit, cancel included.
    ///
    /// Progress is written only while the item is `.downloading` — the
    /// caller sets that status — so a late update can never touch a row
    /// that has been paused, failed or finished in the meantime. No ETA is
    /// set: the sizes of the files still to come are unknown, so any figure
    /// for a multi-file post would be invented.
    ///
    /// `temporaryDirectory` is a seam for tests; by default the system picks
    /// a scratch folder on the download folder's own volume.
    @MainActor
    static func download(
        _ url: URL,
        headers: [String: String] = [:],
        to directory: URL,
        baseName: String,
        fallbackExtension: String,
        item: DownloadItem,
        fileIndex: Int,
        fileCount: Int,
        session: URLSession = DirectDownload.session,
        temporaryDirectory: URL? = nil
    ) async -> Outcome {
        let scratch = Scratch(for: directory, override: temporaryDirectory)
        defer {
            scratch.remove()
            if case .downloading = item.status { item.speed = nil }
        }

        let files = max(fileCount, 1)
        let result = await transfer(request: request(for: url, headers: headers), session: session, to: scratch.file) { progress in
            await MainActor.run {
                guard case .downloading = item.status else { return }
                if let expected = progress.expected {
                    let fraction = min(Double(progress.received) / Double(expected), 1)
                    item.progress = min((Double(fileIndex) + fraction) / Double(files), 1)
                    item.totalSize = sizeText(expected)
                }
                item.speed = speedText(bytesPerSecond: progress.bytesPerSecond)
            }
        }

        let fetched: Fetched
        switch result {
        case .success(let value): fetched = value
        case .failure(let stop):
            switch stop {
            case .cancelled: return .cancelled
            case .failed(let failure): return .failed(failure)
            }
        }
        // A cancel that lands after the last byte must still save nothing:
        // the row is being stopped or removed.
        if Task.isCancelled { return .cancelled }

        let ext = fileExtension(contentType: fetched.contentType, leadingBytes: fetched.leadingBytes) ?? fallbackExtension
        let destination = directory.appendingPathComponent("\(baseName).\(ext)")
        do {
            try FileManager.default.moveItem(at: scratch.file, to: destination)
        } catch {
            return .failed(.move(error))
        }
        if case .downloading = item.status {
            item.progress = min(Double(fileIndex + 1) / Double(files), 1)
            item.totalSize = sizeText(fetched.byteCount)
        }
        return .saved(destination)
    }

    // MARK: - Private

    /// Where one download's bytes wait until they are complete.
    private struct Scratch {
        let file: URL
        /// The folder created for this download alone, removed with it.
        private let ownedDirectory: URL?

        init(for destinationDirectory: URL, override: URL?) {
            let name = "xdownloader-\(UUID().uuidString).part"
            if let override {
                file = override.appendingPathComponent(name)
                ownedDirectory = nil
                return
            }
            // A scratch folder on the destination's own volume makes the
            // final move a rename, which either happens or doesn't; across
            // volumes it is a copy that can stop halfway.
            let created = try? FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destinationDirectory, create: true)
            ownedDirectory = created
            file = (created ?? FileManager.default.temporaryDirectory).appendingPathComponent(name)
        }

        func remove() {
            try? FileManager.default.removeItem(at: ownedDirectory ?? file)
        }
    }

    private struct Progress {
        let received: Int64
        /// nil when the server didn't state the file's size.
        let expected: Int64?
        let bytesPerSecond: Double
    }

    private struct Fetched {
        let byteCount: Int64
        let contentType: String?
        let leadingBytes: Data
    }

    private enum Stop: Error {
        case cancelled
        case failed(FileFailure)
    }

    /// Marks an error as coming from the local file rather than the network,
    /// so a full disk is never reported as a dropped connection.
    private struct WriteError: Error {
        let underlying: Error
    }

    private static let chunkSize = 64 * 1024

    /// Streams the response body into `file`. Runs off the main actor: a
    /// large video is millions of loop turns, and they must not compete
    /// with the interface for the main thread.
    nonisolated private static func transfer(
        request: URLRequest,
        session: URLSession,
        to file: URL,
        report: @escaping @Sendable (Progress) async -> Void
    ) async -> Result<Fetched, Stop> {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            return .failure(isCancellation(error) ? .cancelled : .failed(.transport(error)))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The CDN answered with an error page, not the file — saving it
            // would masquerade as media.
            bytes.task.cancel()
            return .failure(.failed(.httpStatus(http.statusCode)))
        }

        let handle: FileHandle
        do {
            try Data().write(to: file)
            handle = try FileHandle(forWritingTo: file)
        } catch {
            bytes.task.cancel()
            return .failure(.failed(.move(error)))
        }
        defer { try? handle.close() }

        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var leadingBytes = Data()
        var received: Int64 = 0
        var lastReport = ProcessInfo.processInfo.systemUptime
        var receivedAtLastReport: Int64 = 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            if leadingBytes.count < signatureLength {
                leadingBytes.append(buffer.prefix(signatureLength - leadingBytes.count))
            }
            do {
                try handle.write(contentsOf: buffer)
            } catch {
                throw WriteError(underlying: error)
            }
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
        }

        do {
            for try await byte in bytes {
                buffer.append(byte)
                guard buffer.count >= chunkSize else { continue }
                try Task.checkCancellation()
                try flush()
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastReport >= progressInterval {
                    let rate = Double(received - receivedAtLastReport) / (now - lastReport)
                    lastReport = now
                    receivedAtLastReport = received
                    await report(Progress(received: received, expected: expected, bytesPerSecond: rate))
                }
            }
            try Task.checkCancellation()
            try flush()
        } catch let error as WriteError {
            bytes.task.cancel()
            return .failure(.failed(.move(error.underlying)))
        } catch {
            bytes.task.cancel()
            return .failure(isCancellation(error) ? .cancelled : .failed(.transport(error)))
        }
        return .success(Fetched(byteCount: received, contentType: response.mimeType, leadingBytes: leadingBytes))
    }

    /// Cancelling the Task surfaces as either error depending on where the
    /// transfer was when it happened.
    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
