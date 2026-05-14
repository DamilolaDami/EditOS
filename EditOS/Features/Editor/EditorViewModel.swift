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
        project.assets.append(asset)

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
