import CoreImage
import SwiftUI

/// Filters tab — CapCut-style grid of CI filter presets, each rendered as a
/// live thumbnail from the user's first video clip so they preview against
/// real content. Tapping a tile applies the filter to the current selection;
/// an intensity slider appears at the bottom while a filter is active.
struct FilterLibrary: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel

    @State private var posterImage: CGImage?
    @State private var intensityDraft: Double = 1.0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
    private let ciContext: CIContext = CIContext(options: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            header
            if posterImage == nil {
                placeholderBanner
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(FilterCatalog.presets) { preset in
                        FilterTile(
                            preset: preset,
                            rendered: posterImage,
                            isSelected: activePreset == preset.id,
                            onTap: { placeFilter(preset.id) }
                        )
                        .environment(\.ciContext, ciContext)
                    }
                }
                .padding(.bottom, theme.spacing.sm)
            }
            if activePreset != nil {
                intensityBar
            }
        }
        .padding(.horizontal, theme.spacing.sm)
        .task(id: posterKey) { await loadPoster() }
        .onChange(of: activeIntensity ?? 1.0) { _, new in
            intensityDraft = new
        }
        .onAppear {
            intensityDraft = activeIntensity ?? 1.0
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tap a filter to drop it at the playhead.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                Text(activePreset == nil ? "Choose a look" : currentFilterName)
                    .font(theme.typography.bodyEmphasized)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            if isFilterClipSelected {
                Button(role: .destructive) {
                    Task { await model.deleteSelectedClips() }
                } label: { Text("Remove") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.colors.danger)
            }
        }
    }

    private var placeholderBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(theme.colors.accent)
            Text("Add a video to see live filter previews.")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textSecondary)
            Spacer()
        }
        .padding(.horizontal, theme.spacing.sm)
        .padding(.vertical, 8)
        .background(theme.colors.surfaceElevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var intensityBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Intensity")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                Spacer()
                Text("\(Int(intensityDraft * 100))%")
                    .font(theme.typography.caption.monospacedDigit())
                    .foregroundStyle(theme.colors.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.colors.surfaceElevated, in: Capsule())
            }
            Slider(value: $intensityDraft, in: 0...1) { editing in
                model.setFilterIntensity(intensityDraft)
                if !editing {
                    // Commit reloads composition so the change persists in
                    // the player.
                    Task { await model.reloadComposition() }
                }
            }
            .tint(theme.colors.accent)
        }
        .padding(theme.spacing.sm)
        .background(theme.colors.surfaceElevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private var currentFilterName: String {
        guard let id = activePreset else { return "None" }
        return FilterCatalog.find(id: id)?.displayName ?? "None"
    }

    /// The selected clip's filter, if the selection is a filter clip on a
    /// `.filter` track. Drives the intensity slider + Remove button.
    private var activePreset: String? {
        selectedFilterClip()?.filterPreset
    }

    private var activeIntensity: Double? {
        selectedFilterClip()?.filterIntensity
    }

    private var isFilterClipSelected: Bool {
        selectedFilterClip() != nil
    }

    private func selectedFilterClip() -> Clip? {
        guard let id = model.selectedClipIDs.first else { return nil }
        for track in model.project.timeline.tracks where track.kind == .filter {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return clip
            }
        }
        return nil
    }

    private func placeFilter(_ presetID: String) {
        model.placeFilter(presetID, atTime: model.playback.currentTime)
    }

    /// Trigger key for the poster preview — re-renders when the first video
    /// clip's asset changes.
    private var posterKey: String {
        firstVideoClip()?.assetID.uuidString ?? "no-clip"
    }

    private func firstVideoClip() -> Clip? {
        for track in model.project.timeline.tracks where track.kind == .video {
            if let clip = track.clips.first { return clip }
        }
        return nil
    }

    private func loadPoster() async {
        guard let clip = firstVideoClip(),
              let asset = model.project.assets.first(where: { $0.id == clip.assetID }),
              asset.kind == .video else {
            await MainActor.run { posterImage = nil }
            return
        }
        guard let url = try? await environment.assetResolver.resolve(asset) else {
            await MainActor.run { posterImage = nil }
            return
        }
        let image = await environment.thumbnailGenerator.poster(
            for: url,
            at: clip.sourceRange.start + clip.sourceRange.duration / 2,
            size: CGSize(width: 320, height: 320)
        )
        await MainActor.run { posterImage = image }
    }
}

// MARK: - Tile

private struct FilterTile: View {
    @Environment(\.theme) private var theme
    @Environment(\.ciContext) private var ciContext
    let preset: FilterPreset
    let rendered: CGImage?
    let isSelected: Bool
    let onTap: () -> Void

    @State private var preview: CGImage?
    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.colors.surfaceElevated)
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if rendered != nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: preset.symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(theme.colors.textSecondary)
                    }
                }
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected ? theme.colors.accent : Color.clear,
                            lineWidth: 2
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.white, theme.colors.accent)
                            .padding(6)
                    }
                }
                .scaleEffect(isHovering ? 1.015 : 1.0)
                .shadow(color: isSelected ? theme.colors.accent.opacity(0.35) : .clear, radius: 8, y: 3)
                Text(preset.displayName)
                    .font(theme.typography.caption)
                    .foregroundStyle(isSelected ? theme.colors.accent : theme.colors.textPrimary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .task(id: previewKey) { await renderPreview() }
    }

    private var previewKey: String {
        let posterHash = rendered.map { ObjectIdentifier($0).hashValue.description } ?? "none"
        return "\(preset.id)|\(posterHash)"
    }

    private func renderPreview() async {
        guard let cg = rendered else {
            preview = nil
            return
        }
        // Off the main actor for the CI work, then bounce the final image
        // back to populate @State.
        let context = ciContext
        let presetCopy = preset
        let result: CGImage? = await Task.detached {
            let input = CIImage(cgImage: cg)
            let filtered = presetCopy.apply(input, 1.0)
            return context.createCGImage(filtered, from: input.extent)
        }.value
        await MainActor.run { preview = result }
    }
}

// MARK: - CIContext env key

private struct CIContextKey: EnvironmentKey {
    static let defaultValue: CIContext = CIContext(options: nil)
}

extension EnvironmentValues {
    fileprivate var ciContext: CIContext {
        get { self[CIContextKey.self] }
        set { self[CIContextKey.self] = newValue }
    }
}
