import SwiftUI
import UniformTypeIdentifiers

struct LibraryPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel

    @State private var isImporterPresented = false

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)]

    var body: some View {
        EditorPanel {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                header
                Divider().overlay(theme.colors.border)
                if model.project.assets.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: theme.spacing.sm) {
                            ForEach(model.project.assets) { asset in
                                MediaAssetCell(asset: asset)
                            }
                        }
                        .padding(theme.spacing.sm)
                    }
                }
            }
            .padding(theme.spacing.sm)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: MediaImporter.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            importMedia(urls)
        }
    }

    private var header: some View {
        HStack {
            Text(model.selectedTool.label)
                .font(theme.typography.title)
                .foregroundStyle(theme.colors.textPrimary)
            Spacer()
            Button {
                isImporterPresented = true
            } label: {
                Label("Import", systemImage: "plus")
                    .font(theme.typography.body)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme.colors.accent)
        }
    }

    private var emptyState: some View {
        VStack(spacing: theme.spacing.sm) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28))
                .foregroundStyle(theme.colors.textSecondary)
            Text("Drop media here or click Import")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func importMedia(_ urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                // The fileImporter URL needs an active security scope for the
                // duration of metadata reads and bookmark creation.
                let didStart = url.startAccessingSecurityScopedResource()
                defer {
                    if didStart { url.stopAccessingSecurityScopedResource() }
                }
                guard let asset = try? await environment.mediaImporter.makeAsset(from: url) else {
                    continue
                }
                model.addAsset(asset)
            }
            environment.projectStore.update(model.project)
            await model.reloadComposition()
        }
    }
}

private struct MediaAssetCell: View {
    @Environment(\.theme) private var theme
    let asset: MediaAsset

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xxs) {
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .fill(theme.colors.surfaceElevated)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    Image(systemName: icon(for: asset.kind))
                        .font(.system(size: 22))
                        .foregroundStyle(theme.colors.textSecondary)
                }
            Text(asset.displayName)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1)
        }
    }

    private func icon(for kind: MediaAsset.Kind) -> String {
        switch kind {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }
}
