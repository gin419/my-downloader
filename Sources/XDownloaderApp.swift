import SwiftUI

@main
struct XDownloaderApp: App {
    @StateObject private var manager = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 560, minHeight: 460)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 680, height: 560)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Paste and Download") {
                    NotificationCenter.default.post(name: .pasteAndDownload, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(manager)
        }
    }
}

extension Notification.Name {
    static let pasteAndDownload = Notification.Name("pasteAndDownload")
}
