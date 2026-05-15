import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct LibraryPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel

    @State private var isImporterPresented = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)

    @State private var isFinderDropTargeted: Bool = false

    var body: some View {
        EditorPanel {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                header
                Divider().overlay(theme.colors.border)
                content
            }
            .padding(theme.spacing.sm)
            .overlay {
                if isFinderDropTargeted {
                    RoundedRectangle(cornerRadius: theme.radius.md)
                        .stroke(theme.colors.accent,
                                style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(theme.spacing.sm / 2)
                        .allowsHitTesting(false)
                }
            }
        }
        // Accept Finder drops of any supported media URLs.
        .dropDestination(for: URL.self) { urls, _ in
            importMedia(urls)
            return true
        } isTargeted: { isFinderDropTargeted = $0 }
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
            AudioLibrary(model: model)
        case .text:
            TextLibrary(model: model)
        case .stickers:
            StickerLibrary(model: model)
        case .captions:
            TextLibrary(model: model)
        case .filters:
            FilterLibrary(model: model)
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

/// GIPHY-powered sticker browser. Trending results load on appear, and
/// hitting return on the search field requeries. Tapping a sticker
/// downloads the GIF and drops it onto the sticker track at the playhead.
private struct StickerLibrary: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel

    @State private var query: String = ""
    @State private var stickers: [GiphyService.Sticker] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var pendingDownloadID: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            searchField
            statusLine
            ScrollView {
                LazyVGrid(columns: columns, spacing: theme.spacing.sm) {
                    ForEach(stickers) { sticker in
                        StickerCell(
                            sticker: sticker,
                            isLoading: pendingDownloadID == sticker.id,
                            onAddToTimeline: { Task { await place(sticker) } },
                            onDownload: { Task { await downloadOnly(sticker) } }
                        )
                    }
                }
                .padding(.horizontal, theme.spacing.sm)
                .padding(.bottom, theme.spacing.sm)
            }
        }
        .padding(.horizontal, theme.spacing.sm)
        .task {
            await loadTrending()
        }
    }

    private var searchField: some View {
        HStack(spacing: theme.spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.colors.textSecondary)
            TextField("Search GIPHY", text: $query)
                .textFieldStyle(.plain)
                .onSubmit {
                    Task { await runSearch(query) }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    Task { await loadTrending() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, theme.spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .fill(theme.colors.surfaceElevated)
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        if isLoading {
            HStack(spacing: theme.spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Loading stickers…")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        } else if let errorMessage {
            Text(errorMessage)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.danger)
        } else {
            Text(query.isEmpty ? "Trending stickers" : "Results for \"\(query)\"")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textSecondary)
        }
    }

    private func loadTrending() async {
        await runSearch("")
    }

    private func runSearch(_ q: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            stickers = try await environment.giphyService.search(query: q)
            if stickers.isEmpty {
                errorMessage = "No stickers found."
            }
        } catch {
            stickers = []
            // Surface the real error during development so the entitlement /
            // network problem is visible rather than a generic message.
            errorMessage = "GIPHY: \(String(describing: error))"
        }
    }

    private func place(_ sticker: GiphyService.Sticker) async {
        pendingDownloadID = sticker.id
        defer { pendingDownloadID = nil }
        do {
            let url = try await environment.giphyService.download(sticker)
            await MainActor.run {
                model.placeStickerImage(
                    localPath: url.path,
                    displayName: sticker.title,
                    atTime: model.playback.currentTime
                )
                environment.projectStore.update(model.project)
            }
        } catch {
            errorMessage = "Couldn't download that sticker."
        }
    }

    private func downloadOnly(_ sticker: GiphyService.Sticker) async {
        pendingDownloadID = sticker.id
        defer { pendingDownloadID = nil }
        do {
            _ = try await environment.giphyService.download(sticker)
        } catch {
            errorMessage = "Couldn't download that sticker."
        }
    }
}

private struct StickerCell: View {
    @Environment(\.theme) private var theme
    let sticker: GiphyService.Sticker
    let isLoading: Bool
    let onAddToTimeline: () -> Void
    let onDownload: () -> Void

    @State private var isFavorited: Bool = false
    @State private var isHovering: Bool = false

    var body: some View {
        ZStack {
            // Preview surface
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .fill(theme.colors.surfaceElevated)
            AsyncImage(url: sticker.previewURL) { phase in
                switch phase {
                case .empty:
                    ProgressView().controlSize(.small)
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                case .failure:
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(theme.colors.textTertiary)
                @unknown default:
                    EmptyView()
                }
            }

            if isLoading {
                Color.black.opacity(0.45)
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
        .overlay(alignment: .topLeading) {
            // Star toggle — UI-only favourite state for now.
            cornerBadge(
                systemImage: isFavorited ? "star.fill" : "star",
                tint: isFavorited ? theme.colors.warning : .white,
                help: isFavorited ? "Remove from favorites" : "Add to favorites"
            ) {
                isFavorited.toggle()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Download (secondary) and Add-to-timeline (primary accent) sit
            // together in the corner so the sticker preview stays fully
            // visible behind them.
            HStack(spacing: 6) {
                cornerBadge(
                    systemImage: "arrow.down.to.line",
                    tint: .white,
                    help: "Download"
                ) {
                    onDownload()
                }
                Button(action: onAddToTimeline) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(theme.colors.accent, in: Circle())
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .scaleEffect(isHovering ? 1.08 : 1.0)
                }
                .buttonStyle(.plain)
                .help("Add to timeline")
            }
            .padding(5)
        }
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .stroke(isHovering ? theme.colors.borderEmphasis : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private func cornerBadge(
        systemImage: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Color.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(5)
        .help(help)
    }
}

// MARK: - Audio library (Freesound)

/// Freesound-powered audio browser. Search → preview → download adds the
/// MP3 to the project's library and drops it on the audio track at the
/// playhead. Uses a single AVPlayer for streaming previews so only one row
/// plays at a time.
private struct AudioLibrary: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel

    @State private var query: String = ""
    @State private var sounds: [FreesoundService.Sound] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var downloadProgress: [Int: Double] = [:]
    @State private var previewingID: Int?
    @State private var previewPlayer: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            searchField
            statusLine
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sounds.enumerated()), id: \.element.id) { index, sound in
                        AudioRow(
                            sound: sound,
                            progress: downloadProgress[sound.id],
                            isPreviewing: previewingID == sound.id,
                            onTogglePreview: { togglePreview(sound) },
                            onAdd: { Task { await addToTimeline(sound) } }
                        )
                        if index < sounds.count - 1 {
                            Rectangle()
                                .fill(theme.colors.border.opacity(0.5))
                                .frame(height: 1)
                                .padding(.leading, 56)
                        }
                    }
                }
                .padding(.bottom, theme.spacing.sm)
            }
        }
        .padding(.horizontal, theme.spacing.sm)
        .task {
            await runSearch("")
        }
        .onDisappear {
            stopPreview()
        }
    }

    private var searchField: some View {
        HStack(spacing: theme.spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.colors.textSecondary)
            TextField("Search Freesound", text: $query)
                .textFieldStyle(.plain)
                .onSubmit {
                    Task { await runSearch(query) }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    Task { await runSearch("") }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, theme.spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .fill(theme.colors.surfaceElevated)
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        if isLoading {
            HStack(spacing: theme.spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Searching…")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        } else if let errorMessage {
            Text(errorMessage)
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.danger)
        } else {
            Text(query.isEmpty ? "Popular music" : "Results for \"\(query)\"")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textSecondary)
        }
    }

    private func runSearch(_ q: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            sounds = try await environment.freesoundService.search(query: q)
            if sounds.isEmpty {
                errorMessage = "No sounds found."
            }
        } catch {
            sounds = []
            errorMessage = "Couldn't reach Freesound."
        }
    }

    private func togglePreview(_ sound: FreesoundService.Sound) {
        if previewingID == sound.id {
            stopPreview()
            return
        }
        stopPreview()
        let player = AVPlayer(url: sound.previewURL)
        player.play()
        previewPlayer = player
        previewingID = sound.id
    }

    private func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        previewingID = nil
    }

    private func addToTimeline(_ sound: FreesoundService.Sound) async {
        downloadProgress[sound.id] = 0
        defer { downloadProgress[sound.id] = nil }
        do {
            let url = try await environment.freesoundService.download(sound) { value in
                Task { @MainActor in
                    downloadProgress[sound.id] = value
                }
            }
            let asset = try await environment.mediaImporter.makeAsset(from: url)
            await MainActor.run {
                model.placeAsset(asset, atTime: model.playback.currentTime)
                environment.projectStore.update(model.project)
            }
            await model.reloadComposition()
        } catch {
            errorMessage = "Couldn't add that sound."
        }
    }
}

/// Flat (non-card) audio result row. The row body itself is the play/pause
/// affordance; the accent + circle on the right downloads and adds to the
/// timeline, with a live progress ring during the download.
private struct AudioRow: View {
    @Environment(\.theme) private var theme
    let sound: FreesoundService.Sound
    /// 0…1 during an active download; `nil` when idle.
    let progress: Double?
    let isPreviewing: Bool
    let onTogglePreview: () -> Void
    let onAdd: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            playGlyph

            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(durationLabel)
                        .font(theme.typography.caption.monospacedDigit())
                    Text("·").foregroundStyle(theme.colors.textTertiary)
                    Text(sound.username)
                        .lineLimit(1)
                }
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textSecondary)
            }

            Spacer(minLength: 0)

            addControl
        }
        .padding(.horizontal, theme.spacing.sm)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            (isHovering || isPreviewing)
            ? theme.colors.surfaceElevated.opacity(0.55)
            : Color.clear
        )
        .onTapGesture { onTogglePreview() }
        .onHover { isHovering = $0 }
    }

    /// Compact play glyph — uses the row's accent fill while previewing, a
    /// ghost background while idle. Tapping it does the same thing as
    /// tapping the row body, but it gives users an obvious target.
    private var playGlyph: some View {
        ZStack {
            Circle()
                .fill(isPreviewing ? theme.colors.accent : theme.colors.surfaceHighest)
                .frame(width: 32, height: 32)
            Image(systemName: isPreviewing ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
        }
        .help(isPreviewing ? "Stop preview" : "Preview")
    }

    /// Either a downloading progress ring or the static accent + button. The
    /// ring is drawn behind a faint accent disk so progress stays legible
    /// against the row's hover background.
    @ViewBuilder
    private var addControl: some View {
        if let progress {
            ZStack {
                Circle()
                    .fill(theme.colors.accent.opacity(0.18))
                    .frame(width: 30, height: 30)
                Circle()
                    .trim(from: 0, to: max(0.04, progress))
                    .stroke(
                        theme.colors.accent,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 30, height: 30)
                    .animation(.linear(duration: 0.12), value: progress)
                Text("\(Int(progress * 100))")
                    .font(.system(size: 9, weight: .heavy).monospacedDigit())
                    .foregroundStyle(theme.colors.accent)
            }
            .help("Downloading… \(Int(progress * 100))%")
        } else {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(theme.colors.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Add to timeline")
        }
    }

    private var durationLabel: String {
        let total = max(0, sound.duration)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
