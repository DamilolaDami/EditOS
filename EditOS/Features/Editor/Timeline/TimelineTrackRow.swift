import SwiftUI

enum TimelineTrimEdge {
    case leading
    case trailing
}

struct TimelineTrackRow: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel
    let track: Track
    let pixelsPerSecond: CGFloat
    let assets: [MediaAsset]
    let selectedClipID: Clip.ID?
    let playheadTime: TimeInterval
    let onSelectClip: (Clip.ID) -> Void
    /// Sets the edge of `id` to the given timeline time (seconds).
    let onTrim: (Clip.ID, TimelineTrimEdge, TimeInterval) -> Void
    let onTrimEnded: () -> Void
    /// Move clip `id` so its leading edge lands at `newStart` (seconds).
    let onMove: (Clip.ID, TimeInterval) -> Void
    let onMoveEnded: () -> Void
    /// Scrub via taps on empty (non-clip) areas of this row.
    let onScrubEmpty: (TimeInterval) -> Void
    /// Live snap-target while dragging a clip — `nil` when no snap is active.
    let onSnapPreview: (TimeInterval?) -> Void

    /// Two boundaries closer than this (in seconds) are treated as touching.
    private let adjacencyEpsilon: TimeInterval = 0.001
    private var trackHeight: CGFloat { track.kind.timelineHeight }
    private var isCompactRow: Bool { trackHeight < 40 }

    var body: some View {
        ZStack(alignment: .leading) {
            // Background — scrubable; clips on top capture their own clicks.
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .fill(theme.colors.surfaceElevated.opacity(0.45))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(
                        minimumDistance: 0,
                        coordinateSpace: .named(TimelineCoordinateSpace.name)
                    )
                    .onChanged { value in
                        let t = max(0, Double(value.location.x / pixelsPerSecond))
                        onScrubEmpty(t)
                    }
                )

            ForEach(Array(track.clips.enumerated()), id: \.element.id) { index, clip in
                let width = max(16, CGFloat(clip.timeRange.duration) * pixelsPerSecond)
                let previousClip = index > 0 ? track.clips[index - 1] : nil
                let nextClip = index + 1 < track.clips.count ? track.clips[index + 1] : nil
                let joinedWithPrev = previousClip.map {
                    abs($0.timeRange.end - clip.timeRange.start) < adjacencyEpsilon
                } ?? false
                let joinedWithNext = nextClip.map {
                    abs($0.timeRange.start - clip.timeRange.end) < adjacencyEpsilon
                } ?? false

                let snapTargets = snapCandidates(excluding: clip.id)
                TimelineClipView(
                    clip: clip,
                    asset: assets.first(where: { $0.id == clip.assetID }),
                    width: width,
                    pixelsPerSecond: pixelsPerSecond,
                    tint: track.kind.color(in: theme),
                    isSelected: selectedClipID == clip.id,
                    isCompact: isCompactRow,
                    snapCandidates: snapTargets,
                    onTrimLeading: { x in
                        let time = max(0, Double(x / pixelsPerSecond))
                        // CapCut-style joint trim: when the leading edge is
                        // touching the previous clip's trailing edge, drag both
                        // together so there's no gap or overlap.
                        if joinedWithPrev, let prev = previousClip {
                            onTrim(prev.id, .trailing, time)
                        }
                        onTrim(clip.id, .leading, time)
                    },
                    onTrimTrailing: { x in
                        let time = max(0, Double(x / pixelsPerSecond))
                        if joinedWithNext, let next = nextClip {
                            onTrim(next.id, .leading, time)
                        }
                        onTrim(clip.id, .trailing, time)
                    },
                    onTrimEnded: onTrimEnded,
                    onMove: { pixelDelta in
                        let deltaSeconds = Double(pixelDelta / pixelsPerSecond)
                        let newStart = max(0, clip.timeRange.start + deltaSeconds)
                        onMove(clip.id, newStart)
                    },
                    onMoveEnded: onMoveEnded,
                    onSnapPreview: onSnapPreview,
                    onSelect: { onSelectClip(clip.id) }
                )
                .contextMenu {
                    Button {
                        onSelectClip(clip.id)
                        Task { await model.splitClipAtPlayhead() }
                    } label: { Label("Split at Playhead", systemImage: "scissors") }

                    Button {
                        model.toggleClipMuted(clip.id)
                    } label: {
                        Label(
                            clip.volume > 0 ? "Mute" : "Unmute",
                            systemImage: clip.volume > 0 ? "speaker.slash" : "speaker.wave.2"
                        )
                    }
                    Divider()
                    Button(role: .destructive) {
                        onSelectClip(clip.id)
                        Task { await model.deleteSelectedClip() }
                    } label: { Label("Delete", systemImage: "trash") }
                    Button(role: .destructive) {
                        onSelectClip(clip.id)
                        Task { await model.rippleDeleteSelectedClip() }
                    } label: { Label("Ripple Delete", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                }
                .frame(width: width)
                .offset(x: CGFloat(clip.timeRange.start) * pixelsPerSecond)
            }
        }
        .frame(height: trackHeight)
        .opacity(track.isHidden ? 0.4 : 1.0)
    }

    /// Times the dragged clip can snap to: timeline origin, every other clip's
    /// edges, and the current playhead.
    private func snapCandidates(excluding excludedID: Clip.ID) -> [TimeInterval] {
        var candidates: [TimeInterval] = [0, playheadTime]
        for other in track.clips where other.id != excludedID {
            candidates.append(other.timeRange.start)
            candidates.append(other.timeRange.end)
        }
        return candidates
    }
}

struct TimelineClipView: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    let clip: Clip
    let asset: MediaAsset?
    let width: CGFloat
    let pixelsPerSecond: CGFloat
    let tint: Color
    let isSelected: Bool
    /// Slim presentation for short rows (overlay / caption / sticker).
    /// Skips filmstrip + waveform and lays the label inline so the clip stays
    /// readable at ~26pt tall.
    var isCompact: Bool = false
    /// Times this clip should snap to while being dragged.
    let snapCandidates: [TimeInterval]
    let onTrimLeading: (CGFloat) -> Void
    let onTrimTrailing: (CGFloat) -> Void
    let onTrimEnded: () -> Void
    /// Pixel delta from the start of the body drag.
    let onMove: (CGFloat) -> Void
    let onMoveEnded: () -> Void
    /// Reports the active snap target (nil when none) so the panel can draw
    /// a snap line under the playhead.
    let onSnapPreview: (TimeInterval?) -> Void
    let onSelect: () -> Void

    @State private var thumbnails: [CGImage] = []
    @State private var waveformSamples: [Float] = []
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false

    private let handleWidth: CGFloat = 8
    private let thumbnailTargetWidth: CGFloat = 60

    var body: some View {
        ZStack {
            // Base tint — visible behind/around the thumbnails or waveform.
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .fill(tint.opacity(isCompact ? 1.0 : 0.85))

            if !isCompact {
                // Overlay clip preview (text / sticker) — these don't carry an
                // asset, so the filmstrip/waveform paths short-circuit cleanly.
                if let text = clip.text {
                    HStack(spacing: 4) {
                        Image(systemName: "textformat")
                            .font(.system(size: 11, weight: .bold))
                        Text(text)
                            .font(theme.typography.bodyEmphasized)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                } else if let symbol = clip.stickerSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }

                // Filmstrip thumbnails (video).
                if !thumbnails.isEmpty {
                    FilmstripRow(images: thumbnails)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
                }

                // Audio waveform. For audio clips the waveform fills the cell.
                // For video clips it tucks under the filmstrip as a thin level
                // strip so the user can still see where the loud beats are.
                if !waveformSamples.isEmpty {
                    if asset?.kind == .audio {
                        WaveformView(samples: waveformSamples, color: .white.opacity(0.9))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                            .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
                    } else {
                        VStack(spacing: 0) {
                            Spacer()
                            WaveformView(samples: waveformSamples, color: .white.opacity(0.85))
                                .frame(height: 14)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                    }
                }

                // Bottom-tinted band so the clip still reads as colored even
                // with thumbs.
                VStack(spacing: 0) {
                    Spacer()
                    Rectangle()
                        .fill(tint)
                        .frame(height: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
            }
        }
        .overlay(alignment: isCompact ? .leading : .topLeading) {
            HStack(spacing: 4) {
                if let symbol = clip.stickerSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                } else if clip.text != nil {
                    Image(systemName: "textformat")
                        .font(.system(size: 10, weight: .bold))
                } else if clip.volume == 0 {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(clip.label ?? "Clip")
                    .font(theme.typography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isCompact ? 6 : 6)
            .padding(.vertical, 2)
            .background(
                isCompact ? Color.clear : Color.black.opacity(0.55),
                in: Capsule()
            )
            .padding(.horizontal, isCompact ? 4 : theme.spacing.xs)
            .padding(.vertical, isCompact ? 0 : theme.spacing.xs)
            .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .stroke(isSelected ? theme.colors.accent : .clear, lineWidth: 2)
        }
        .overlay(alignment: .leading) {
            TrimHandle(side: .leading, isSelected: isSelected)
                .frame(width: handleWidth)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineCoordinateSpace.name))
                        .onChanged { value in onTrimLeading(value.location.x) }
                        .onEnded { _ in onTrimEnded() }
                )
        }
        .overlay(alignment: .trailing) {
            TrimHandle(side: .trailing, isSelected: isSelected)
                .frame(width: handleWidth)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineCoordinateSpace.name))
                        .onChanged { value in onTrimTrailing(value.location.x) }
                        .onEnded { _ in onTrimEnded() }
                )
        }
        .offset(x: dragOffset)
        .shadow(color: .black.opacity(isDragging ? 0.4 : 0), radius: isDragging ? 6 : 0, y: isDragging ? 2 : 0)
        .onHover { hovering in
            // Open-hand cursor over the clip body so users know they can grab
            // it. Trim handles override with resizeLeftRight on their hover.
            if hovering {
                (isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
            } else {
                NSCursor.arrow.set()
            }
        }
        // Body drag — moves the clip horizontally. minimumDistance > 0 so a
        // pure tap doesn't trigger move, leaving room for the tap-select below.
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation.width
                    onSnapPreview(snapTarget(forPixelDelta: value.translation.width))
                }
                .onEnded { value in
                    let delta = value.translation.width
                    dragOffset = 0
                    isDragging = false
                    onSnapPreview(nil)
                    if abs(delta) >= 1 {
                        onMove(delta)
                        onMoveEnded()
                    }
                }
        )
        .onTapGesture { onSelect() }
        .task(id: thumbnailKey) {
            await loadThumbnails()
        }
        .task(id: waveformKey) {
            await loadWaveform()
        }
    }

    /// Picks the snap candidate (clip start *or* clip end) closest to the
    /// dragged clip's projected position, within a six-pixel tolerance. Drives
    /// the snap-line preview while dragging.
    private func snapTarget(forPixelDelta deltaPixels: CGFloat) -> TimeInterval? {
        guard pixelsPerSecond > 0 else { return nil }
        let deltaSeconds = Double(deltaPixels / pixelsPerSecond)
        let projectedStart = clip.timeRange.start + deltaSeconds
        let projectedEnd = projectedStart + clip.timeRange.duration
        let tolerance = max(0.04, Double(6 / pixelsPerSecond))

        var bestCandidate: TimeInterval?
        var bestDistance = tolerance
        for candidate in snapCandidates {
            let dStart = abs(candidate - projectedStart)
            let dEnd = abs(candidate - projectedEnd)
            if dStart < bestDistance {
                bestCandidate = candidate
                bestDistance = dStart
            }
            if dEnd < bestDistance {
                bestCandidate = candidate
                bestDistance = dEnd
            }
        }
        return bestCandidate
    }

    private var thumbnailKey: String {
        let assetKey = asset?.id.uuidString ?? "none"
        return "\(clip.id.uuidString)|\(assetKey)|\(Int(width))|\(Int(clip.sourceRange.start * 100))|\(Int(clip.sourceRange.duration * 100))"
    }

    private var waveformKey: String {
        let assetKey = asset?.id.uuidString ?? "none"
        return "wave|\(assetKey)|\(Int(width))"
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
        guard !Task.isCancelled else { return }
        thumbnails = result
    }

    private func loadWaveform() async {
        // Pull a waveform for any asset that has an audio track — that
        // includes regular video clips, so we can show levels under the
        // filmstrip.
        guard let asset, asset.kind == .audio || asset.kind == .video else {
            waveformSamples = []
            return
        }
        let url: URL
        do {
            url = try await environment.assetResolver.resolve(asset)
        } catch {
            waveformSamples = []
            return
        }
        let bucketCount = max(40, min(400, Int(width / 2)))
        let samples = await environment.waveformGenerator.samples(
            for: url,
            bucketCount: bucketCount
        )
        guard !Task.isCancelled else { return }
        waveformSamples = samples
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

/// Bar-style audio level visualiser, mirrored about the centre line.
private struct WaveformView: View {
    let samples: [Float]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard !samples.isEmpty else { return }
                let barCount = samples.count
                let barWidth = max(1, (size.width / CGFloat(barCount)) * 0.7)
                let gap = max(0, (size.width / CGFloat(barCount)) * 0.3)
                let centerY = size.height / 2
                let maxHeight = size.height / 2
                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * (barWidth + gap)
                    let h = max(1, CGFloat(sample) * maxHeight)
                    let rect = CGRect(x: x, y: centerY - h, width: barWidth, height: h * 2)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color)
                    )
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
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }
}
