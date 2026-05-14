import SwiftUI

@main
struct EditOSApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        Window("EditOS", id: WindowID.home.rawValue) {
            HomeView()
                .environment(environment)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .commands { AppCommands(environment: environment) }

        WindowGroup("Editor", id: WindowID.editor.rawValue, for: Project.ID.self) { $projectID in
            EditorHost(projectID: projectID)
                .environment(environment)
                .frame(minWidth: 1280, minHeight: 800)
        }
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
