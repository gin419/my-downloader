import XCTest

@testable import XDownloader

/// Known raw yt-dlp ERROR lines must be replaced with app-native copy that
/// names the true cause and the in-app fix — the model is GalleryDlService's
/// Instagram-login mapping. Inputs are verbatim line formats from yt-dlp
/// 2026.07.04 (cookies.py, postprocessor/ffmpeg.py, YoutubeDL.py) and the
/// playability errors YouTube relays through it.
@MainActor
final class YtDlpErrorMappingTests: XCTestCase {

    private func failureMessage(for line: String, url: String = "https://youtube.com/watch?v=pzBazEzxqaI") -> String? {
        let item = DownloadItem(url: url)
        YtDlpService.parseLine(line, item: item) {
            XCTFail("terminate() must not fire for error lines")
        }
        guard case .failed(let message) = item.status else { return nil }
        return message
    }

    func testKnownErrorLinesMapToActionableMessages() {
        let cases: [(line: String, expected: String)] = [
            // 1. Private video
            (
                "ERROR: [youtube] pzBazEzxqaI: Private video. Sign in if you've been granted access to this video. "
                    + "Use --cookies-from-browser or --cookies for the authentication.",
                "Private video — sign in with an authorized account in the browser chosen in Settings → Cookies, then Retry."
            ),
            // 2. Age restriction
            (
                "ERROR: [youtube] pzBazEzxqaI: Sign in to confirm your age. This video may be inappropriate for some users. "
                    + "Use --cookies-from-browser or --cookies for the authentication.",
                "Age-restricted — needs a signed-in browser session (Settings → Cookies)."
            ),
            // 3. Members-only content (the real line carries both tokens)
            (
                "ERROR: [youtube] pzBazEzxqaI: Join this channel to get access to members-only content like this video, "
                    + "and other exclusive perks.",
                "Members-only video — needs cookies from a member account."
            ),
            // 4. Bot check — YouTube's phrasing uses a right single quote…
            (
                "ERROR: [youtube] pzBazEzxqaI: Sign in to confirm you’re not a bot. "
                    + "Use --cookies-from-browser or --cookies for the authentication.",
                "YouTube wants a signed-in session — pick your YouTube browser in Settings → Cookies (update yt-dlp if this repeats)."
            ),
            // …but a plain apostrophe must match too.
            (
                "ERROR: [youtube] pzBazEzxqaI: Sign in to confirm you're not a bot. "
                    + "Use --cookies-from-browser or --cookies for the authentication.",
                "YouTube wants a signed-in session — pick your YouTube browser in Settings → Cookies (update yt-dlp if this repeats)."
            ),
            // 5. Stale-tool 403 on media download
            (
                "ERROR: unable to download video data: HTTP Error 403: Forbidden",
                "YouTube rejected the download (HTTP 403) — this usually means yt-dlp is outdated. Update it, then Retry."
            ),
            // 6. Browser cookie database not found (wrong browser/profile in Settings)
            (
                "ERROR: could not find chrome cookies database in \"/Users/example/Google/Chrome\"",
                "Couldn't read the selected browser's cookies — pick the browser and profile you actually use in Settings → Cookies."
            ),
            // 7. ffmpeg/ffprobe missing at the postprocessing step
            (
                "ERROR: Postprocessing: ffprobe and ffmpeg not found. Please install or provide the path using --ffmpeg-location",
                "ffmpeg is required to convert or merge media — install it (brew install ffmpeg), then Retry."
            ),
        ]
        for c in cases {
            XCTAssertEqual(failureMessage(for: c.line), c.expected, "line: \(c.line)")
        }
    }

    /// The stale-yt-dlp diagnosis for a 403 is a YouTube pattern — on other
    /// sites the same line gets generic copy, not YouTube wording.
    func testNonYouTube403GetsGenericCopyNotYouTubeWording() {
        let message = failureMessage(
            for: "ERROR: unable to download video data: HTTP Error 403: Forbidden",
            url: "https://x.com/a/status/1")
        XCTAssertEqual(
            message,
            "The site rejected the download (HTTP 403) — Retry; if it persists, the media may need different cookies.")
        XCTAssertFalse(message?.contains("YouTube") ?? true)
    }
}

/// Known raw gallery-dl error lines must be replaced with app-native copy,
/// ordered most-specific-first: the NSFW/Protected forms must win over the
/// generic AuthRequired umbrella they are nested in. Inputs are verbatim
/// gallery-dl 1.32.9 line formats (job.py logs GalleryDLExceptions as
/// "ClassName: message"; AbortExtraction logs the bare message).
@MainActor
final class GalleryDlErrorMappingTests: XCTestCase {

    private func failureMessage(for line: String, url: String = "https://x.com/a/status/1") -> String? {
        let item = DownloadItem(url: url)
        GalleryDlService.parseLine(line, item: item)
        guard case .failed(let message) = item.status else { return nil }
        return message
    }

    func testKnownErrorLinesMapToActionableMessages() {
        let cases: [(line: String, url: String, expected: String)] = [
            // 8. NSFW tweet — contains "AuthRequired", so it also pins the
            // ordering: the specific form must win over the umbrella below.
            (
                "[twitter][error] AuthRequired: NSFW Tweet",
                "https://x.com/a/status/1",
                "This tweet is marked sensitive — export a cookies.txt file in Settings "
                    + "(browser cookies often can't unlock NSFW X media), then Retry."
            ),
            // 9. Protected account, both phrasings
            (
                "[twitter][error] AuthRequired: Protected Tweet",
                "https://x.com/a/status/1",
                "This account's posts are protected — you must follow it; sign in via Settings → Cookies, then Retry."
            ),
            (
                "[twitter][error] gin419's Tweets are protected",
                "https://x.com/gin419/status/1",
                "This account's posts are protected — you must follow it; sign in via Settings → Cookies, then Retry."
            ),
            // 10. Generic X auth failures
            (
                "[twitter][error] AuthRequired: authenticated cookies needed to access this timeline",
                "https://x.com/a/status/1",
                "X sign-in needed or expired — sign in to X in the browser in Settings → Cookies, then Retry. "
                    + "If you're already signed in and this persists, update gallery-dl."
            ),
            (
                "[twitter][error] 401 Unauthorized (Could not authenticate you)",
                "https://x.com/a/status/1",
                "X sign-in needed or expired — sign in to X in the browser in Settings → Cookies, then Retry. "
                    + "If you're already signed in and this persists, update gallery-dl."
            ),
            // 11. gallery-dl internal error (site API drift)
            (
                "[twitter][error] An unexpected error occurred: KeyError - 'itemContent'. Please run gallery-dl again "
                    + "with the --verbose flag, copy its output and report this issue on "
                    + "https://codeberg.org/mikf/gallery-dl/issues .",
                "https://x.com/a/status/1",
                "gallery-dl hit an internal error — the site may have changed its API. "
                    + "Updating gallery-dl (brew upgrade gallery-dl) usually fixes this."
            ),
            // 12. Instagram security challenge
            (
                "[instagram][error] HTTP redirect to challenge page (https://www.instagram.com/challenge/)",
                "https://www.instagram.com/p/Daoe_4TTVY0/",
                "Instagram is asking for a security check — open instagram.com, complete it, then Retry."
            ),
            // 13. URL not recognized by gallery-dl
            (
                "[gallery-dl][error] Unsupported URL 'https://example.com/post/1'",
                "https://example.com/post/1",
                "gallery-dl doesn't recognize this URL — if the site recently changed links, updating gallery-dl may add support."
            ),
        ]
        for c in cases {
            XCTAssertEqual(failureMessage(for: c.line, url: c.url), c.expected, "line: \(c.line)")
        }
    }

    /// The X sign-in copy is gated to the twitter profile: an auth failure on
    /// another site must never tell the user to sign in to X. Instagram's
    /// 401-shaped line gets the generic sign-in copy instead (its login
    /// redirect already has a dedicated mapping).
    func testNonTwitterAuthLinesDoNotGetXWording() {
        let message = failureMessage(
            for: "[instagram][error] 401 Unauthorized",
            url: "https://www.instagram.com/p/Daoe_4TTVY0/")
        XCTAssertEqual(message, "Sign-in required or session expired — check Settings → Cookies, then Retry.")
        XCTAssertFalse(message?.contains("sign in to X") ?? true)
    }
}
