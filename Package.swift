// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XDownloader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "XDownloader",
            path: "Sources/XDownloader",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
