import Combine
import Sparkle
import SwiftUI

/// Wraps `SPUStandardUpdaterController` so the rest of the app stays
/// SwiftUI-flavoured. The controller spins up an `SPUUpdater` that owns
/// the appcast polling, signature verification, and installation
/// pipeline; we just expose a published "can check?" flag for the menu
/// item and a tiny method to kick off a manual check.
///
/// Sparkle defaults — automatic checks every 24h, prompt the user before
/// downloading — live in `Info.plist` via `SUEnableAutomaticChecks`,
/// `SUFeedURL`, and `SUPublicEDKey`. Anything not in Info.plist falls
/// back to Sparkle's framework-level defaults, which are reasonable.
@MainActor
final class SparkleUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Mirror of `SPUUpdater.canCheckForUpdates` — SwiftUI rebinds the
    /// menu item's `disabled` state when this flips (Sparkle disables
    /// checks momentarily while a check is in flight).
    @Published private(set) var canCheckForUpdates: Bool = false

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // SPUUpdater publishes `canCheckForUpdates` via KVO. Bridge that
        // to SwiftUI by polling the value on init and updating it
        // whenever the updater state changes.
        canCheckForUpdates = controller.updater.canCheckForUpdates
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Triggers the standard "Check for Updates…" UI — same flow as the
    /// app menu item. Sparkle handles "you're up to date" / "an update
    /// is available" prompts internally.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
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
