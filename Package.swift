// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XDownloader",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-update. Prebuilt binaryTarget — also ships the signing/appcast
        // tools used by build.sh and release.yml (.build/artifacts/…/bin).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "XDownloader",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/XDownloader",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "XDownloaderTests",
            dependencies: ["XDownloader"],
            path: "Tests/XDownloaderTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
