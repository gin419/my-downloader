import Foundation

/// A snapshot of the user's persisted settings — everything `DownloadManager`
/// stores in UserDefaults. The cookie bookmark is carried here for persistence
/// even though `CookieAccessManager` owns it at runtime.
struct AppSettings {
    var outputDirectory: URL
    var cookieBrowser: CookieBrowser
    var cookiesFilePath: String?
    var cookiesFileBookmarkData: Data?
    var showDownloadDate: Bool
    var youtubeFormat: YouTubeFormat
    var videoQuality: VideoQuality
    var audioQuality: AudioQuality
    var subtitleLanguage: SubtitleLanguage
    var embedSubtitles: Bool
    var maxConcurrent: Int
    var openPreference: OpenPreference
    var autoDownloadOnPaste: Bool
    var saveHistoryEnabled: Bool
}

/// Owns all the UserDefaults key strings + marshalling for the app's settings, so
/// `DownloadManager` doesn't carry them. `defaults` is injectable for tests.
struct SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func save(_ s: AppSettings) {
        let d = defaults
        d.set(s.outputDirectory.absoluteString, forKey: "outputDirectory")
        d.set(s.cookieBrowser.rawValue, forKey: "cookieBrowser")
        d.set(s.cookiesFilePath, forKey: "cookiesFilePath")
        if let bm = s.cookiesFileBookmarkData {
            d.set(bm, forKey: "cookiesFileBookmarkData")
        } else {
            d.removeObject(forKey: "cookiesFileBookmarkData")
        }
        d.set(s.showDownloadDate, forKey: "showDownloadDate")
        d.set(s.youtubeFormat.rawValue, forKey: "youtubeFormat")
        d.set(s.videoQuality.rawValue, forKey: "videoQuality")
        d.set(s.audioQuality.rawValue, forKey: "audioQuality")
        d.set(s.subtitleLanguage.rawValue, forKey: "subtitleLanguage")
        d.set(s.embedSubtitles, forKey: "embedSubtitles")
        d.set(s.maxConcurrent, forKey: "maxConcurrent")
        d.set(s.openPreference.rawValue, forKey: "openPreference")
        d.set(s.autoDownloadOnPaste, forKey: "autoDownloadOnPaste")
        d.set(s.saveHistoryEnabled, forKey: "saveHistoryEnabled")
    }

    /// Load persisted settings, using `fallback` for any key not present.
    func load(fallback: AppSettings) -> AppSettings {
        let d = defaults
        var s = fallback
        if let v = d.string(forKey: "outputDirectory"), let u = URL(string: v) { s.outputDirectory = u }
        if let r = d.string(forKey: "cookieBrowser"), let v = CookieBrowser(rawValue: r) { s.cookieBrowser = v }
        if let p = d.string(forKey: "cookiesFilePath"), !p.isEmpty { s.cookiesFilePath = p } else { s.cookiesFilePath = nil }
        s.cookiesFileBookmarkData = d.data(forKey: "cookiesFileBookmarkData")
        if let r = d.string(forKey: "youtubeFormat"), let v = YouTubeFormat(rawValue: r) { s.youtubeFormat = v }
        if let r = d.string(forKey: "videoQuality"), let v = VideoQuality(rawValue: r) { s.videoQuality = v }
        if let r = d.string(forKey: "audioQuality"), let v = AudioQuality(rawValue: r) { s.audioQuality = v }
        if let r = d.string(forKey: "subtitleLanguage"), let v = SubtitleLanguage(rawValue: r) { s.subtitleLanguage = v }
        if let r = d.string(forKey: "openPreference"), let v = OpenPreference(rawValue: r) { s.openPreference = v }
        s.showDownloadDate = d.bool(forKey: "showDownloadDate")
        s.embedSubtitles = d.object(forKey: "embedSubtitles") as? Bool ?? fallback.embedSubtitles
        s.autoDownloadOnPaste = d.bool(forKey: "autoDownloadOnPaste")
        s.saveHistoryEnabled = d.object(forKey: "saveHistoryEnabled") as? Bool ?? fallback.saveHistoryEnabled
        let stored = d.integer(forKey: "maxConcurrent")
        if stored > 0 { s.maxConcurrent = stored }
        return s
    }
}
