import Combine
import Sparkle
import SwiftUI

/// Wraps `SPUStandardUpdaterController` and bridges Sparkle's KVO +
/// delegate callbacks into SwiftUI-friendly `@Published` state.
///
/// Three pieces the rest of the app reads from:
///
/// - `canCheckForUpdates` — mirrors `SPUUpdater.canCheckForUpdates` so
///   the "Check for Updates…" menu item disables itself while a check
///   is already in flight.
/// - `availableUpdate` — the latest `SUAppcastItem` returned by an
///   automatic background check. Drives the in-Home "Update available"
///   banner so users can find new versions without hunting through the
///   menu bar.
/// - `latestCheckStatus` — short human-readable string for the badge
///   ("Checking…", "Up to date", "Update available").
@MainActor
final class SparkleUpdater: NSObject, ObservableObject, @preconcurrency SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates: Bool = false
    @Published private(set) var availableUpdate: SUAppcastItem?

    /// Lazy so `self` is fully constructed before Sparkle starts wiring
    /// the delegate. The controller spins up `SPUUpdater` immediately
    /// when accessed; touching it from `init` after super.init() is the
    /// canonical way to start the polling loop.
    private lazy var controller: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()

    override init() {
        super.init()
        // Trigger the lazy controller so polling actually starts. Without
        // this line Sparkle would only initialise on the first menu-item
        // tap, defeating the automatic-check pitch.
        _ = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Triggers the standard "Check for Updates…" UI — same path the
    /// menu item uses. Sparkle handles "you're up to date" / "update
    /// available" prompts internally.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Called from the Home banner's "Install" button. Routes through
    /// Sparkle's normal flow so signature verification, sandbox XPC
    /// handoff, and the install-now dialog all run unchanged.
    func installAvailableUpdate() {
        controller.checkForUpdates(nil)
    }

    /// Dismisses the in-app banner without skipping the update — the
    /// next automatic check (or a manual one) will surface the same
    /// version again.
    func dismissBanner() {
        availableUpdate = nil
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdate = item
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdate = nil
    }
}

/// Tiny menu item view. Lives inside `AppCommands` so it picks up
/// SwiftUI's command-builder enable/disable plumbing automatically.
struct CheckForUpdatesMenuItem: View {
    @ObservedObject var updater: SparkleUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
