import SwiftData
import SwiftUI

@main
struct EditOSApp: App {
    /// CloudKit-backed SwiftData container. Set `cloudKitDatabase` to
    /// `.private(<container ID>)` so projects sync into the user's private
    /// iCloud database — same shape as iCloud Drive Documents, but as
    /// records instead of files.
    let modelContainer: ModelContainer
    @State private var environment: AppEnvironment

    /// Sparkle auto-updater. Created once at launch — Sparkle owns its
    /// own scheduling, KVO publishing, and signature verification from
    /// here on. The "Check for Updates…" menu item in AppCommands binds
    /// to its `canCheckForUpdates` state.
    @StateObject private var sparkle = SparkleUpdater()

    init() {
        let container: ModelContainer
        do {
            let configuration = ModelConfiguration(
                schema: Schema([ProjectRecord.self]),
                cloudKitDatabase: .private("iCloud.com.damioffice.EditOS")
            )
            container = try ModelContainer(
                for: ProjectRecord.self,
                configurations: configuration
            )
        } catch {
            // Fall back to a local-only store so the app still launches if
            // the iCloud container isn't configured yet (development).
            let local = ModelConfiguration(schema: Schema([ProjectRecord.self]))
            container = (try? ModelContainer(for: ProjectRecord.self, configurations: local))
                ?? (try! ModelContainer(for: ProjectRecord.self))
        }
        self.modelContainer = container
        _environment = State(initialValue: AppEnvironment(modelContainer: container))
    }

    var body: some Scene {
        Window("EditOS", id: WindowID.home.rawValue) {
            HomeView()
                .environment(environment)
                .modelContainer(modelContainer)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .commands { AppCommands(environment: environment, sparkle: sparkle) }

        WindowGroup("Editor", id: WindowID.editor.rawValue, for: Project.ID.self) { $projectID in
            EditorHost(projectID: projectID)
                .environment(environment)
                .modelContainer(modelContainer)
                .frame(minWidth: 1280, minHeight: 800)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1600, height: 1000)
    }
}

enum WindowID: String {
    case home
    case editor
}

private struct EditorHost: View {
    @Environment(AppEnvironment.self) private var environment
    let projectID: Project.ID?

    var body: some View {
        Group {
            if let projectID, let project = environment.projectStore.project(for: projectID) {
                EditorView(project: project, resolver: environment.assetResolver)
            } else {
                ContentUnavailableView(
                    "Project not found",
                    systemImage: "film.stack",
                    description: Text("The project you opened is no longer available.")
                )
            }
        }
    }
}
