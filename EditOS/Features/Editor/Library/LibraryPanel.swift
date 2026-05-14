import SwiftUI
import UniformTypeIdentifiers

struct LibraryPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel

    @State private var isImporterPresented = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)

    var body: some View {
        EditorPanel {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                header
                Divider().overlay(theme.colors.border)
                content
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

    @ViewBuilder
    private var content: some View {
        switch model.selectedTool {
        case .media:
            mediaGrid(filter: { _ in true })
        case .audio:
            mediaGrid(filter: { $0.kind == .audio })
        case .text:
            TextLibrary(model: model)
        case .stickers:
            StickerLibrary(model: model)
        case .captions:
            TextLibrary(model: model)
        default:
            placeholder(for: model.selectedTool)
        }
    }

    @ViewBuilder
    private func mediaGrid(filter: (MediaAsset) -> Bool) -> some View {
        let filtered = model.project.assets.filter(filter)
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: theme.spacing.sm) {
                    ForEach(filtered) { asset in
                        MediaAssetCell(asset: asset, model: model)
                    }
                }
                .padding(theme.spacing.sm)
            }
        }
    }

    private func placeholder(for tool: ToolCategory) -> some View {
        VStack(spacing: theme.spacing.sm) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 28))
                .foregroundStyle(theme.colors.textSecondary)
            Text("\(tool.label) — coming soon")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text(model.selectedTool.label)
                .font(theme.typography.title)
                .foregroundStyle(theme.colors.textPrimary)
            Spacer()
            if model.selectedTool == .media || model.selectedTool == .audio {
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
    @Environment(AppEnvironment.self) private var environment
    let asset: MediaAsset
    @Bindable var model: EditorViewModel

    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xxs) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.sm)
                    .fill(theme.colors.surfaceElevated)
                if let thumbnail {
                    // Use .fit so vertical/horizontal source frames keep their
                    // native aspect inside the uniform grid cell, with the
                    // surface color filling the letterbox gaps.
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: icon(for: asset.kind))
                        .font(.system(size: 18))
                        .foregroundStyle(theme.colors.textSecondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
            Text(asset.displayName)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        // Drag source — payload is the asset's UUID string; the timeline drop
        // destination looks the asset back up by id and adds a clip for it.
        .draggable(asset.id.uuidString) {
            DragPreview(asset: asset, thumbnail: thumbnail)
        }
        .contextMenu {
            Button {
                model.placeAsset(asset, atTime: model.playback.currentTime)
                Task { await model.reloadComposition() }
            } label: {
                Label("Add to Timeline", systemImage: "plus.rectangle.on.rectangle")
            }
            Button {
                model.revealAssetInFinder(asset.id)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) {
                Task { await model.removeAsset(asset.id) }
            } label: {
                Label("Remove from Library", systemImage: "trash")
            }
        }
        .task(id: asset.id) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard asset.kind == .video || asset.kind == .image else { return }
        do {
            let url = try await environment.assetResolver.resolve(asset)
            let image = await environment.thumbnailGenerator.poster(
                for: url,
                at: 0,
                size: CGSize(width: 320, height: 320)
            )
            guard !Task.isCancelled else { return }
            thumbnail = image
        } catch {
            // No thumbnail; the icon fallback stays.
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

private struct DragPreview: View {
    @Environment(\.theme) private var theme
    let asset: MediaAsset
    let thumbnail: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.colors.surfaceElevated)
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: asset.kind == .video ? "film" : (asset.kind == .audio ? "waveform" : "photo"))
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Text library

private struct TextLibrary: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel

    private struct Preset: Identifiable {
        let id = UUID()
        let label: String
        let sample: String
        let size: CGFloat
        let weight: Font.Weight
    }

    private let presets: [Preset] = [
        Preset(label: "Title", sample: "Title", size: 88, weight: .heavy),
        Preset(label: "Subtitle", sample: "Subtitle", size: 56, weight: .semibold),
        Preset(label: "Body", sample: "Body text", size: 40, weight: .regular),
        Preset(label: "Caption", sample: "Caption", size: 28, weight: .medium)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                Text("Tap a style to add it at the playhead.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                ForEach(presets) { preset in
                    Button {
                        model.placeText(preset.sample, atTime: model.playback.currentTime)
                    } label: {
                        HStack {
                            Text(preset.sample)
                                .font(.system(size: min(preset.size * 0.45, 24), weight: preset.weight))
                                .foregroundStyle(.white)
                            Spacer()
                            Text(preset.label)
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.textSecondary)
                        }
                        .padding(.horizontal, theme.spacing.md)
                        .padding(.vertical, theme.spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: theme.radius.sm)
                                .fill(theme.colors.surfaceElevated)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(theme.spacing.sm)
        }
    }
}

// MARK: - Sticker library

private struct StickerLibrary: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel

    private let symbols: [String] = [
        "heart.fill", "star.fill", "bolt.fill", "flame.fill", "sparkles",
        "hand.thumbsup.fill", "hands.clap", "face.smiling.fill", "party.popper.fill",
        "checkmark.seal.fill", "xmark.seal.fill", "exclamationmark.triangle.fill",
        "questionmark.circle.fill", "speaker.wave.3.fill", "music.note", "camera.fill",
        "location.fill", "moon.stars.fill", "sun.max.fill", "cloud.fill",
        "cart.fill", "gift.fill", "bell.fill", "crown.fill"
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                Text("Tap a sticker to drop it at the playhead.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                LazyVGrid(columns: columns, spacing: theme.spacing.sm) {
                    ForEach(symbols, id: \.self) { name in
                        Button {
                            model.placeSticker(name, atTime: model.playback.currentTime)
                        } label: {
                            Image(systemName: name)
                                .font(.system(size: 22))
                                .foregroundStyle(theme.colors.textPrimary)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: theme.radius.sm)
                                        .fill(theme.colors.surfaceElevated)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
            }
            .padding(theme.spacing.sm)
        }
    }
}
