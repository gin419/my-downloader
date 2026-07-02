import SwiftUI

@main
struct XDownloaderApp: App {
    @StateObject private var manager = DownloadManager()

    var body: some Scene {
        // Window (not WindowGroup): the menu bar's "Open XDownloader" must
        // raise the ONE existing window via openWindow(id:), never spawn a
        // second queue view.
        Window("X Downloader", id: "main") {
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

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarMenuView(manager: manager)
        } label: {
            MenuBarLabelView(manager: manager)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(manager)
        }
    }

    /// Routed through saveSettings so ⌘-dragging the icon out of the menu bar
    /// (which flips isInserted without touching SettingsView) persists too.
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { manager.showMenuBarExtra },
            set: { inserted in
                // SwiftUI re-sets this binding on EVERY scene update, not just
                // user removal. Writing the @Published unconditionally fires
                // objectWillChange → App body re-evaluates → set again — an
                // infinite scene-update loop pegging a core and leaking the
                // whole view graph. Only a real change may write.
                guard manager.showMenuBarExtra != inserted else { return }
                manager.showMenuBarExtra = inserted
                manager.saveSettings()
            }
        )
    }
}
