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

        CommandGroup(after: .newItem) {
            // File → Open Recent submenu, populated from RecentProjects.
            // The list is built every time the menu opens because
            // SwiftUI's Commands re-evaluate body when @Observable
            // dependencies change.
            Menu("Open Recent") {
                let recents = environment.recentProjects.liveProjects(from: environment.projectStore)
                if recents.isEmpty {
                    Button("No Recent Projects") {}.disabled(true)
                } else {
                    ForEach(recents) { project in
                        Button(project.name) {
                            environment.recentProjects.recordOpen(project.id)
                            openWindow(id: WindowID.editor.rawValue, value: project.id)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        environment.recentProjects.clear()
                    }
                }
            }

            Divider()

            Button("Show Projects Window") {
                openWindow(id: WindowID.home.rawValue)
            }
            .keyboardShortcut("0", modifiers: [.command, .shift])
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

        // Cursor-style selection commands live under Edit by the system.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All Clips") {
                editorModel?.selectAllClips()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(editorModel == nil)

            Button("Deselect All") {
                editorModel?.selectClip(nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(editorModel?.selectedClipIDs.isEmpty ?? true)
        }

        CommandMenu("View") {
            Button("Zoom In Timeline") {
                if let editorModel {
                    editorModel.zoom = min(4.0, editorModel.zoom * 1.25)
                }
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(editorModel == nil)

            Button("Zoom Out Timeline") {
                if let editorModel {
                    editorModel.zoom = max(0.25, editorModel.zoom * 0.8)
                }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(editorModel == nil)

            Button("Reset Timeline Zoom") {
                editorModel?.zoom = 1.0
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(editorModel == nil)

            Divider()

            Button(editorModel?.snapEnabled == false ? "Enable Snap" : "Disable Snap") {
                editorModel?.snapEnabled.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(editorModel == nil)

            Divider()

            Button("Toggle Library") {
                NotificationCenter.default.post(name: .editorToggleLibrary, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(editorModel == nil)

            Button("Toggle Inspector") {
                NotificationCenter.default.post(name: .editorToggleInspector, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(editorModel == nil)
        }

        CommandMenu("Library") {
            tabButton("Media", "1", to: .media)
            tabButton("Audio", "2", to: .audio)
            tabButton("Text", "3", to: .text)
            tabButton("Stickers", "4", to: .stickers)
            tabButton("Filters", "5", to: .filters)
            tabButton("Captions", "6", to: .captions)
            tabButton("Effects", "7", to: .effects)
            tabButton("Transitions", "8", to: .transitions)
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

            Divider()

            Button("Go to Start") {
                editorModel?.playback.seek(to: 0)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(editorModel == nil)

            Button("Go to End") {
                editorModel?.playback.seek(to: editorModel?.playback.duration ?? 0)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
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

            Divider()

            Button("Delete Clip") {
                if let editorModel {
                    Task { await editorModel.deleteSelectedClip() }
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(editorModel?.selectedClipIDs.isEmpty ?? true)

            Button("Ripple Delete") {
                if let editorModel {
                    Task { await editorModel.rippleDeleteSelectedClip() }
                }
            }
            .keyboardShortcut(.delete, modifiers: .shift)
            .disabled(editorModel?.selectedClipID == nil)
        }

        // Wrapped in a Group so the file stays under SwiftUI's
        // CommandsBuilder arity limit (10 top-level builders).
        Group {
            CommandMenu("Markers") {
                Button("Add Marker at Playhead") {
                    editorModel?.addMarkerAtPlayhead()
                }
                .keyboardShortcut("m", modifiers: [])
                .disabled(editorModel == nil)

                Divider()

                Button("Jump to Previous Marker") {
                    guard let model = editorModel else { return }
                    let t = model.playback.currentTime
                    if let previous = model.project.timeline.markers
                        .filter({ $0.time < t - 0.05 })
                        .max(by: { $0.time < $1.time }) {
                        model.playback.seek(to: previous.time)
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(editorModel?.project.timeline.markers.isEmpty ?? true)

                Button("Jump to Next Marker") {
                    guard let model = editorModel else { return }
                    let t = model.playback.currentTime
                    if let next = model.project.timeline.markers
                        .filter({ $0.time > t + 0.05 })
                        .min(by: { $0.time < $1.time }) {
                        model.playback.seek(to: next.time)
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(editorModel?.project.timeline.markers.isEmpty ?? true)

                Divider()

                Button("Clear All Markers") {
                    editorModel?.clearAllMarkers()
                }
                .disabled(editorModel?.project.timeline.markers.isEmpty ?? true)
            }

            CommandGroup(replacing: .help) {
            Button("Replay Onboarding") {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                openWindow(id: WindowID.home.rawValue)
            }

            Button("Report an Issue") {
                if let url = URL(string: "https://github.com/DamilolaDami/EditOS/issues/new") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Button("EditOS on GitHub") {
                if let url = URL(string: "https://github.com/DamilolaDami/EditOS") {
                    NSWorkspace.shared.open(url)
                }
            }
            }
        }
    }

    @ViewBuilder
    private func tabButton(_ title: String, _ shortcut: String, to tool: ToolCategory) -> some View {
        Button(title) {
            editorModel?.selectedTool = tool
        }
        .keyboardShortcut(KeyEquivalent(Character(shortcut)), modifiers: .command)
        .disabled(editorModel == nil)
    }
}

extension Notification.Name {
    static let editorToggleInspector = Notification.Name("EditOS.editor.toggleInspector")
    static let editorToggleLibrary = Notification.Name("EditOS.editor.toggleLibrary")
}
