import Foundation

struct BrowserCookieProfile: Identifiable, Equatable {
    let id: String
    let displayName: String
}

enum BrowserCookieProfileDiscovery {
    static func profiles(
        for browser: CookieBrowser,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [BrowserCookieProfile] {
        guard let relativeRoot = browser.chromiumProfileRoot else { return [] }
        let root = homeDirectory.appendingPathComponent(relativeRoot, isDirectory: true)
        let localState = root.appendingPathComponent("Local State")
        guard
            let data = try? Data(contentsOf: localState),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = json["profile"] as? [String: Any],
            let infoCache = profile["info_cache"] as? [String: Any]
        else { return [] }

        return infoCache.compactMap { directory, value in
            guard
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(directory, isDirectory: true).path)
            else { return nil }
            let details = value as? [String: Any]
            let name = (details?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return BrowserCookieProfile(
                id: directory,
                displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? directory)
        }
        .sorted {
            if $0.id == "Default" || $1.id == "Default" {
                return $0.id == "Default" && $1.id != "Default"
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}

extension CookieBrowser {
    fileprivate var chromiumProfileRoot: String? {
        switch self {
        case .chrome:
            return "Library/Application Support/Google/Chrome"
        case .edge:
            return "Library/Application Support/Microsoft Edge"
        default:
            return nil
        }
    }
}
