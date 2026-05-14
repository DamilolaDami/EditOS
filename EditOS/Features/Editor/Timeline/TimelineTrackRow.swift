import SwiftUI

struct TimelineTrackRow: View {
    @Environment(\.theme) private var theme
    let track: Track
    let pixelsPerSecond: CGFloat
    let assets: [MediaAsset]
    let selectedClipID: Clip.ID?
    let onSelectClip: (Clip.ID) -> Void
    let onTrimLeading: (Clip.ID, CGFloat) -> Void
    let onTrimTrailing: (Clip.ID, CGFloat) -> Void
    let onTrimEnded: () -> Void

    private let trackHeight: CGFloat = 56

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .fill(theme.colors.surfaceElevated.opacity(0.5))
            ForEach(track.clips) { clip in
                let width = max(16, CGFloat(clip.timeRange.duration) * pixelsPerSecond)
                TimelineClipView(
                    clip: clip,
                    asset: assets.first(where: { $0.id == clip.assetID }),
                    width: width,
                    tint: track.kind.color(in: theme),
                    isSelected: selectedClipID == clip.id,
                    onTrimLeading: { x in onTrimLeading(clip.id, x) },
                    onTrimTrailing: { x in onTrimTrailing(clip.id, x) },
                    onTrimEnded: onTrimEnded
                )
                .frame(width: width)
                .offset(x: CGFloat(clip.timeRange.start) * pixelsPerSecond)
                .onTapGesture { onSelectClip(clip.id) }
            }
        }
        .frame(height: trackHeight)
        .opacity(track.isHidden ? 0.4 : 1.0)
    }
}

struct TimelineClipView: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    let clip: Clip
    let asset: MediaAsset?
    let width: CGFloat
    let tint: Color
    let isSelected: Bool
    let onTrimLeading: (CGFloat) -> Void
    let onTrimTrailing: (CGFloat) -> Void
    let onTrimEnded: () -> Void

    @State private var thumbnails: [CGImage] = []

    private let handleWidth: CGFloat = 8
    private let thumbnailTargetWidth: CGFloat = 60

    var body: some View {
        ZStack {
            // Base tint — visible behind/around the thumbnails.
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .fill(tint.opacity(0.85))

            // Filmstrip thumbnails.
            if !thumbnails.isEmpty {
                FilmstripRow(images: thumbnails)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
            }

            // Bottom-tinted band so the clip still reads as colored even with thumbs.
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(tint)
                    .frame(height: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
        }
        .overlay(alignment: .topLeading) {
            Text(clip.label ?? "Clip")
                .font(theme.typography.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(theme.spacing.xs)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .stroke(isSelected ? theme.colors.accent : .clear, lineWidth: 2)
        }
        .overlay(alignment: .leading) {
            TrimHandle(side: .leading, isSelected: isSelected)
                .frame(width: handleWidth)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineCoordinateSpace.name))
                        .onChanged { value in onTrimLeading(value.location.x) }
                        .onEnded { _ in onTrimEnded() }
                )
        }
        .overlay(alignment: .trailing) {
            TrimHandle(side: .trailing, isSelected: isSelected)
                .frame(width: handleWidth)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineCoordinateSpace.name))
                        .onChanged { value in onTrimTrailing(value.location.x) }
                        .onEnded { _ in onTrimEnded() }
                )
        }
        .task(id: thumbnailKey) {
            await loadThumbnails()
        }
    }

    private var thumbnailKey: String {
        let assetKey = asset?.id.uuidString ?? "none"
        return "\(clip.id.uuidString)|\(assetKey)|\(Int(width))|\(Int(clip.sourceRange.start * 100))|\(Int(clip.sourceRange.duration * 100))"
    }

    private func loadThumbnails() async {
        guard let asset, asset.kind == .video, width > 16 else {
            thumbnails = []
            return
        }
        let url: URL
        do {
            url = try await environment.assetResolver.resolve(asset)
        } catch {
            thumbnails = []
            return
        }
        let count = max(1, min(20, Int(width / thumbnailTargetWidth)))
        let result = await environment.thumbnailGenerator.filmstrip(
            for: url,
            range: clip.sourceRange,
            frameCount: count,
            size: CGSize(width: 160, height: 90)
        )
        // Bail if the view's clip/width changed underneath us.
        guard !Task.isCancelled else { return }
        thumbnails = result
    }
}

private struct FilmstripRow: View {
    let images: [CGImage]

    var body: some View {
        GeometryReader { proxy in
            let cellWidth = proxy.size.width / CGFloat(max(1, images.count))
            HStack(spacing: 0) {
                ForEach(images.indices, id: \.self) { index in
                    Image(decorative: images[index], scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cellWidth, height: proxy.size.height)
                        .clipped()
                }
            }
        }
    }
}

private struct TrimHandle: View {
    @Environment(\.theme) private var theme
    enum Side { case leading, trailing }
    let side: Side
    let isSelected: Bool

    var body: some View {
        Rectangle()
            .fill(isSelected ? theme.colors.accent.opacity(0.9) : Color.clear)
            .overlay {
                if isSelected {
                    Rectangle()
                        .fill(.white.opacity(0.8))
                        .frame(width: 2, height: 22)
                }
            }
            .contentShape(Rectangle())
    }
}
