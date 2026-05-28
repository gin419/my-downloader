import Foundation
import SwiftUI

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
