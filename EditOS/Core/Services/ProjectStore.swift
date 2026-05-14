import Foundation
import Observation

/// CRUD for projects on disk. Each project is one JSON file inside the app's
/// Application Support directory; media assets reference the original source
/// files via security-scoped bookmarks rather than being copied in.
@Observable
@MainActor
final class ProjectStore {
    private(set) var projects: [Project] = []

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL) {
        self.directory = directory
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    static func live() -> ProjectStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = base.appending(path: "EditOS/Projects", directoryHint: .isDirectory)
        return ProjectStore(directory: directory)
    }

    func project(for id: Project.ID) -> Project? {
        projects.first { $0.id == id }
    }

    @discardableResult
    func createProject(named name: String, canvas: CanvasFormat = .hd) -> Project {
        let project = Project(name: name, canvas: canvas)
        projects.insert(project, at: 0)
        save(project)
        return project
    }

    func update(_ project: Project) {
        var modified = project
        modified.modifiedAt = .now
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = modified
        } else {
            projects.insert(modified, at: 0)
        }
        save(modified)
    }

    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        try? FileManager.default.removeItem(at: url(for: project.id))
    }

    private func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        projects = urls
            .filter { $0.pathExtension == "editos" }
            .compactMap { try? decoder.decode(Project.self, from: Data(contentsOf: $0)) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func save(_ project: Project) {
        guard let data = try? encoder.encode(project) else { return }
        try? data.write(to: url(for: project.id), options: .atomic)
    }

    private func url(for id: Project.ID) -> URL {
        directory.appending(path: "\(id.uuidString).editos")
    }
}
