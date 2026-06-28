import Foundation

enum YouTubeFormat: String, CaseIterable, Identifiable {
    case videoAndAudio = "video"
    case singleFile = "videoOnly"
    case audioOnly = "audio"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .videoAndAudio: return "Video + Audio"
        case .singleFile:    return "Video Only"
        case .audioOnly:     return "Audio Only"
        }
    }
}

enum SubtitleLanguage: String, CaseIterable, Identifiable {
    case none              = ""
    case english           = "en"
    case chineseTraditional = "zh-Hant"
    case chineseSimplified  = "zh-Hans"
    case japanese          = "ja"
    case korean            = "ko"
    case spanish           = "es"
    case french            = "fr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:               return "None"
        case .english:            return "English"
        case .chineseTraditional: return "Chinese (Traditional)"
        case .chineseSimplified:  return "Chinese (Simplified)"
        case .japanese:           return "Japanese"
        case .korean:             return "Korean"
        case .spanish:            return "Spanish"
        case .french:             return "French"
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case best  = "best"
    case p1080 = "1080"
    case p720  = "720"
    case p480  = "480"
    case p360  = "360"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .best:  return "Best"
        case .p1080: return "1080p"
        case .p720:  return "720p"
        case .p480:  return "480p"
        case .p360:  return "360p"
        }
    }

    /// yt-dlp filter string, e.g. "[height<=720]". Nil for "best" (no filter).
    var heightFilter: String? {
        self == .best ? nil : "[height<=\(rawValue)]"
    }
}

enum AudioQuality: String, CaseIterable, Identifiable {
    case best = "0"
    case q320 = "320K"
    case q192 = "192K"
    case q128 = "128K"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .best: return "Best"
        case .q320: return "320 kbps"
        case .q192: return "192 kbps"
        case .q128: return "128 kbps"
        }
    }
}

enum OpenPreference: String, CaseIterable, Identifiable {
    case video = "video"
    case audio = "audio"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        }
    }
}

enum CookieBrowser: String, CaseIterable, Identifiable {
    case safari  = "safari"
    case chrome  = "chrome"
    case firefox = "firefox"
    case edge    = "edge"
    case none    = ""

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safari:  return "Safari"
        case .chrome:  return "Chrome"
        case .firefox: return "Firefox"
        case .edge:    return "Edge"
        case .none:    return "None"
        }
    }
}

/// Shared pure helper to eliminate duplication between YtDlpService and GalleryDlService.
/// File path always takes precedence (for sensitive/NSFW X content workaround).
enum CookieArgs {
    static func make(browser: CookieBrowser, file: String?) -> [String] {
        if let f = file, !f.isEmpty {
            return ["--cookies", f]
        }
        return browser != .none ? ["--cookies-from-browser", browser.rawValue] : []
    }
}
