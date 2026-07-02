import AppKit
import SwiftUI

/// Receives xdownloader:// URLs at the app level so a script or Shortcuts
/// call queues QUIETLY in the background — the window is raised only for
/// outcomes that need it (warnings, duplicate confirmations). URLs arriving
/// before the UI has attached (cold launch via URL) are buffered.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var manager: DownloadManager?
    private var openMainWindow: (() -> Void)?
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let manager else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { handle(url, with: manager) }
    }

    /// Called from ContentView.onAppear — the earliest point where both the
    /// manager and an openWindow action exist.
    func attach(manager: DownloadManager, openMainWindow: @escaping () -> Void) {
        self.manager = manager
        self.openMainWindow = openMainWindow
        let buffered = pendingURLs
        pendingURLs.removeAll()
        for url in buffered { handle(url, with: manager) }
    }

    private func handle(_ url: URL, with manager: DownloadManager) {
        let result = manager.handleSchemeURL(url)
        // Quiet success stays quiet — scripting is the point of the scheme;
        // the menu bar count ticking up is the acknowledgment.
        let quietSuccess = (result?.queued ?? 0) > 0 && (result?.toConfirm ?? 0) == 0
        if !quietSuccess {
            openMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct XDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

                ImportLinksCommand(manager: manager)
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
                manager.showMenuBarExtra = inserted
                manager.saveSettings()
            }
        )
    }
}

/// Its own View so it can reach openWindow — import feedback (status line,
/// duplicate confirmations) renders in the window, so it always comes up.
private struct ImportLinksCommand: View {
    let manager: DownloadManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Import Links…") {
            let panel = NSOpenPanel()
            // plainText only — RTF/HTML conform to .text, and their raw
            // markup would defeat link extraction with a misleading result.
            panel.allowedContentTypes = [.plainText]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = "Import Links"
            panel.message = "Choose a plain-text file of links — one per line, or mixed with prose."
            panel.prompt = "Import"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { @MainActor in
                _ = await manager.importLinks(from: url)
                // The user just drove a file dialog — show them the result,
                // whatever it was. (With the window closed and the menu bar
                // hidden, even a success would otherwise be invisible.)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .keyboardShortcut("o", modifiers: .command)
    }
}
