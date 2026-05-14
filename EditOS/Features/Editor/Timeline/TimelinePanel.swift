import SwiftUI

struct TimelinePanel: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel

    /// Pixels per second at zoom = 1.
    private let basePixelsPerSecond: CGFloat = 60

    var body: some View {
        EditorPanel {
            VStack(spacing: 0) {
                TimelineToolbar(model: model)
                Divider().overlay(theme.colors.border)
                GeometryReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
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
                                        track: track,
                                        pixelsPerSecond: pixelsPerSecond,
                                        assets: model.project.assets,
                                        selectedClipID: model.selectedClipID,
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
                                        onScrubEmpty: { time in scrub(to: time) }
                                    )
                                }
                                // Empty area below the last track — scrub here too,
                                // CapCut-style. Clips never live here so this never
                                // steals input from a clip body.
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(minHeight: 80)
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
                        .frame(
                            minWidth: proxy.size.width,
                            minHeight: proxy.size.height,
                            alignment: .topLeading
                        )
                        .dropDestination(for: String.self) { items, location in
                            // location is in this padded view's local coords;
                            // subtract the leading padding so x=0 lines up with
                            // timeline time 0.
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
                        }
                    }
                }
            }
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
            Spacer()
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
}
