import Foundation
import Observation
import OSLog
import SwiftData

/// CRUD for projects, backed by SwiftData with a CloudKit-synced container.
///
/// The full `Project` is stored as a JSON blob inside a `ProjectRecord`
/// SwiftData model, so the in-app data structures stay as plain Swift
/// structs while iCloud handles cross-device sync via the model container.
/// Legacy `.editos` files in Application Support are migrated into
/// SwiftData on first launch.
@Observable
@MainActor
final class ProjectStore {
    private(set) var projects: [Project] = []

    private let context: ModelContext
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "ProjectStore")

    init(context: ModelContext) {
        self.context = context
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        migrateLegacyFilesIfNeeded()
        reload()
    }

    /// Convenience initializer that builds its own `ModelContext` from a
    /// container — used by `AppEnvironment` when no DI is in play.
    static func live(container: ModelContainer) -> ProjectStore {
        ProjectStore(context: ModelContext(container))
    }

    // MARK: - CRUD

    func project(for id: Project.ID) -> Project? {
        projects.first { $0.id == id }
    }

    @discardableResult
    func createProject(named name: String, canvas: CanvasFormat = .hd) -> Project {
        let project = Project(name: name, canvas: canvas)
        upsert(project)
        return project
    }

    func update(_ project: Project) {
        var modified = project
        modified.modifiedAt = .now
        upsert(modified)
    }

    func delete(_ project: Project) {
        let id = project.id
        let descriptor = FetchDescriptor<ProjectRecord>(predicate: #Predicate { $0.id == id })
        if let record = try? context.fetch(descriptor).first {
            context.delete(record)
            try? context.save()
        }
        projects.removeAll { $0.id == id }
    }

    /// Pull-down refresh — re-reads every record from SwiftData. Use it
    /// after a CloudKit sync notification or when the user wants to force
    /// reload remote changes.
    func reload() {
        let descriptor = FetchDescriptor<ProjectRecord>(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        guard let records = try? context.fetch(descriptor) else {
            projects = []
            return
        }
        projects = records.compactMap { record -> Project? in
            guard !record.data.isEmpty,
                  let decoded = try? decoder.decode(Project.self, from: record.data)
            else { return nil }
            return decoded
        }
    }

    // MARK: - Internals

    private func upsert(_ project: Project) {
        let id = project.id
        let data: Data
        do {
            data = try encoder.encode(project)
        } catch {
            Self.log.error("Encode failed for \(project.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let descriptor = FetchDescriptor<ProjectRecord>(predicate: #Predicate { $0.id == id })
        if let record = try? context.fetch(descriptor).first {
            record.name = project.name
            record.modifiedAt = project.modifiedAt
            record.data = data
        } else {
            let record = ProjectRecord(
                id: project.id,
                name: project.name,
                modifiedAt: project.modifiedAt,
                data: data
            )
            context.insert(record)
        }
        do {
            try context.save()
        } catch {
            Self.log.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }

        // Keep the in-memory list in sync so views update immediately.
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
        projects.sort { $0.modifiedAt > $1.modifiedAt }
    }

    /// One-shot migration: pulls every `.editos` JSON file from the legacy
    /// Application Support directory into SwiftData. Removes the on-disk
    /// copy after a successful import so the next launch is clean.
    private func migrateLegacyFilesIfNeeded() {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        let directory = support.appending(path: "EditOS/Projects", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: directory.path),
              let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }

        for url in urls where url.pathExtension == "editos" {
            guard let data = try? Data(contentsOf: url),
                  let project = try? decoder.decode(Project.self, from: data) else { continue }
            let id = project.id
            let descriptor = FetchDescriptor<ProjectRecord>(predicate: #Predicate { $0.id == id })
            if (try? context.fetch(descriptor).first) == nil {
                let record = ProjectRecord(
                    id: project.id,
                    name: project.name,
                    modifiedAt: project.modifiedAt,
                    data: data
                )
                context.insert(record)
            }
            // Remove the migrated file so we don't re-import on every launch.
            try? fm.removeItem(at: url)
        }
        try? context.save()
    }
}
