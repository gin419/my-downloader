import Foundation
import SwiftUI

enum MediaCategory: String, Equatable, Codable {
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

enum DownloadStatus: Equatable, Codable {
    case queued
    case fetching
    case downloading
    case completed
    case failed(String)

    private enum CodingKeys: String, CodingKey { case kind, message }
    private enum Kind: String, Codable { case queued, fetching, downloading, completed, failed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .queued, .fetching, .downloading: self = .queued
        case .completed: self = .completed
        case .failed:
            let m = (try? c.decode(String.self, forKey: .message)) ?? ""
            self = .failed(m)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued:      try c.encode(Kind.queued,      forKey: .kind)
        case .fetching:    try c.encode(Kind.fetching,    forKey: .kind)
        case .downloading: try c.encode(Kind.downloading, forKey: .kind)
        case .completed:   try c.encode(Kind.completed,   forKey: .kind)
        case .failed(let m):
            try c.encode(Kind.failed, forKey: .kind)
            try c.encode(m, forKey: .message)
        }
    }

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

    init(url: String, addedAt: Date = Date()) {
        self.url = url
        self.addedAt = addedAt
    }

    init(persisted p: PersistedDownloadItem) {
        self.url = p.url
        self.addedAt = p.addedAt
        self.title = p.title
        self.progress = p.progress
        self.status = p.status
        self.totalSize = p.totalSize
        self.outputPath = p.outputPath
        self.videoPath = p.videoPath
        self.audioPath = p.audioPath
        self.imageCount = p.imageCount
        self.videoCount = p.videoCount
        self.mediaCategory = p.mediaCategory
        self.retryCount = p.retryCount
    }

    func toPersisted() -> PersistedDownloadItem {
        PersistedDownloadItem(
            url: url,
            addedAt: addedAt,
            title: title,
            progress: status == .completed ? 1.0 : 0.0,
            status: status,
            totalSize: totalSize,
            outputPath: outputPath,
            videoPath: videoPath,
            audioPath: audioPath,
            imageCount: imageCount,
            videoCount: videoCount,
            mediaCategory: mediaCategory,
            retryCount: retryCount
        )
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return url
    }
}

struct PersistedDownloadItem: Codable {
    let url: String
    let addedAt: Date
    let title: String?
    let progress: Double
    let status: DownloadStatus
    let totalSize: String?
    let outputPath: String?
    let videoPath: String?
    let audioPath: String?
    let imageCount: Int?
    let videoCount: Int?
    let mediaCategory: MediaCategory
    let retryCount: Int
}
