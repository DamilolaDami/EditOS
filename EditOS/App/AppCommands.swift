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

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                editorModel?.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(editorModel?.canUndo ?? false))

            Button("Redo") {
                editorModel?.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(editorModel?.canRedo ?? false))
        }

        // Replace the system pasteboard commands so we operate on clips
        // inside the editor without touching app-global text behaviour.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                if let editorModel { Task { await editorModel.cutSelection() } }
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(editorModel?.selectedClipIDs.isEmpty ?? true)

            Button("Copy") {
                editorModel?.copySelection()
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(editorModel?.selectedClipIDs.isEmpty ?? true)

            Button("Paste") {
                if let editorModel { Task { await editorModel.paste() } }
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!(editorModel?.hasClipboard ?? false))

            Button("Duplicate") {
                if let editorModel { Task { await editorModel.duplicateSelection() } }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(editorModel?.selectedClipIDs.isEmpty ?? true)
        }

        CommandMenu("Playback") {
            Button(editorModel?.playback.isPlaying == true ? "Pause" : "Play") {
                editorModel?.playback.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(editorModel == nil)

            Divider()

            Button("Step Back 1 Frame") {
                editorModel?.stepFrame(by: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(editorModel == nil)

            Button("Step Forward 1 Frame") {
                editorModel?.stepFrame(by: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(editorModel == nil)

            Button("Back 1 Second") {
                editorModel?.stepSeconds(by: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: .shift)
            .disabled(editorModel == nil)

            Button("Forward 1 Second") {
                editorModel?.stepSeconds(by: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: .shift)
            .disabled(editorModel == nil)
        }

        CommandMenu("Clip") {
            Button("Split at Playhead") {
                if let editorModel {
                    Task { await editorModel.splitClipAtPlayhead() }
                }
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(editorModel == nil)

            Button("Mute / Unmute") {
                if let editorModel, let id = editorModel.selectedClipID {
                    editorModel.toggleClipMuted(id)
                }
            }
            .keyboardShortcut("m", modifiers: .command)
            .disabled(editorModel?.selectedClipID == nil)

            Button("Delete Clip") {
                if let editorModel {
                    Task { await editorModel.deleteSelectedClip() }
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(editorModel?.selectedClipID == nil)
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
