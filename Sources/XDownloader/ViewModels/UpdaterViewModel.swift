import AppKit
import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle's updater for SwiftUI. Gated off entirely for development
/// builds — bare binaries (`swift run`) have no bundle, and untagged bundles
/// carry the 0.0.0 sentinel, where "updating" to the latest release would be
/// a downgrade in disguise.
@MainActor
final class UpdaterViewModel: NSObject, ObservableObject {
    /// Mirrors Sparkle's canCheckForUpdates so Check Now disables itself
    /// while a check or install is already in flight.
    @Published private(set) var canCheckForUpdates = false

    /// The version Sparkle last reported as available; nil when the app is
    /// current or the user skipped it. Drives the menu bar row.
    @Published private(set) var availableVersion: String?

    private var controller: SPUStandardUpdaterController?
    private var canCheckSubscription: AnyCancellable?

    /// The stamped marketing version, or nil for development builds.
    static let installedVersion: String? = {
        guard Bundle.main.bundleIdentifier != nil,
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            version != "0.0.0"
        else { return nil }
        return version
    }()

    var isEnabled: Bool { controller != nil }

    var lastCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    /// Persisted by Sparkle itself in the app's defaults (SUEnableAutomaticChecks)
    /// — deliberately not part of SettingsStore.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    override init() {
        super.init()
        guard Self.installedVersion != nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        canCheckSubscription = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

extension UpdaterViewModel: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.availableVersion = nil }
    }

    nonisolated func updater(_ updater: SPUUpdater, userDidSkipThisVersion item: SUAppcastItem) {
        // A skipped version shouldn't keep advertising itself in the menu bar.
        Task { @MainActor in self.availableVersion = nil }
    }
}
