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
                // Targets the manager directly (not a window) so the shortcut
                // works identically for every future entry point too.
                Button("Paste and Download") {
                    manager.captureFromClipboard()
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
