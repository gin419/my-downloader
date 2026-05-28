import Foundation
import SwiftUI

enum MediaCategory: Equatable {
    case image
    case video
    case audio
    case mixed   // image + video in the same tweet
    case unknown

    var icon: String {
        switch self {
        case .image:   return "🖼️"
        case .video:   return "🎬"
        case .audio:   return "🎵"
        case .mixed:   return "🖼️🎬"
        case .unknown: return "?"
        }
    }

    var label: String {
        switch self {
        case .image:   return "Image"
        case .video:   return "Video"
        case .audio:   return "Audio"
        case .mixed:   return "Mixed"
        case .unknown: return "?"
        }
    }

    var color: Color {
        switch self {
        case .image:   return .purple
        case .video:   return .blue
        case .audio:   return .orange
        case .mixed:   return .indigo
        case .unknown: return .secondary
        }
    }
}

enum DownloadStatus: Equatable {
    case queued
    case fetching
    case downloading
    case completed
    case failed(String)

    var label: String {
        switch self {
        case .queued:      return "Queued"
        case .fetching:    return "Fetching info..."
        case .downloading: return "Downloading"
        case .completed:   return "Done"
        case .failed:      return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .queued:      return .secondary
        case .fetching:    return .orange
        case .downloading: return .blue
        case .completed:   return .green
        case .failed:      return .red
        }
    }
}

@MainActor
class DownloadItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: String
    let addedAt: Date

    @Published var title: String?
    @Published var progress: Double = 0
    @Published var status: DownloadStatus = .queued
    @Published var speed: String?
    @Published var eta: String?
    @Published var totalSize: String?
    @Published var outputPath: String?
    @Published var videoPath: String?
    @Published var audioPath: String?
    @Published var imageCount: Int?
    @Published var videoCount: Int?
    @Published var mediaCategory: MediaCategory = .unknown
    @Published var retryCount: Int = 0

    init(url: String) {
        self.url = url
        self.addedAt = Date()
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return url
    }
}
