import SwiftUI

struct AppCommands: Commands {
    let environment: AppEnvironment
    let sparkle: SparkleUpdater

    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.editorModel) private var editorModel

    /// Shortcut lookup helper. Touching `environment.shortcuts.binding(for:)`
    /// inside the commands body wires the menu rebuild into the
    /// `@Observable` store — when the user rebinds an action in
    /// Settings → Shortcuts, every affected menu item picks up the
    /// new combo without an app restart.
    private func shortcut(_ action: ShortcutAction) -> KeyboardShortcut {
        environment.shortcuts.swiftUIShortcut(for: action)
    }

    var body: some Commands {
        // Wrapping the app-menu Check-for-Updates and the File menu
        // pair in a Group keeps us under the CommandsBuilder arity
        // limit (10 top-level builders).
        Group {
            // "Check for Updates…" lives under the EditOS application
            // menu (top of the menu bar), right below "About EditOS",
            // where every Mac user expects it.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem(updater: sparkle)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    let project = environment.projectStore.createProject(
                        named: "Untitled",
                        canvas: environment.preferences.defaultCanvasFormat()
                    )
                    openWindow(id: WindowID.editor.rawValue, value: project.id)
                }
                .keyboardShortcut(shortcut(.newProject))
            }
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
            .keyboardShortcut(shortcut(.showProjectsWindow))
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                editorModel?.undo()
            }
            .keyboardShortcut(shortcut(.undo))
            .disabled(!(editorModel?.canUndo ?? false))

            Button("Redo") {
                editorModel?.redo()
            }
            .keyboardShortcut(shortcut(.redo))
            .disabled(!(editorModel?.canRedo ?? false))
        }

        // Replace the system pasteboard commands so we operate on clips
        // inside the editor without touching app-global text behaviour.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                if let editorModel { Task { await editorModel.cutSelection() } }
            }
            .keyboardShortcut(shortcut(.cut))
            .disabled(editorModel?.selectedClipIDs.isEmpty ?? true)

            Button("Copy") {
                editorModel?.copySelection()
            }
            .keyboardShortcut(shortcut(.copy))
            .disabled(editorModel?.selectedClipIDs.isEmpty ?? true)

            Button("Paste") {
                if let editorModel { Task { await editorModel.paste() } }
            }
            .keyboardShortcut(shortcut(.paste))
            .disabled(!(editorModel?.hasClipboard ?? false))

            Button("Duplicate") {
                if let editorModel { Task { await editorModel.duplicateSelection() } }
            }
            .keyboardShortcut(shortcut(.duplicate))
            .disabled(editorModel?.selectedClipIDs.isEmpty ?? true)
        }

        // Cursor-style selection commands live under Edit by the system.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All Clips") {
                editorModel?.selectAllClips()
            }
            .keyboardShortcut(shortcut(.selectAll))
            .disabled(editorModel == nil)

            Button("Deselect All") {
                editorModel?.selectClip(nil)
            }
            .keyboardShortcut(shortcut(.deselectAll))
            .disabled(editorModel?.selectedClipIDs.isEmpty ?? true)
        }

        // Inject into the system View menu instead of creating our own
        // CommandMenu("View") — SwiftUI auto-creates that menu and a
        // duplicate would surface as two side-by-side View menus in
        // the menu bar. `CommandGroup(after: .sidebar)` slots our
        // entries underneath the system "Show / Hide Sidebar" item.
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Zoom In Timeline") {
                if let editorModel {
                    editorModel.zoom = min(4.0, editorModel.zoom * 1.25)
                }
            }
            .keyboardShortcut(shortcut(.zoomIn))
            .disabled(editorModel == nil)

            Button("Zoom Out Timeline") {
                if let editorModel {
                    editorModel.zoom = max(0.25, editorModel.zoom * 0.8)
                }
            }
            .keyboardShortcut(shortcut(.zoomOut))
            .disabled(editorModel == nil)

            Button("Reset Timeline Zoom") {
                editorModel?.zoom = 1.0
            }
            .keyboardShortcut(shortcut(.resetZoom))
            .disabled(editorModel == nil)

            Divider()

            Button(editorModel?.snapEnabled == false ? "Enable Snap" : "Disable Snap") {
                editorModel?.snapEnabled.toggle()
            }
            .keyboardShortcut(shortcut(.toggleSnap))
            .disabled(editorModel == nil)

            Divider()

            Button("Toggle Library") {
                NotificationCenter.default.post(name: .editorToggleLibrary, object: nil)
            }
            .keyboardShortcut(shortcut(.toggleLibrary))
            .disabled(editorModel == nil)

            Button("Toggle Inspector") {
                NotificationCenter.default.post(name: .editorToggleInspector, object: nil)
            }
            .keyboardShortcut(shortcut(.toggleInspector))
            .disabled(editorModel == nil)

            Divider()

            // Workspace presets (#64). Rendered as a flat list under
            // View — Apple's HIG prefers shallow menus, and these
            // shortcuts are common enough that hiding them in a
            // submenu would punish the muscle-memory user.
            workspaceMenuItem("Editing Workspace", .editing, action: .workspaceEditing)
            workspaceMenuItem("Color Workspace", .color, action: .workspaceColor)
            workspaceMenuItem("Audio Workspace", .audio, action: .workspaceAudio)
            workspaceMenuItem("Effects Workspace", .effects, action: .workspaceEffects)
            workspaceMenuItem("Full Preview Workspace", .fullPreview, action: .workspaceFullPreview)
        }

        CommandMenu("Library") {
            tabButton("Media", .libraryMedia, to: .media)
            tabButton("Audio", .libraryAudio, to: .audio)
            tabButton("Text", .libraryText, to: .text)
            tabButton("Stickers", .libraryStickers, to: .stickers)
            tabButton("Filters", .libraryFilters, to: .filters)
            tabButton("Captions", .libraryCaptions, to: .captions)
            tabButton("Effects", .libraryEffects, to: .effects)
            tabButton("Transitions", .libraryTransitions, to: .transitions)
        }

        CommandMenu("Playback") {
            Button(editorModel?.playback.isPlaying == true ? "Pause" : "Play") {
                editorModel?.playback.togglePlayback()
            }
            .keyboardShortcut(shortcut(.togglePlayback))
            .disabled(editorModel == nil)

            Divider()

            Button("Step Back 1 Frame") {
                editorModel?.stepFrame(by: -1)
            }
            .keyboardShortcut(shortcut(.stepBack))
            .disabled(editorModel == nil)

            Button("Step Forward 1 Frame") {
                editorModel?.stepFrame(by: 1)
            }
            .keyboardShortcut(shortcut(.stepForward))
            .disabled(editorModel == nil)

            Button("Back 1 Second") {
                editorModel?.stepSeconds(by: -1)
            }
            .keyboardShortcut(shortcut(.back1s))
            .disabled(editorModel == nil)

            Button("Forward 1 Second") {
                editorModel?.stepSeconds(by: 1)
            }
            .keyboardShortcut(shortcut(.forward1s))
            .disabled(editorModel == nil)

            Divider()

            Button("Go to Start") {
                editorModel?.playback.seek(to: 0)
            }
            .keyboardShortcut(shortcut(.goToStart))
            .disabled(editorModel == nil)

            Button("Go to End") {
                editorModel?.playback.seek(to: editorModel?.playback.duration ?? 0)
            }
            .keyboardShortcut(shortcut(.goToEnd))
            .disabled(editorModel == nil)
        }

        CommandMenu("Clip") {
            Button("Split at Playhead") {
                if let editorModel {
                    Task { await editorModel.splitClipAtPlayhead() }
                }
            }
            .keyboardShortcut(shortcut(.splitAtPlayhead))
            .disabled(editorModel == nil)

            Button("Mute / Unmute") {
                if let editorModel, let id = editorModel.selectedClipID {
                    editorModel.toggleClipMuted(id)
                }
            }
            .keyboardShortcut(shortcut(.toggleMute))
            .disabled(editorModel?.selectedClipID == nil)

            Divider()

            Button("Delete Clip") {
                if let editorModel {
                    Task { await editorModel.deleteSelectedClip() }
                }
            }
            .keyboardShortcut(shortcut(.deleteClip))
            .disabled(editorModel?.selectedClipIDs.isEmpty ?? true)

            Button("Ripple Delete") {
                if let editorModel {
                    Task { await editorModel.rippleDeleteSelectedClip() }
                }
            }
            .keyboardShortcut(shortcut(.rippleDelete))
            .disabled(editorModel?.selectedClipID == nil)
        }

        // Wrapped in a Group so the file stays under SwiftUI's
        // CommandsBuilder arity limit (10 top-level builders).
        Group {
            CommandMenu("Markers") {
                Button("Add Marker at Playhead") {
                    editorModel?.addMarkerAtPlayhead()
                }
                .keyboardShortcut(shortcut(.addMarker))
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
                .keyboardShortcut(shortcut(.prevMarker))
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
                .keyboardShortcut(shortcut(.nextMarker))
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
    private func tabButton(_ title: String, _ action: ShortcutAction, to tool: ToolCategory) -> some View {
        Button(title) {
            editorModel?.selectedTool = tool
        }
        .keyboardShortcut(shortcut(action))
        .disabled(editorModel == nil)
    }

    @ViewBuilder
    private func workspaceMenuItem(
        _ title: String,
        _ workspace: Workspace,
        action: ShortcutAction
    ) -> some View {
        Button(title) {
            withAnimation(.easeInOut(duration: 0.22)) {
                editorModel?.applyWorkspace(workspace)
            }
        }
        .keyboardShortcut(shortcut(action))
        .disabled(editorModel == nil)
    }
}

extension Notification.Name {
    static let editorToggleInspector = Notification.Name("EditOS.editor.toggleInspector")
    static let editorToggleLibrary = Notification.Name("EditOS.editor.toggleLibrary")
}
