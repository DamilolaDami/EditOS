import CloudKit
import Foundation
import Observation
import OSLog

/// Watches the user's iCloud account status so the Home view can show a
/// meaningful sync chip ("Synced", "Signed Out", "Offline"). SwiftData does
/// the actual record mirroring under the hood — this just surfaces whether
/// CloudKit will accept writes.
@MainActor
@Observable
final class CloudKitSyncMonitor {
    enum State: Equatable {
        case unknown
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case couldNotDetermine(String)

        var label: String {
            switch self {
            case .unknown: return "Checking…"
            case .available: return "iCloud Synced"
            case .noAccount: return "Sign in to iCloud"
            case .restricted: return "iCloud Restricted"
            case .temporarilyUnavailable: return "iCloud Unavailable"
            case .couldNotDetermine: return "iCloud Offline"
            }
        }

        var systemImage: String {
            switch self {
            case .unknown: return "icloud"
            case .available: return "checkmark.icloud.fill"
            case .noAccount: return "icloud.slash"
            case .restricted: return "icloud.slash"
            case .temporarilyUnavailable: return "exclamationmark.icloud"
            case .couldNotDetermine: return "exclamationmark.icloud"
            }
        }

        var isHealthy: Bool {
            if case .available = self { return true }
            return false
        }
    }

    private(set) var state: State = .unknown
    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "CloudKitSyncMonitor")

    init() {
        Task { await refresh() }
        // The monitor is owned by AppEnvironment for the full lifetime of
        // the process, so we skip explicit observer cleanup — a deinit on a
        // `@MainActor` type can't release a `nonisolated` observer under
        // Swift 6 strict concurrency without going through extra hoops.
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        do {
            let status = try await CKContainer.default().accountStatus()
            switch status {
            case .available:
                state = .available
            case .noAccount:
                state = .noAccount
            case .restricted:
                state = .restricted
            case .temporarilyUnavailable:
                state = .temporarilyUnavailable
            case .couldNotDetermine:
                state = .couldNotDetermine("unknown")
            @unknown default:
                state = .couldNotDetermine("unknown")
            }
        } catch {
            Self.log.error("Account status check failed: \(error.localizedDescription, privacy: .public)")
            state = .couldNotDetermine(error.localizedDescription)
        }
    }
}
