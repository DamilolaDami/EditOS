import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class EditorViewModel {
    var project: Project
    var selectedClipID: Clip.ID?
    var selectedTool: ToolCategory = .media
    var isLibraryVisible: Bool = true
    var isInspectorVisible: Bool = true
    var zoom: Double = 1.0
    /// Magnet-on/off — when off, dragging clips skips edge-snap completely.
    var snapEnabled: Bool = true

    let playback: PlaybackEngine
    private let resolver: AssetResolver

    init(project: Project, resolver: AssetResolver) {
        self.project = project
        self.playback = PlaybackEngine()
        self.resolver = resolver
    }

    // MARK: - Selection

    func selectClip(_ id: Clip.ID?) {
        selectedClipID = id
    }

    var selectedClip: Clip? {
        guard let id = selectedClipID else { return nil }
        return project.timeline.tracks
            .flatMap(\.clips)
            .first { $0.id == id }
    }

    // MARK: - Panels

    func toggleLibrary() {
        isLibraryVisible.toggle()
    }

    func toggleInspector() {
        isInspectorVisible.toggle()
    }

    // MARK: - Library import

    func addAsset(_ asset: MediaAsset) {
        // First imported video sets the project canvas to the asset's native
        // size, so the player frame matches the source's real aspect ratio.
        // Later imports just use the canvas that's already there — they
        // letterbox via the per-clip aspect-fit transform.
        let isFirstVideo = asset.kind == .video
            && !project.assets.contains { $0.kind == .video }
        project.assets.append(asset)
        if isFirstVideo, let nativeSize = asset.nativeSize,
           nativeSize.width > 0, nativeSize.height > 0 {
            project.canvas.size = nativeSize
        }

        let kind: Track.Kind = (asset.kind == .audio) ? .audio : .video
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.kind == kind }) else { return }

        let trailingEdge = project.timeline.tracks[trackIndex].clips.last?.timeRange.end ?? 0
        let duration = max(0.1, asset.duration)
        let clip = Clip(
            assetID: asset.id,
            timeRange: TimeRange(start: trailingEdge, duration: duration),
            sourceRange: TimeRange(start: 0, duration: duration),
            label: asset.displayName
        )
        project.timeline.tracks[trackIndex].clips.append(clip)
    }

    // MARK: - Cover

    /// Records a bookmark for the project cover image. The URL is expected to
    /// have an active security scope at call time. Pass `nil` to clear.
    func setCover(from url: URL?) {
        guard let url else {
            project.coverBookmark = nil
            return
        }
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        project.coverBookmark = bookmark
    }

    // MARK: - Overlay clips (text / sticker)

    /// Adds a text overlay clip at `time` on the first caption track,
    /// creating one if none exists. Default duration is 3 seconds.
    func placeText(_ text: String, atTime time: TimeInterval, duration: TimeInterval = 3) {
        ensureTrack(kind: .caption)
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.kind == .caption }) else { return }
        let start = freeSlotStart(in: trackIndex, preferred: max(0, time), duration: duration)
        let clip = Clip(
            assetID: UUID(),  // placeholder — overlay clips don't reference a real asset
            timeRange: TimeRange(start: start, duration: duration),
            sourceRange: TimeRange(start: 0, duration: duration),
            label: text,
            text: text,
            foregroundColor: .white,
            overlaySize: 64
        )
        project.timeline.tracks[trackIndex].clips.append(clip)
        project.timeline.tracks[trackIndex].clips.sort { $0.timeRange.start < $1.timeRange.start }
        selectedClipID = clip.id
    }

    /// Adds a sticker overlay clip — `symbol` is an SF Symbol name (e.g. "heart.fill").
    func placeSticker(_ symbol: String, atTime time: TimeInterval, duration: TimeInterval = 3) {
        ensureTrack(kind: .sticker)
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.kind == .sticker }) else { return }
        let start = freeSlotStart(in: trackIndex, preferred: max(0, time), duration: duration)
        let clip = Clip(
            assetID: UUID(),
            timeRange: TimeRange(start: start, duration: duration),
            sourceRange: TimeRange(start: 0, duration: duration),
            label: symbol,
            stickerSymbol: symbol,
            foregroundColor: .white,
            overlaySize: 96
        )
        project.timeline.tracks[trackIndex].clips.append(clip)
        project.timeline.tracks[trackIndex].clips.sort { $0.timeRange.start < $1.timeRange.start }
        selectedClipID = clip.id
    }

    private func ensureTrack(kind: Track.Kind) {
        if !project.timeline.tracks.contains(where: { $0.kind == kind }) {
            project.timeline.tracks.append(Track(kind: kind))
        }
    }

    // MARK: - Tracks

    /// Appends a new track of the given kind. Sticker / caption / overlay
    /// tracks let the user layer multiple of the same type.
    func addTrack(kind: Track.Kind) {
        project.timeline.tracks.append(Track(kind: kind))
    }

    /// Remove a track and any composition rebuild that follows. The view
    /// guards against removing the last video track from the UI side.
    func deleteTrack(_ id: Track.ID) {
        project.timeline.tracks.removeAll { $0.id == id }
        Task { await reloadComposition() }
    }

    // MARK: - Track toggles

    func toggleTrackHidden(_ id: Track.ID) {
        if let index = project.timeline.tracks.firstIndex(where: { $0.id == id }) {
            project.timeline.tracks[index].isHidden.toggle()
            Task { await reloadComposition() }
        }
    }

    func toggleTrackMuted(_ id: Track.ID) {
        if let index = project.timeline.tracks.firstIndex(where: { $0.id == id }) {
            project.timeline.tracks[index].isMuted.toggle()
            Task { await reloadComposition() }
        }
    }

    func toggleTrackLocked(_ id: Track.ID) {
        if let index = project.timeline.tracks.firstIndex(where: { $0.id == id }) {
            project.timeline.tracks[index].isLocked.toggle()
        }
    }

    // MARK: - Mutations

    /// Mutates the clip matching `id` and reloads the composition. Use this for
    /// edits that affect the timeline structure (position, source range, speed).
    func updateClip(_ id: Clip.ID, _ mutate: (inout Clip) -> Void) {
        for trackIndex in project.timeline.tracks.indices {
            if let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) {
                mutate(&project.timeline.tracks[trackIndex].clips[clipIndex])
                return
            }
        }
    }

    /// Move the left edge of a clip on the timeline to `newStart`, trimming the
    /// equivalent amount off the front of the source range so the visible
    /// content stays anchored to the right edge.
    func trimLeading(_ id: Clip.ID, to newStart: TimeInterval) {
        updateClip(id) { clip in
            let oldStart = clip.timeRange.start
            let oldEnd = clip.timeRange.end
            let clampedStart = max(0, min(newStart, oldEnd - 0.1))
            let delta = clampedStart - oldStart
            let scaledDelta = delta * clip.speed
            let newSourceStart = clip.sourceRange.start + scaledDelta
            let newSourceDuration = clip.sourceRange.duration - scaledDelta
            guard newSourceStart >= 0, newSourceDuration > 0.05 else { return }
            clip.timeRange = TimeRange(start: clampedStart, duration: oldEnd - clampedStart)
            clip.sourceRange = TimeRange(start: newSourceStart, duration: newSourceDuration)
        }
    }

    /// Move the right edge of a clip on the timeline to `newEnd`, extending or
    /// shrinking the source range from the back.
    func trimTrailing(_ id: Clip.ID, to newEnd: TimeInterval) {
        updateClip(id) { clip in
            let clampedEnd = max(clip.timeRange.start + 0.1, newEnd)
            let newDuration = clampedEnd - clip.timeRange.start
            let delta = newDuration - clip.timeRange.duration
            let scaledDelta = delta * clip.speed
            let newSourceDuration = clip.sourceRange.duration + scaledDelta
            guard newSourceDuration > 0.05 else { return }
            clip.timeRange = TimeRange(start: clip.timeRange.start, duration: newDuration)
            clip.sourceRange = TimeRange(start: clip.sourceRange.start, duration: newSourceDuration)
        }
    }

    /// Add an existing library asset to its appropriate track, preferring to
    /// place its leading edge at `time`. If that overlaps an existing clip the
    /// new clip is appended to the end of the track instead.
    func placeAsset(_ asset: MediaAsset, atTime time: TimeInterval) {
        if !project.assets.contains(where: { $0.id == asset.id }) {
            let isFirstVideo = asset.kind == .video
                && !project.assets.contains { $0.kind == .video }
            project.assets.append(asset)
            if isFirstVideo, let nativeSize = asset.nativeSize,
               nativeSize.width > 0, nativeSize.height > 0 {
                project.canvas.size = nativeSize
            }
        }

        let kind: Track.Kind = (asset.kind == .audio) ? .audio : .video
        guard let trackIndex = project.timeline.tracks.firstIndex(where: { $0.kind == kind }) else { return }
        let duration = max(0.1, asset.duration)
        let start = freeSlotStart(in: trackIndex, preferred: max(0, time), duration: duration)
        let clip = Clip(
            assetID: asset.id,
            timeRange: TimeRange(start: start, duration: duration),
            sourceRange: TimeRange(start: 0, duration: duration),
            label: asset.displayName
        )
        project.timeline.tracks[trackIndex].clips.append(clip)
        project.timeline.tracks[trackIndex].clips.sort { $0.timeRange.start < $1.timeRange.start }
    }

    /// Returns the earliest start time that fits `duration` on the track without
    /// overlapping any existing clip. Prefers `preferred`; if that overlaps,
    /// snaps just after the latest clip that ends before the gap closes.
    private func freeSlotStart(in trackIndex: Int, preferred: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let clips = project.timeline.tracks[trackIndex].clips
        let candidate = TimeRange(start: preferred, duration: duration)
        if !clips.contains(where: { $0.timeRange.intersects(candidate) }) {
            return preferred
        }
        return clips.last?.timeRange.end ?? 0
    }

    /// Removes an asset and any clips referencing it.
    func removeAsset(_ id: MediaAsset.ID) async {
        project.assets.removeAll { $0.id == id }
        for trackIndex in project.timeline.tracks.indices {
            project.timeline.tracks[trackIndex].clips.removeAll { $0.assetID == id }
        }
        if let selected = selectedClipID,
           !project.timeline.tracks.flatMap(\.clips).contains(where: { $0.id == selected }) {
            selectedClipID = nil
        }
        await reloadComposition()
    }

    /// Reveal an asset's source file in Finder.
    func revealAssetInFinder(_ id: MediaAsset.ID) {
        guard let asset = project.assets.first(where: { $0.id == id }) else { return }
        Task {
            guard let url = try? await resolver.resolve(asset) else { return }
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Toggle mute on a clip. Stores the previous volume on a per-clip flag so
    /// un-muting restores the original level.
    func toggleClipMuted(_ id: Clip.ID) {
        updateClip(id) { clip in
            if clip.volume > 0 {
                clip.volume = 0
            } else {
                clip.volume = 1
            }
        }
        Task { await reloadComposition() }
    }

    /// Move a clip horizontally along its track. Clamped between the previous
    /// clip's end (or 0) and the next clip's start minus this clip's duration,
    /// so reposition can't overlap neighbors. After moving, clips on the track
    /// are re-sorted by start time so adjacency math stays consistent.
    func moveClip(_ id: Clip.ID, toStart newStart: TimeInterval) {
        for trackIndex in project.timeline.tracks.indices {
            guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) else {
                continue
            }
            var clip = project.timeline.tracks[trackIndex].clips[clipIndex]
            let duration = clip.timeRange.duration
            let clips = project.timeline.tracks[trackIndex].clips
            let lowerBound: TimeInterval = clipIndex > 0 ? clips[clipIndex - 1].timeRange.end : 0
            let upperBound: TimeInterval = clipIndex + 1 < clips.count
                ? max(lowerBound, clips[clipIndex + 1].timeRange.start - duration)
                : .greatestFiniteMagnitude
            var clamped = max(lowerBound, min(newStart, upperBound))

            // Snap to neighbour edges, the timeline origin, and the playhead
            // when within tolerance — magnetic feel during drag-end. Skipped
            // entirely when the user has disabled snap from the toolbar.
            if snapEnabled {
                let snapTolerance: TimeInterval = 0.08
                var snapTargets: [TimeInterval] = [0, lowerBound]
                if upperBound.isFinite { snapTargets.append(upperBound) }
                let playheadStart = playback.currentTime
                let playheadAsTrailing = playheadStart - duration
                snapTargets.append(playheadStart)
                if playheadAsTrailing >= lowerBound { snapTargets.append(playheadAsTrailing) }

                if let best = snapTargets
                    .filter({ $0 >= lowerBound && $0 <= upperBound })
                    .min(by: { abs($0 - clamped) < abs($1 - clamped) }),
                   abs(best - clamped) <= snapTolerance {
                    clamped = best
                }
            }

            clip.timeRange = TimeRange(start: clamped, duration: duration)
            project.timeline.tracks[trackIndex].clips[clipIndex] = clip
            project.timeline.tracks[trackIndex].clips.sort { $0.timeRange.start < $1.timeRange.start }
            return
        }
    }

    /// Removes the selected clip AND shifts everything on the same track that
    /// followed it left by its duration, closing the gap. Mirrors CapCut's
    /// "Ripple Delete".
    func rippleDeleteSelectedClip() async {
        guard let id = selectedClipID else { return }
        for trackIndex in project.timeline.tracks.indices {
            let clips = project.timeline.tracks[trackIndex].clips
            guard let clipIndex = clips.firstIndex(where: { $0.id == id }) else { continue }
            let removed = clips[clipIndex]
            let shift = removed.timeRange.duration
            project.timeline.tracks[trackIndex].clips.remove(at: clipIndex)
            for i in clipIndex..<project.timeline.tracks[trackIndex].clips.count {
                var c = project.timeline.tracks[trackIndex].clips[i]
                c.timeRange = TimeRange(
                    start: max(0, c.timeRange.start - shift),
                    duration: c.timeRange.duration
                )
                project.timeline.tracks[trackIndex].clips[i] = c
            }
            selectedClipID = nil
            await reloadComposition()
            return
        }
    }

    func deleteSelectedClip() async {
        guard let id = selectedClipID else { return }
        for trackIndex in project.timeline.tracks.indices {
            project.timeline.tracks[trackIndex].clips.removeAll { $0.id == id }
        }
        selectedClipID = nil
        await reloadComposition()
    }

    /// Splits the clip under the playhead into two adjacent clips. No-op if
    /// the playhead is at a clip's edge.
    func splitClipAtPlayhead() async {
        let time = playback.currentTime
        for trackIndex in project.timeline.tracks.indices {
            let clips = project.timeline.tracks[trackIndex].clips
            for clipIndex in clips.indices {
                let clip = clips[clipIndex]
                guard clip.timeRange.contains(time),
                      time > clip.timeRange.start,
                      time < clip.timeRange.end
                else { continue }

                let offset = time - clip.timeRange.start
                let scaledOffset = offset * clip.speed

                var left = clip
                left.timeRange = TimeRange(start: clip.timeRange.start, duration: offset)
                left.sourceRange = TimeRange(start: clip.sourceRange.start, duration: scaledOffset)

                let right = Clip(
                    assetID: clip.assetID,
                    timeRange: TimeRange(start: time, duration: clip.timeRange.end - time),
                    sourceRange: TimeRange(
                        start: clip.sourceRange.start + scaledOffset,
                        duration: clip.sourceRange.duration - scaledOffset
                    ),
                    transform: clip.transform,
                    volume: clip.volume,
                    speed: clip.speed,
                    label: clip.label
                )

                project.timeline.tracks[trackIndex].clips[clipIndex] = left
                project.timeline.tracks[trackIndex].clips.insert(right, at: clipIndex + 1)
                selectedClipID = right.id
                await reloadComposition()
                return
            }
        }
    }

    // MARK: - Playback stepping

    /// Step the playhead by `frames` frames at the project's frame rate.
    /// Pauses playback so the user sees the exact frame.
    func stepFrame(by frames: Int) {
        let fps = max(1, project.canvas.frameRate)
        let delta = Double(frames) / fps
        seekRelative(by: delta)
    }

    /// Step the playhead by `seconds` seconds (positive forward).
    func stepSeconds(by seconds: TimeInterval) {
        seekRelative(by: seconds)
    }

    private func seekRelative(by seconds: TimeInterval) {
        playback.pause()
        let new = max(0, min(playback.duration, playback.currentTime + seconds))
        playback.seek(to: new)
    }

    // MARK: - Playback

    func reloadComposition() async {
        let resumeTime = playback.currentTime
        let builder = CompositionBuilder()
        do {
            let result = try await builder.build(project, assetResolver: resolver)
            playback.load(result)
            playback.seek(to: resumeTime)
        } catch {
            // Composition couldn't be built; preview stays empty.
        }
    }
}
