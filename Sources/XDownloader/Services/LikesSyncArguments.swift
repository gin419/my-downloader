import Foundation

struct LikesSyncPlan: Equatable {
    var handle: LikesSyncHandle
    var rootDirectory: URL
    var outputDirectory: URL
    var archivePath: URL
    var url: URL
}

enum LikesSyncPlanner {
    static func plan(for handle: LikesSyncHandle, rootDirectory: URL) -> LikesSyncPlan {
        let output =
            rootDirectory
            .appendingPathComponent("Twitter Likes", isDirectory: true)
            .appendingPathComponent(handle.displayName, isDirectory: true)
        return LikesSyncPlan(
            handle: handle,
            rootDirectory: rootDirectory,
            outputDirectory: output,
            archivePath: output.appendingPathComponent("gallery-dl-archive.sqlite3"),
            url: handle.likesURL
        )
    }
}

struct LikesSyncArguments: Equatable {
    var args: [String]
}

enum LikesSyncArgumentBuilder {
    static let eventNames = ["prepare", "post", "post-after", "after", "skip", "error"]

    static func make(
        plan: LikesSyncPlan,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String? = nil,
        cookiesFile: String?,
        inputURLs: [String]? = nil,
        redownloadMissing: Bool = false,
        abortAfterConsecutiveSkips: Int? = nil
    ) -> LikesSyncArguments {
        var args = CookieArgs.make(
            browser: cookieBrowser, profile: cookieBrowserProfile, file: cookiesFile)
        args += [
            "--config-ignore",
            "--no-input",
            "--dest", plan.outputDirectory.path,
            "-D", ".",
        ]
        // Off (the default): the archive beside the files decides — a media
        // file it lists is skipped without looking at the folder, so a file
        // deleted or moved away is never fetched again. On: no archive, and
        // gallery-dl's own path check decides — a file already in the folder
        // under its name is skipped (still a "skip" event), a missing one is
        // downloaded. A full scan reads every Like's metadata either way, so
        // leaving the archive out costs no extra requests. Turning the option
        // off again heals the archive: gallery-dl adds each file it finds on
        // disk ("archive-event" includes "skip") the next time it sees it.
        if !redownloadMissing {
            args += ["--download-archive", plan.archivePath.path]
        }
        args += [
            "--retries", "10",
            "-o", "downloader.http.timeout=60",
            "-o", "extractor.twitter.quoted=true",
            "-o", "extractor.twitter.retweets=true",
            "-o", "extractor.twitter.cards=false",
            "-o", "extractor.twitter.text-tweets=true",
        ]
        if !redownloadMissing {
            args += ["-o", "archive-event=after,skip"]
        }
        args += [
            "-f", "{author[nick]} - {content!s:.100} [{tweet_id}] #{num}.{extension}",
            "--no-mtime",
        ]

        for event in eventNames {
            // Capital-P --Print emits metadata AND still downloads. Lowercase
            // --print switches gallery-dl into metadata-only mode.
            //
            // gallery-dl's PrintAction (option.py) partitions this argument at
            // the first ":" and CONSUMES the "<event>:" selector as the hook
            // name — only what follows the colon is the printed format string.
            // The event name must therefore be re-embedded INSIDE the format
            // string, or every real emission arrives as an anonymous
            // "likes-sync\t{json}" line no parser can attribute to an event.
            args += ["--Print", "\(event):likes-sync\t\(event):{_json}"]
        }

        if let abortAfterConsecutiveSkips, abortAfterConsecutiveSkips > 0 {
            // Incremental scan (automatic sync): stop once N files in a row
            // were already saved. gallery-dl raises StopExtraction for this,
            // which its job swallows — the run still exits 0. Without the
            // archive (redownloadMissing) a file already at its path is a
            // skip too, so the count works the same either way.
            args += ["-A", String(abortAfterConsecutiveSkips)]
        }

        let urls = inputURLs.flatMap { $0.isEmpty ? nil : $0 } ?? [plan.url.absoluteString]
        args += urls
        return LikesSyncArguments(args: args)
    }

    static func makeVerification(
        handle: LikesSyncHandle,
        cookieBrowser: CookieBrowser,
        cookieBrowserProfile: String? = nil,
        cookiesFile: String?
    ) -> LikesSyncArguments {
        var args = CookieArgs.make(
            browser: cookieBrowser, profile: cookieBrowserProfile, file: cookiesFile)
        args += [
            "--config-ignore", "--no-input", "--simulate", "--range", "1",
            "-o", "extractor.twitter.quoted=false",
            "-o", "extractor.twitter.retweets=false",
            "-o", "extractor.twitter.cards=false",
            "-o", "extractor.twitter.text-tweets=true",
            "--print", "post:likes-verify\t{tweet_id}",
            handle.likesURL.absoluteString,
        ]
        return LikesSyncArguments(args: args)
    }
}
