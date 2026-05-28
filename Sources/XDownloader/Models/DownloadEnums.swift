import Foundation

enum YouTubeFormat: String, CaseIterable, Identifiable {
    case videoAndAudio = "video"
    case singleFile = "videoOnly"
    case audioOnly = "audio"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .videoAndAudio: return "Video + Audio"
        case .singleFile:    return "Single File"
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
