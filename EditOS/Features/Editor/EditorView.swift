import SwiftUI

struct EditorView: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @State private var model: EditorViewModel

    init(project: Project, resolver: AssetResolver) {
        _model = State(initialValue: EditorViewModel(project: project, resolver: resolver))
    }

    /// Seed model state from user preferences before the first render
    /// so a fresh editor honours the General → Defaults tab without
    /// the user having to interact first.
    private func applyPreferenceDefaults() {
        model.snapEnabled = environment.preferences.snapEnabledByDefault
        model.saveDebounce = environment.preferences.autoSaveDebounce
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(model: model)
            HStack(spacing: theme.spacing.sm) {
                EditorToolbar(selected: $model.selectedTool)
                if model.isLibraryVisible {
                    LibraryPanel(model: model)
                        .frame(width: 280)
                        // Slide + fade so workspace switches feel
                        // intentional. Toolbar + preview stay put
                        // because they're never conditionally hidden.
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                PreviewPanel(model: model)
                    .frame(maxWidth: .infinity)
                if model.isInspectorVisible {
                    InspectorPanel(model: model)
                        .frame(width: 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, theme.spacing.sm)
            .padding(.top, theme.spacing.sm)
            .frame(maxHeight: .infinity)
            // Tween panel visibility off `currentWorkspace`. The
            // toggle-on-the-fly notifications (⌘⌥L / ⌘⌥I) drive their
            // mutations through `withAnimation` blocks instead, so
            // manual toggles also animate without double-firing here.
            .animation(.easeInOut(duration: 0.22), value: model.currentWorkspace)

            TimelinePanel(model: model)
                .padding(theme.spacing.sm)
        }
        .background(theme.colors.background)
        .navigationTitle(model.project.name)
        .focusedSceneValue(\.editorModel, model)
        .task(id: model.project.id) {
            await model.reloadComposition()
        }
        .onAppear {
            applyPreferenceDefaults()
        }
        .onChange(of: environment.preferences.autoSaveDebounce) { _, newValue in
            model.saveDebounce = newValue
        }
        // Persist project edits (trim, move, delete, mute, cover, etc.). The
        // model coalesces bursts into a single trailing-edge write so a
        // continuous drag collapses to one disk hit instead of dozens.
        .onChange(of: model.project) { _, newProject in
            model.scheduleSave {
                environment.projectStore.update(newProject)
            }
        }
        // Flush any in-flight debounced save before the window tears down
        // so we don't lose the trailing edits inside the debounce window.
        .onDisappear {
            model.flushPendingSave()
        }
        .onDeleteCommand {
            Task { await model.deleteSelectedClip() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorToggleInspector)) { _ in
            withAnimation(.easeInOut(duration: 0.22)) {
                model.toggleInspector()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorToggleLibrary)) { _ in
            withAnimation(.easeInOut(duration: 0.22)) {
                model.toggleLibrary()
            }
        }
    }
}

private struct EditorModelKey: FocusedValueKey {
    typealias Value = EditorViewModel
}

extension FocusedValues {
    var editorModel: EditorViewModel? {
        get { self[EditorModelKey.self] }
        set { self[EditorModelKey.self] = newValue }
    }
}
