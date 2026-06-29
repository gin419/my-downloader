import Foundation

/// Single source of truth for media file extensions, so the same lists don't
/// drift across the services. They had drifted — yt-dlp's image check was
/// missing `gif`/`avif`, and gallery-dl's "known media" set was missing
/// `mkv`/`m4v` that its own `isVideo` check then tested (a dead branch).
enum MediaExtensions {
    static let image: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif"]
    static let video: Set<String> = ["mp4", "mov", "webm", "mkv", "m4v"]
    static let audio: Set<String> = ["m4a", "aac", "ogg", "opus", "weba", "mp3"]

    /// Everything we recognize as a downloadable media file.
    static let all: Set<String> = image.union(video).union(audio)
}
