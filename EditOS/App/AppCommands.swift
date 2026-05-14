import SwiftUI

struct AppCommands: Commands {
    let environment: AppEnvironment

    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.editorModel) private var editorModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") {
                let project = environment.projectStore.createProject(named: "Untitled")
                openWindow(id: WindowID.editor.rawValue, value: project.id)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Clip") {
            Button("Split at Playhead") {
                if let editorModel {
                    Task { await editorModel.splitClipAtPlayhead() }
                }
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(editorModel == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Toggle Inspector") {
                NotificationCenter.default.post(name: .editorToggleInspector, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Button("Toggle Library") {
                NotificationCenter.default.post(name: .editorToggleLibrary, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}

extension Notification.Name {
    static let editorToggleInspector = Notification.Name("EditOS.editor.toggleInspector")
    static let editorToggleLibrary = Notification.Name("EditOS.editor.toggleLibrary")
}
