import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class EditorViewModel {
    var project: Project
    /// Multi-selection backing store. Single-selection callers go through
    /// `selectedClipID` which mirrors the first member.
    var selectedClipIDs: Set<Clip.ID> = []
    var selectedTool: ToolCategory = .media
    var isLibraryVisible: Bool = true
    var isInspectorVisible: Bool = true
    var zoom: Double = 1.0
    /// Magnet-on/off — when off, dragging clips skips edge-snap completely.
    var snapEnabled: Bool = true
    /// Path of the most recent successful export; powers the top bar Share button.
    var lastExportedURL: URL?

    // In-memory clipboard. Stored with track kinds so a paste can route to
    // the right track type (video / audio / caption / sticker).
    struct ClipboardEntry: Sendable {
        let kind: Track.Kind
        let clip: Clip
    }
    private var clipboard: [ClipboardEntry] = []
    var hasClipboard: Bool { !clipboard.isEmpty }

    let playback: PlaybackEngine
    private let resolver: AssetResolver

    // MARK: - Undo / Redo
    //
    // Each high-level mutation calls `recordSnapshot()` before mutating, which
    // pushes a Codable snapshot of `project` onto `undoStack`. Calls within
    // `snapshotCoalesceWindow` of the previous snapshot are skipped, so a
    // continuous drag (trim / slider) collapses into a single undo step
    // instead of dozens.
    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    private var lastSnapshotAt: Date = .distantPast
    private let snapshotCoalesceWindow: TimeInterval = 0.45
    private let maxUndoDepth: Int = 64
    private let snapshotEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let snapshotDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(project: Project, resolver: AssetResolver) {
        self.project = project
        self.playback = PlaybackEngine()
        self.resolver = resolver
    }

    // MARK: - Selection

    /// Single-selection convenience. Reading returns the primary (first)
    /// member of `selectedClipIDs`. Writing replaces the selection set.
    var selectedClipID: Clip.ID? {
        get { selectedClipIDs.first }
        set {
            if let newValue {
                selectedClipIDs = [newValue]
            } else {
                selectedClipIDs.removeAll()
            }
        }
    }

    /// Replace selection with the given clip (or clear if nil).
    func selectClip(_ id: Clip.ID?) {
        if let id {
            selectedClipIDs = [id]
        } else {
            selectedClipIDs.removeAll()
        }
    }

    /// Select every clip across every track. Used by ⌘A.
    func selectAllClips() {
        selectedClipIDs = Set(project.timeline.tracks.flatMap(\.clips).map(\.id))
    }

    /// ⌘-click behaviour: add to / remove from the selection set.
    func toggleClipSelection(_ id: Clip.ID) {
        if selectedClipIDs.contains(id) {
            selectedClipIDs.remove(id)
        } else {
            selectedClipIDs.insert(id)
        }
    }

    func isClipSelected(_ id: Clip.ID) -> Bool {
        selectedClipIDs.contains(id)
    }

    // MARK: - Snapshots

    /// Pushes a copy of `project` onto the undo stack. Calls in quick
    /// succession (e.g. trim drag onChanged ticks) are dropped so one drag
    /// becomes one undo step. Caller pattern: invoke before mutating.
    func recordSnapshot() {
        let now = Date()
        if now.timeIntervalSince(lastSnapshotAt) < snapshotCoalesceWindow {
            return
        }
        guard let data = try? snapshotEncoder.encode(project) else { return }
        undoStack.append(data)
        if undoStack.count > maxUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
        lastSnapshotAt = now
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        if let currentData = try? snapshotEncoder.encode(project) {
            redoStack.append(currentData)
        }
        applySnapshot(snapshot)
        // Don't coalesce the very next mutation into this snapshot.
        lastSnapshotAt = .distantPast
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        if let currentData = try? snapshotEncoder.encode(project) {
            undoStack.append(currentData)
        }
        applySnapshot(snapshot)
        lastSnapshotAt = .distantPast
    }

    private func applySnapshot(_ data: Data) {
        guard let restored = try? snapshotDecoder.decode(Project.self, from: data) else { return }
        project = restored
        let liveIDs = Set(project.timeline.tracks.flatMap(\.clips).map(\.id))
        selectedClipIDs.formIntersection(liveIDs)
        Task { await reloadComposition() }
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
        recordSnapshot()
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
        recordSnapshot()
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

    /// Adds a text overlay clip at `time`, automatically stacking on a new
    /// caption track if every existing one overlaps at that time. Default
    /// duration is 3 seconds.
    func placeText(_ text: String, atTime time: TimeInterval, duration: TimeInterval = 3) {
        recordSnapshot()
        let placement = overlayPlacement(forKind: .caption, preferredStart: max(0, time), duration: duration)
        let clip = Clip(
            assetID: UUID(),  // placeholder — overlay clips don't reference a real asset
            timeRange: TimeRange(start: placement.start, duration: duration),
            sourceRange: TimeRange(start: 0, duration: duration),
            label: text,
            text: text,
            foregroundColor: .white,
            overlaySize: 64
        )
        project.timeline.tracks[placement.trackIndex].clips.append(clip)
        project.timeline.tracks[placement.trackIndex].clips.sort { $0.timeRange.start < $1.timeRange.start }
        selectedClipID = clip.id
    }

    /// Adds a sticker overlay clip — `symbol` is an SF Symbol name (e.g. "heart.fill").
    /// Stacks on a new sticker lane when the existing ones are busy at `time`.
    func placeSticker(_ symbol: String, atTime time: TimeInterval, duration: TimeInterval = 3) {
        recordSnapshot()
        let placement = overlayPlacement(forKind: .sticker, preferredStart: max(0, time), duration: duration)
        let clip = Clip(
            assetID: UUID(),
            timeRange: TimeRange(start: placement.start, duration: duration),
            sourceRange: TimeRange(start: 0, duration: duration),
            label: symbol,
            stickerSymbol: symbol,
            foregroundColor: .white,
            overlaySize: 96
        )
        project.timeline.tracks[placement.trackIndex].clips.append(clip)
        project.timeline.tracks[placement.trackIndex].clips.sort { $0.timeRange.start < $1.timeRange.start }
        selectedClipID = clip.id
    }

    /// Adds a sticker overlay clip that references a downloaded image file
    /// (e.g. a GIPHY GIF cached in Application Support).
    func placeStickerImage(localPath: String, displayName: String, atTime time: TimeInterval, duration: TimeInterval = 3) {
        recordSnapshot()
        let placement = overlayPlacement(forKind: .sticker, preferredStart: max(0, time), duration: duration)
        let trimmedName = displayName.isEmpty ? "Sticker" : displayName
        let clip = Clip(
            assetID: UUID(),
            timeRange: TimeRange(start: placement.start, duration: duration),
            sourceRange: TimeRange(start: 0, duration: duration),
            label: trimmedName,
            stickerImagePath: localPath,
            foregroundColor: .white,
            overlaySize: 200
        )
        project.timeline.tracks[placement.trackIndex].clips.append(clip)
        project.timeline.tracks[placement.trackIndex].clips.sort { $0.timeRange.start < $1.timeRange.start }
        selectedClipID = clip.id
    }

    /// Picks an existing track of `kind` where the candidate clip fits at
    /// `preferredStart` without overlapping anything, or appends a new track
    /// of that kind when every existing lane is busy. Lets the user stack
    /// multiple overlays at the same timestamp the way CapCut does.
    private func overlayPlacement(
        forKind kind: Track.Kind,
        preferredStart: TimeInterval,
        duration: TimeInterval
    ) -> (trackIndex: Int, start: TimeInterval) {
        let candidate = TimeRange(start: preferredStart, duration: duration)
        for (index, track) in project.timeline.tracks.enumerated() where track.kind == kind {
            let overlaps = track.clips.contains { $0.timeRange.intersects(candidate) }
            if !overlaps {
                return (index, preferredStart)
            }
        }
        project.timeline.tracks.append(Track(kind: kind))
        return (project.timeline.tracks.count - 1, preferredStart)
    }

    // MARK: - Tracks

    /// Appends a new track of the given kind. Sticker / caption / overlay
    /// tracks let the user layer multiple of the same type.
    func addTrack(kind: Track.Kind) {
        recordSnapshot()
        project.timeline.tracks.append(Track(kind: kind))
    }

    /// Remove a track and any composition rebuild that follows. The view
    /// guards against removing the last video track from the UI side.
    func deleteTrack(_ id: Track.ID) {
        recordSnapshot()
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
        recordSnapshot()
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
        // No explicit recordSnapshot — updateClip already coalesces.
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
        recordSnapshot()
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
        recordSnapshot()
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

    /// Drops a filter clip on a `.filter` track at `time`. Stacks onto a new
    /// filter lane when the existing ones are busy — matches CapCut: filters
    /// live on their own track and only affect video beneath them while
    /// active.
    func placeFilter(_ presetID: String, atTime time: TimeInterval, duration: TimeInterval = 3) {
        recordSnapshot()
        let placement = overlayPlacement(forKind: .filter, preferredStart: max(0, time), duration: duration)
        let displayName = FilterCatalog.find(id: presetID)?.displayName ?? "Filter"
        let clip = Clip(
            assetID: UUID(),
            timeRange: TimeRange(start: placement.start, duration: duration),
            sourceRange: TimeRange(start: 0, duration: duration),
            label: displayName,
            filterPreset: presetID,
            filterIntensity: 1.0
        )
        project.timeline.tracks[placement.trackIndex].clips.append(clip)
        project.timeline.tracks[placement.trackIndex].clips.sort { $0.timeRange.start < $1.timeRange.start }
        selectedClipIDs = [clip.id]
        Task { await reloadComposition() }
    }

    /// Apply (or clear) a filter on every clip in the current selection. Use
    /// `presetID = nil` to remove the filter. Triggers a composition reload
    /// so the player reflects the change immediately.
    func applyFilter(_ presetID: String?, intensity: Double = 1.0) {
        guard !selectedClipIDs.isEmpty else { return }
        recordSnapshot()
        for trackIndex in project.timeline.tracks.indices {
            for clipIndex in project.timeline.tracks[trackIndex].clips.indices
            where selectedClipIDs.contains(project.timeline.tracks[trackIndex].clips[clipIndex].id) {
                project.timeline.tracks[trackIndex].clips[clipIndex].filterPreset = presetID
                project.timeline.tracks[trackIndex].clips[clipIndex].filterIntensity = presetID == nil ? nil : intensity
            }
        }
        Task { await reloadComposition() }
    }

    /// Live-edit the filter strength for the selected clip(s) without
    /// pushing a snapshot each tick — pair with the inspector slider.
    func setFilterIntensity(_ value: Double) {
        for trackIndex in project.timeline.tracks.indices {
            for clipIndex in project.timeline.tracks[trackIndex].clips.indices
            where selectedClipIDs.contains(project.timeline.tracks[trackIndex].clips[clipIndex].id) {
                guard project.timeline.tracks[trackIndex].clips[clipIndex].filterPreset != nil else { continue }
                project.timeline.tracks[trackIndex].clips[clipIndex].filterIntensity = max(0, min(1, value))
            }
        }
    }

    /// Toggle mute on a clip. Stores the previous volume on a per-clip flag so
    /// un-muting restores the original level.
    func toggleClipMuted(_ id: Clip.ID) {
        recordSnapshot()
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
        recordSnapshot()
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

            // Snap to neighbour edges, the timeline origin, the playhead,
            // *and* the edges of every clip in every other track — so the
            // dragged clip can align vertically with content on a different
            // lane the same way it aligns horizontally with its own
            // neighbours. Skipped entirely when snap is toggled off.
            if snapEnabled {
                let snapTolerance: TimeInterval = 0.08

                // Interesting times: timeline 0, playhead, every other
                // clip's start/end across all tracks (including same-track
                // neighbours, which are already covered by lowerBound /
                // upperBound but harmless to include here).
                var interestingPoints: [TimeInterval] = [0, lowerBound]
                if upperBound.isFinite { interestingPoints.append(upperBound) }
                interestingPoints.append(playback.currentTime)
                for laneTrack in project.timeline.tracks {
                    for other in laneTrack.clips where other.id != id {
                        interestingPoints.append(other.timeRange.start)
                        interestingPoints.append(other.timeRange.end)
                    }
                }

                // Each interesting point yields two candidate placements:
                // align our leading edge to it, or align our trailing edge
                // to it (which means new start = point − duration).
                var snapTargets: [TimeInterval] = []
                for point in interestingPoints {
                    snapTargets.append(point)
                    snapTargets.append(point - duration)
                }

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
        recordSnapshot()
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

    /// Delete every clip in the current selection set (single or multi).
    func deleteSelectedClip() async {
        await deleteSelectedClips()
    }

    /// Splits the clip under the playhead into two adjacent clips. No-op if
    /// the playhead is at a clip's edge.
    func splitClipAtPlayhead() async {
        recordSnapshot()
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

    /// Build a fresh composition for export. Caller is responsible for keeping
    /// the resolver alive while the export session runs (we already do — the
    /// resolver is stored on this view model for the editor's lifetime).
    func buildComposition() async throws -> CompositionResult {
        let builder = CompositionBuilder()
        return try await builder.build(project, assetResolver: resolver)
    }

    // MARK: - Clipboard

    /// Snapshot the selected clips to an in-memory clipboard, keyed by their
    /// host track kind so paste can route back to the correct lane.
    func copySelection() {
        var entries: [ClipboardEntry] = []
        for track in project.timeline.tracks {
            for clip in track.clips where selectedClipIDs.contains(clip.id) {
                entries.append(ClipboardEntry(kind: track.kind, clip: clip))
            }
        }
        guard !entries.isEmpty else { return }
        clipboard = entries
    }

    /// Paste clipboard contents at the playhead. Preserves relative timing
    /// between multiple copied clips and stacks onto new lanes when busy.
    func paste() async {
        guard !clipboard.isEmpty else { return }
        recordSnapshot()
        let base = playback.currentTime
        let earliest = clipboard.map { $0.clip.timeRange.start }.min() ?? 0
        var newIDs: Set<Clip.ID> = []
        for entry in clipboard {
            let original = entry.clip
            let relativeStart = original.timeRange.start - earliest
            let preferredStart = max(0, base + relativeStart)
            let placement = overlayPlacement(
                forKind: entry.kind,
                preferredStart: preferredStart,
                duration: original.timeRange.duration
            )
            let copy = original.duplicateForCopy(
                placedAt: placement.start
            )
            project.timeline.tracks[placement.trackIndex].clips.append(copy)
            project.timeline.tracks[placement.trackIndex].clips
                .sort { $0.timeRange.start < $1.timeRange.start }
            newIDs.insert(copy.id)
        }
        selectedClipIDs = newIDs
        await reloadComposition()
    }

    /// Copy + paste in one shot — useful as a ⌘D shortcut.
    func duplicateSelection() async {
        copySelection()
        await paste()
    }

    func cutSelection() async {
        copySelection()
        await deleteSelectedClips()
    }

    /// Multi-clip delete that respects the full selection set.
    func deleteSelectedClips() async {
        guard !selectedClipIDs.isEmpty else { return }
        recordSnapshot()
        let ids = selectedClipIDs
        for trackIndex in project.timeline.tracks.indices {
            project.timeline.tracks[trackIndex].clips.removeAll { ids.contains($0.id) }
        }
        selectedClipIDs.removeAll()
        await reloadComposition()
    }

    // MARK: - Project metadata

    /// Rename the project; whitespace-only input is ignored.
    func renameProject(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        recordSnapshot()
        project.name = trimmed
    }

    /// Update the project canvas to a new size, preserving frame rate.
    func setCanvasSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != project.canvas.size else { return }
        recordSnapshot()
        project.canvas.size = size
    }

    // MARK: - Tracks (reorder + lock helpers)

    /// Move a track up or down in the stack by one position.
    func moveTrack(_ id: Track.ID, byOffset offset: Int) {
        guard let index = project.timeline.tracks.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard target >= 0, target < project.timeline.tracks.count, target != index else { return }
        recordSnapshot()
        let track = project.timeline.tracks.remove(at: index)
        project.timeline.tracks.insert(track, at: target)
    }

    /// True when the clip's host track is locked (clip cannot be moved or trimmed).
    func isClipLocked(_ id: Clip.ID) -> Bool {
        for track in project.timeline.tracks {
            if track.clips.contains(where: { $0.id == id }) {
                return track.isLocked
            }
        }
        return false
    }
}

private extension Clip {
    /// Returns a copy with a fresh UUID and the time range moved to `start`.
    /// Used by the clipboard and ⌘D duplicate path.
    func duplicateForCopy(placedAt start: TimeInterval) -> Clip {
        Clip(
            id: UUID(),
            assetID: assetID,
            timeRange: TimeRange(start: start, duration: timeRange.duration),
            sourceRange: sourceRange,
            transform: transform,
            volume: volume,
            speed: speed,
            label: label,
            text: text,
            stickerSymbol: stickerSymbol,
            stickerImagePath: stickerImagePath,
            foregroundColor: foregroundColor,
            overlaySize: overlaySize
        )
    }
}
