import SwiftUI

struct EditorView: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @State private var model: EditorViewModel

    init(project: Project, resolver: AssetResolver) {
        _model = State(initialValue: EditorViewModel(project: project, resolver: resolver))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: theme.spacing.sm) {
                EditorToolbar(selected: $model.selectedTool)
                if model.isLibraryVisible {
                    LibraryPanel(model: model)
                        .frame(width: 280)
                }
                PreviewPanel(model: model)
                    .frame(maxWidth: .infinity)
                if model.isInspectorVisible {
                    InspectorPanel(model: model)
                        .frame(width: 320)
                }
            }
            .padding(.horizontal, theme.spacing.sm)
            .padding(.top, theme.spacing.sm)
            .frame(maxHeight: .infinity)

            TimelinePanel(model: model)
                .frame(height: 280)
                .padding(theme.spacing.sm)
        }
        .background(theme.colors.background)
        .navigationTitle(model.project.name)
        .focusedSceneValue(\.editorModel, model)
        .task(id: model.project.id) {
            await model.reloadComposition()
        }
        .onDeleteCommand {
            Task { await model.deleteSelectedClip() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorToggleInspector)) { _ in
            model.toggleInspector()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorToggleLibrary)) { _ in
            model.toggleLibrary()
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
