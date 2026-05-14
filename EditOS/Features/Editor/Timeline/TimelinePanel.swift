import SwiftUI

struct TimelinePanel: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel
    @State private var isDropTargeted: Bool = false
    @State private var snapPreviewTime: TimeInterval?
    @State private var zoomAtPinchStart: Double?

    /// Pixels per second at zoom = 1.
    private let basePixelsPerSecond: CGFloat = 60
    private let headerWidth: CGFloat = 168
    private let rulerHeight: CGFloat = 36
    private let coverLaneHeight: CGFloat = 34
    private let bottomScrubZoneHeight: CGFloat = 24
    private let toolbarHeight: CGFloat = 38
    /// Hard ceiling so a project with twenty tracks doesn't swallow the
    /// preview. Content above this height scrolls inside the panel.
    private let maxPanelHeight: CGFloat = 360

    var body: some View {
        EditorPanel {
            VStack(spacing: 0) {
                TimelineToolbar(model: model)
                Divider().overlay(theme.colors.border)
                // Single vertical scroll wraps headers + tracks so they move
                // together. Inner horizontal scroll only scrolls the clip
                // content, keeping headers pinned to the left.
                ScrollView(.vertical, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        headerColumn
                        timelineScroll
                    }
                }
            }
        }
        .frame(height: panelHeight)
    }

    /// Natural height of the rows inside the panel (rulers + tracks + chrome).
    private var contentHeight: CGFloat {
        let tracks = model.project.timeline.tracks
        let trackTotal = tracks.reduce(0) { $0 + $1.kind.timelineHeight }
        // ruler + cover + each track + the bottom scrub gap, separated by
        // spacing.xxs between every pair.
        let rowCount = CGFloat(tracks.count + 3)
        let spacings = max(0, rowCount - 1) * theme.spacing.xxs
        let padding = theme.spacing.sm * 2
        return rulerHeight + coverLaneHeight + trackTotal + bottomScrubZoneHeight + spacings + padding
    }

    /// Final panel height. Grows with track count, then clamps to a ceiling
    /// so the preview keeps useful room; scrolling kicks in past that point.
    private var panelHeight: CGFloat {
        min(maxPanelHeight, toolbarHeight + 1 /* divider */ + contentHeight)
    }

    // MARK: - Track header column

    private var headerColumn: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xxs) {
            // Ruler placeholder so the first track row aligns vertically with
            // the timeline's first track row.
            Color.clear.frame(height: rulerHeight)
            // Cover lane placeholder.
            Color.clear.frame(height: coverLaneHeight)
            ForEach(model.project.timeline.tracks) { track in
                TimelineTrackHeader(model: model, track: track)
                    .frame(height: track.kind.timelineHeight)
            }
            addTrackMenu
            // No trailing Spacer — outer vertical ScrollView sizes the column
            // to its natural height; otherwise Spacer would expand to fill
            // the scroll container and break the alignment with timeline rows.
        }
        .padding(theme.spacing.sm)
        .frame(width: headerWidth)
        .background(theme.colors.surface.opacity(0.5))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.colors.border)
                .frame(width: 1)
        }
    }

    private var addTrackMenu: some View {
        Menu {
            Button {
                model.addTrack(kind: .video)
            } label: { Label("Video Track", systemImage: "film") }
            Button {
                model.addTrack(kind: .audio)
            } label: { Label("Audio Track", systemImage: "waveform") }
            Button {
                model.addTrack(kind: .overlay)
            } label: { Label("Overlay Track", systemImage: "rectangle.on.rectangle") }
            Button {
                model.addTrack(kind: .caption)
            } label: { Label("Caption Track", systemImage: "captions.bubble") }
            Button {
                model.addTrack(kind: .sticker)
            } label: { Label("Sticker Track", systemImage: "face.smiling") }
        } label: {
            HStack(spacing: theme.spacing.xs) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text("Add Track")
                    .font(theme.typography.caption)
                Spacer()
            }
            .padding(.horizontal, theme.spacing.sm)
            .frame(height: 30)
            .foregroundStyle(theme.colors.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.sm)
                    .stroke(theme.colors.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Timeline scroll content

    private var timelineScroll: some View {
        // Horizontal-only ScrollView. Vertical scrolling happens at the outer
        // wrapper so the header column stays in lockstep with the rows.
        ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: theme.spacing.xxs) {
                        TimelineRuler(
                            duration: timelineDuration,
                            pixelsPerSecond: pixelsPerSecond,
                            onScrub: { time in scrub(to: time) }
                        )
                        CoverLane(model: model)
                        ForEach(model.project.timeline.tracks) { track in
                            TimelineTrackRow(
                                model: model,
                                track: track,
                                pixelsPerSecond: pixelsPerSecond,
                                assets: model.project.assets,
                                selectedClipID: model.selectedClipID,
                                playheadTime: model.playback.currentTime,
                                onSelectClip: { model.selectClip($0) },
                                onTrim: { id, edge, time in
                                    switch edge {
                                    case .leading:
                                        model.trimLeading(id, to: time)
                                    case .trailing:
                                        model.trimTrailing(id, to: time)
                                    }
                                },
                                onTrimEnded: {
                                    Task { await model.reloadComposition() }
                                },
                                onMove: { id, newStart in
                                    model.moveClip(id, toStart: newStart)
                                },
                                onMoveEnded: {
                                    Task { await model.reloadComposition() }
                                },
                                onScrubEmpty: { time in scrub(to: time) },
                                onSnapPreview: { time in snapPreviewTime = time }
                            )
                        }
                        // Empty area below the last track — scrub here too,
                        // CapCut-style. Clips never live here so this never
                        // steals input from a clip body.
                        Rectangle()
                            .fill(Color.clear)
                            .frame(minHeight: 24)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(
                                    minimumDistance: 0,
                                    coordinateSpace: .named(TimelineCoordinateSpace.name)
                                )
                                .onChanged { value in
                                    model.selectClip(nil)
                                    let t = max(0, Double(value.location.x / pixelsPerSecond))
                                    scrub(to: min(t, timelineDuration))
                                }
                            )
                    }
                    // Live snap-line shown while dragging a clip onto a snap
                    // target — rendered below the playhead so the playhead
                    // still wins visually. Skipped when snap is toggled off.
                    if model.snapEnabled, let snapTime = snapPreviewTime {
                        SnapLine(time: snapTime, pixelsPerSecond: pixelsPerSecond)
                    }
                    TimelinePlayhead(
                        time: model.playback.currentTime,
                        pixelsPerSecond: pixelsPerSecond,
                        duration: timelineDuration,
                        onScrub: { time in scrub(to: time) }
                    )
                }
                // Coordinate space lives on the inner ZStack — padding is
                // applied outside so drag locations match content x cleanly.
                .coordinateSpace(name: TimelineCoordinateSpace.name)
                .padding(theme.spacing.sm)
                .dropDestination(for: String.self) { items, location in
                    let pad = theme.spacing.sm
                    let x = max(0, location.x - pad)
                    let dropTime = Double(x / pixelsPerSecond)
                    for raw in items {
                        guard let assetID = UUID(uuidString: raw),
                              let asset = model.project.assets.first(where: { $0.id == assetID })
                        else { continue }
                        model.placeAsset(asset, atTime: dropTime)
                    }
                    Task { await model.reloadComposition() }
                    return true
                } isTargeted: { targeted in
                    isDropTargeted = targeted
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: theme.radius.md)
                            .stroke(theme.colors.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .padding(theme.spacing.sm / 2)
                            .allowsHitTesting(false)
                    }
                }
                // Trackpad pinch zooms the timeline — captures the base zoom
                // at gesture start so each tick scales smoothly.
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = zoomAtPinchStart ?? model.zoom
                            zoomAtPinchStart = start
                            let target = start * value.magnification
                            model.zoom = min(4.0, max(0.25, target))
                        }
                        .onEnded { _ in
                            zoomAtPinchStart = nil
                        }
                )
            }
    }

    private func scrub(to time: TimeInterval) {
        model.playback.pause()
        model.playback.seek(to: time)
    }

    private var pixelsPerSecond: CGFloat {
        basePixelsPerSecond * CGFloat(model.zoom)
    }

    private var timelineDuration: TimeInterval {
        max(model.project.timeline.duration, 30)
    }
}

/// Vertical magenta dashed line drawn at the snap target while dragging.
private struct SnapLine: View {
    @Environment(\.theme) private var theme
    let time: TimeInterval
    let pixelsPerSecond: CGFloat

    var body: some View {
        Rectangle()
            .fill(theme.colors.warning)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
            .overlay(
                Rectangle()
                    .stroke(theme.colors.warning, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            )
            .offset(x: CGFloat(time) * pixelsPerSecond - 0.75)
            .allowsHitTesting(false)
    }
}

private struct TimelineToolbar: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel

    var body: some View {
        HStack(spacing: theme.spacing.md) {
            Button { } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(true)
                .help("Undo (coming soon)")
            Button { } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(true)
                .help("Redo (coming soon)")
            Button {
                Task { await model.splitClipAtPlayhead() }
            } label: { Image(systemName: "scissors") }
                .help("Split at playhead (⌘B)")
            Button {
                Task { await model.deleteSelectedClip() }
            } label: { Image(systemName: "trash") }
                .disabled(model.selectedClipID == nil)
                .help("Delete selected clip")
            Divider().frame(height: 16)
            Button {
                model.snapEnabled.toggle()
            } label: {
                Image(systemName: model.snapEnabled ? "magnet" : "magnet.slash")
            }
            .foregroundStyle(model.snapEnabled ? theme.colors.accent : theme.colors.textSecondary)
            .help(model.snapEnabled ? "Disable snapping" : "Enable snapping")
            Spacer()
            Text(timecode(model.playback.currentTime) + " / " + timecode(model.project.timeline.duration))
                .font(theme.typography.caption.monospacedDigit())
                .foregroundStyle(theme.colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(theme.colors.surfaceElevated, in: Capsule())
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(theme.colors.textSecondary)
            Slider(value: $model.zoom, in: 0.25...4.0)
                .frame(width: 160)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(theme.colors.textSecondary)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.colors.textPrimary)
        .padding(.horizontal, theme.spacing.sm)
        .padding(.vertical, theme.spacing.xs)
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = Int(total) % 60
        let frames = Int((total - floor(total)) * 30)
        return String(format: "%02d:%02d.%02d", minutes, secs, frames)
    }
}
