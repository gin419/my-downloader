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
        cookiesFile: String?,
        inputURLs: [String]? = nil
    ) -> LikesSyncArguments {
        var args = CookieArgs.make(browser: cookieBrowser, file: cookiesFile)
        args += [
            "--config-ignore",
            "--no-input",
            "--dest", plan.outputDirectory.path,
            "-D", ".",
            "--download-archive", plan.archivePath.path,
            "--retries", "10",
            "-o", "downloader.http.timeout=60",
            "-o", "extractor.twitter.quoted=true",
            "-o", "extractor.twitter.retweets=true",
            "-o", "extractor.twitter.cards=false",
            "-o", "extractor.twitter.text-tweets=true",
            "-o", "archive-event=after,skip",
            "-f", "{author[nick]} - {content!s:.100} [{tweet_id}] #{num}.{extension}",
            "--no-mtime",
        ]

        for event in eventNames {
            // Capital-P --Print emits metadata AND still downloads. Lowercase
            // --print switches gallery-dl into metadata-only mode.
            args += ["--Print", "\(event):likes-sync\t{_json}"]
        }

        let urls = inputURLs.flatMap { $0.isEmpty ? nil : $0 } ?? [plan.url.absoluteString]
        args += urls
        return LikesSyncArguments(args: args)
    }

    static func makeVerification(
        handle: LikesSyncHandle,
        cookieBrowser: CookieBrowser,
        cookiesFile: String?
    ) -> LikesSyncArguments {
        var args = CookieArgs.make(browser: cookieBrowser, file: cookiesFile)
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
