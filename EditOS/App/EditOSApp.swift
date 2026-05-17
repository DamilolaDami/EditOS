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
                // Bridge SwiftUI's `openWindow` into the environment so
                // non-View code (the screen-recorder coordinator running
                // inside an NSWindow callback) can request the editor
                // for a freshly-imported screen recording.
                .background(OpenWindowBridge(environment: environment))
        }
        .windowResizability(.contentMinSize)
        .commands { AppCommands(environment: environment, sparkle: environment.sparkle) }

        WindowGroup("Editor", id: WindowID.editor.rawValue, for: Project.ID.self) { $projectID in
            EditorHost(projectID: projectID)
                .environment(environment)
                .modelContainer(modelContainer)
                .frame(minWidth: 1280, minHeight: 800)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1600, height: 1000)

        // macOS auto-creates "EditOS → Settings…" (⌘,) for the Settings
        // scene. Hosts our Updates / Integrations / About tabs.
        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}

enum WindowID: String {
    case home
    case editor
}

/// Captures SwiftUI's `openWindow` action and assigns it to
/// `AppEnvironment.openProjectInEditor`. Lives in the Home scene so
/// the action is available as long as the app has at least one window.
private struct OpenWindowBridge: View {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                environment.openProjectInEditor = { id in
                    openWindow(id: WindowID.editor.rawValue, value: id)
                }
            }
    }
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
