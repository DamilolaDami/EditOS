import Foundation
import Observation
import SwiftUI

/// Tracks the project IDs the user has most recently opened. Backs the
/// File → Open Recent menu and the Home view's "Continue editing" hero.
///
/// Persistence is a JSON-encoded array of UUID strings in UserDefaults so
/// every editor window shares the same list without any cross-window
/// notifications. The list always reflects open order — most-recent first
/// — and is trimmed to `Self.maxEntries`.
@Observable
@MainActor
final class RecentProjects {
    private(set) var ids: [Project.ID] = []

    /// We don't need to remember more than a screenful — Apple's
    /// recent-files menus typically show 5–10.
    static let maxEntries = 10

    private static let storageKey = "EditOS.recentProjectIDs"

    init() {
        ids = load()
    }

    /// Record a project as "just opened". Moves it to the front of the
    /// list (or inserts it) and trims to `maxEntries`. Called from every
    /// site that opens an editor window for an existing project.
    func recordOpen(_ id: Project.ID) {
        var next = ids.filter { $0 != id }
        next.insert(id, at: 0)
        if next.count > Self.maxEntries {
            next = Array(next.prefix(Self.maxEntries))
        }
        ids = next
        save()
    }

    /// Drop a project from the recents — used when the project itself is
    /// deleted so stale IDs don't haunt the menu.
    func forget(_ id: Project.ID) {
        guard ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        save()
    }

    /// Wipe the whole list — wired to the "Clear Menu" item at the
    /// bottom of File → Open Recent, matching every other Mac app.
    func clear() {
        guard !ids.isEmpty else { return }
        ids.removeAll()
        save()
    }

    /// Resolve each recent id to its live `Project` (if it still exists).
    /// Drops entries pointing at deleted projects on the way through, so
    /// callers always get a clean, in-order list.
    func liveProjects(from store: ProjectStore) -> [Project] {
        var live: [Project] = []
        var validIDs: [Project.ID] = []
        for id in ids {
            if let project = store.projects.first(where: { $0.id == id }) {
                live.append(project)
                validIDs.append(id)
            }
        }
        if validIDs.count != ids.count {
            ids = validIDs
            save()
        }
        return live
    }

    // MARK: - Persistence

    private func load() -> [Project.ID] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let raw = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return raw.compactMap(UUID.init(uuidString:))
    }

    private func save() {
        let raw = ids.map(\.uuidString)
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
