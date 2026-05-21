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
    /// Active workspace preset. Drives the top-bar picker's chip and
    /// the menu-item checkmarks; updated by `applyWorkspace`. Manual
    /// panel toggles don't change this — the picker just records "the
    /// last preset the user explicitly chose."
    var currentWorkspace: Workspace = .editing
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
    let voiceoverRecorder: VoiceoverRecorder = VoiceoverRecorder()
    let captionTranscriber: CaptionTranscriber = CaptionTranscriber()
    /// Set while an auto-caption pass is running for a given clip — lets the
    /// inspector show a progress hint and disable the button to prevent
    /// re-entry on the same clip.
    var transcribingClipID: Clip.ID? = nil
    /// Last user-visible error from a caption pass. Cleared automatically
    /// after the next successful run.
    var lastCaptionError: String? = nil
    /// Set while a beat-detection pass is running on a given clip — the
    /// inspector reads this to swap the button label for a spinner +
    /// disable re-entry on the same clip.
    var detectingBeatsClipID: Clip.ID? = nil
    /// Last user-visible error from a beat-detection pass. Cleared on
    /// the next successful run.
    var lastBeatDetectionError: String? = nil
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

    // MARK: - Auto-save

    /// Lifecycle of the project's autosave state. Drives the editor-header
    /// pill (`Saving…`, `Saved 3s ago`, `Unsaved changes`) and lets test
    /// fixtures observe whether a flush is still pending without sleeping
    /// for the debounce window.
    enum SaveStatus: Equatable, Sendable {
        case idle
        case pendingChanges
        case saving
        case saved(Date)
        case error(String)
    }

    /// Latest save lifecycle state. Read by the top-bar indicator. Tests
    /// can poll this to wait for a flush without sleeping.
    private(set) var saveStatus: SaveStatus = .idle

    /// Debounce window — bursts of edits inside this window collapse into
    /// a single disk write. Seeded from `PreferencesStore.autoSaveDebounce`
    /// by `EditorView`; settable so the General settings tab can change
    /// the window live without an editor reopen.
    var saveDebounce: TimeInterval = 0.8

    private var pendingSaveTask: Task<Void, Never>?
    /// Latest persist block. Each `scheduleSave` call replaces it so the
    /// closure that finally runs always uses the freshest `Project`.
    private var pendingPersist: (@MainActor () -> Void)?

    /// Coalesce a save. Each call cancels any pending flush, marks the
    /// status as `.pendingChanges`, and schedules `persist` to run on the
    /// main actor once the debounce settles. Bursts of mutations during a
    /// drag collapse into a single disk write at the trailing edge.
    func scheduleSave(persist: @escaping @MainActor () -> Void) {
        pendingSaveTask?.cancel()
        pendingPersist = persist
        saveStatus = .pendingChanges
        pendingSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.saveDebounce))
            guard !Task.isCancelled else { return }
            self.performPendingSave()
        }
    }

    /// Force the pending save to run immediately. Called on window close
    /// so the user doesn't lose the trailing edits inside the debounce
    /// window.
    func flushPendingSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        performPendingSave()
    }

    private func performPendingSave() {
        guard let persist = pendingPersist else { return }
        pendingPersist = nil
        saveStatus = .saving
        persist()
        saveStatus = .saved(.now)
    }

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

    /// Apply a workspace preset — flips panel visibility flags and
    /// optionally swaps the library tab. Always resets to the preset's
    /// defaults, so re-selecting the current workspace is the gesture
    /// for "undo my manual tweaks and snap back to the layout."
    func applyWorkspace(_ workspace: Workspace) {
        currentWorkspace = workspace
        let layout = workspace.layout
        isLibraryVisible = layout.libraryVisible
        isInspectorVisible = layout.inspectorVisible
        if let tab = layout.preferredLibraryTab {
            selectedTool = tab
        }
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

    /// Materialise a title template at `time`. Each layer in the template
    /// becomes its own caption clip with the layer's animation,
    /// position, colour, and font size; layers stagger by their
    /// `startDelay` and all share the same end-time so they fade
    /// together. Background fills are deferred to a future PR — V1
    /// titles sit over whatever's underneath on the video track (or
    /// the project canvas's background colour if no video is playing).
    /// Returns the placed clip IDs so the caller can drive a selection
    /// or animation hint.
    @discardableResult
    func placeTitleTemplate(_ template: TitleTemplate, atTime time: TimeInterval) -> [Clip.ID] {
        recordSnapshot()
        var newIDs: [Clip.ID] = []
        for layer in template.layers {
            let layerStart = max(0, time + layer.startDelay)
            let layerDuration = max(0.5, template.duration - layer.startDelay)
            let placement = overlayPlacement(
                forKind: .caption,
                preferredStart: layerStart,
                duration: layerDuration
            )
            var clip = Clip(
                assetID: UUID(),  // placeholder — overlay clips don't reference a real asset
                timeRange: TimeRange(start: placement.start, duration: layerDuration),
                sourceRange: TimeRange(start: 0, duration: layerDuration),
                label: layer.text,
                text: layer.text,
                foregroundColor: layer.color,
                overlaySize: layer.size
            )
            // Apply the layer's position offset + animation. ClipTransform
            // stores its offset as `translation`; we map directly.
            clip.transform.translation = layer.offset
            clip.textAnimation = layer.animation
            project.timeline.tracks[placement.trackIndex].clips.append(clip)
            project.timeline.tracks[placement.trackIndex].clips
                .sort { $0.timeRange.start < $1.timeRange.start }
            newIDs.append(clip.id)
        }
        // Select the first layer so the inspector opens onto the title
        // and the user can tweak text / colour without hunting.
        if let firstID = newIDs.first {
            selectedClipID = firstID
        }
        Task { await reloadComposition() }
        return newIDs
    }

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

    /// Drop a sequence of rough-cut segments onto a fresh video track
    /// above the current ones. The segments reference the same asset
    /// the user analysed and are laid out sequentially starting at
    /// `t=0` — original clip stays untouched on its existing track.
    /// Returns the new track's ID so callers can highlight or select
    /// it after creation.
    @discardableResult
    func applyRoughCut(
        segments: [RoughCutEngine.Segment],
        sourceAsset: MediaAsset,
        trackName: String = "Rough cut"
    ) -> Track.ID? {
        guard !segments.isEmpty else { return nil }
        recordSnapshot()

        var cursor: TimeInterval = 0
        let clips: [Clip] = segments.map { seg in
            let clip = Clip(
                assetID: sourceAsset.id,
                timeRange: TimeRange(start: cursor, duration: seg.duration),
                sourceRange: TimeRange(start: seg.startTime, duration: seg.duration),
                label: trackName
            )
            cursor += seg.duration
            return clip
        }

        // Prepend so the rough-cut track sits above the original in
        // the timeline UI.
        let newTrack = Track(kind: .video, clips: clips)
        if let firstVideoIndex = project.timeline.tracks.firstIndex(where: { $0.kind == .video }) {
            project.timeline.tracks.insert(newTrack, at: firstVideoIndex)
        } else {
            project.timeline.tracks.append(newTrack)
        }
        Task { await reloadComposition() }
        return newTrack.id
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

    // MARK: - Voiceover

    /// Begin recording the user's voice. Throws if AVAudioRecorder can't
    /// start (typically a missing microphone permission).
    func startVoiceoverRecording() throws {
        _ = try voiceoverRecorder.start()
        // Pause playback so the recording mic isn't picking up the speakers.
        playback.pause()
    }

    /// Stop the active recording and drop the resulting AAC file on the
    /// audio track at the playhead as a voiceover-flagged clip. Existing
    /// music gets audio-ducked automatically (see CompositionBuilder).
    func stopVoiceoverRecording() async {
        guard let url = voiceoverRecorder.stop() else { return }
        let importer = MediaImporter()
        do {
            let asset = try await importer.makeAsset(from: url)
            recordSnapshot()
            placeAsset(asset, atTime: playback.currentTime)
            // Flag the most recent audio-track clip referencing this asset
            // as a voiceover so audio ducking knows to dim other music
            // tracks during its time range.
            if let trackIndex = project.timeline.tracks.firstIndex(where: { $0.kind == .audio }) {
                if let clipIndex = project.timeline.tracks[trackIndex].clips
                    .lastIndex(where: { $0.assetID == asset.id }) {
                    project.timeline.tracks[trackIndex].clips[clipIndex].isVoiceover = true
                }
            }
            await reloadComposition()
        } catch {
            // Recording is on disk; user can re-import via Media tab if
            // needed.
        }
    }

    func cancelVoiceoverRecording() {
        voiceoverRecorder.cancel()
    }

    // MARK: - Auto-captions

    /// Run SFSpeechRecognizer over `clip`'s underlying audio (or video) asset
    /// and drop one caption-track text overlay per recognised phrase. The
    /// clip's `timeRange.start` and `sourceRange.start` are used to map the
    /// recogniser's timestamps back into project time, so partially-trimmed
    /// clips still line up.
    func generateCaptions(for clipID: Clip.ID) async {
        guard transcribingClipID == nil else { return }
        guard let location = locateClip(clipID) else { return }
        let clip = project.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else { return }
        guard asset.kind == .audio || asset.kind == .video else { return }

        transcribingClipID = clipID
        defer { transcribingClipID = nil }
        do {
            let url = try await resolver.resolve(asset)
            let segments = try await captionTranscriber.transcribe(audioURL: url)
            lastCaptionError = nil
            recordSnapshot()
            for segment in segments {
                // Skip segments that fall outside the clip's visible range
                // (sourceRange) — e.g. a long file trimmed to its middle.
                let inClipStart = segment.start - clip.sourceRange.start
                let inClipEnd = inClipStart + segment.duration
                guard inClipEnd > 0, inClipStart < clip.timeRange.duration else { continue }
                let clampedStart = max(0, inClipStart)
                let clampedEnd = min(clip.timeRange.duration, inClipEnd)
                let projectStart = clip.timeRange.start + clampedStart
                let projectDuration = max(0.4, clampedEnd - clampedStart)
                placeText(segment.text, atTime: projectStart, duration: projectDuration)
            }
        } catch let error as CaptionTranscriber.TranscribeError {
            lastCaptionError = error.errorDescription
        } catch {
            lastCaptionError = error.localizedDescription
        }
    }

    /// Run `BeatDetector` over the clip's source audio and stash the
    /// detected beats on the timeline. Beats outside the clip's
    /// `sourceRange` are filtered out — the user trimmed that audio off,
    /// so it shouldn't show up as a snap target — and the surviving
    /// beats are mapped from source-local time into project time.
    func detectBeats(for clipID: Clip.ID) async {
        guard detectingBeatsClipID == nil else { return }
        guard let location = locateClip(clipID) else { return }
        let clip = project.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else { return }
        guard asset.kind == .audio || asset.kind == .video else { return }

        detectingBeatsClipID = clipID
        defer { detectingBeatsClipID = nil }
        do {
            let url = try await resolver.resolve(asset)
            let detector = BeatDetector()
            let result = try await detector.analyze(url: url)
            // Source-local → project time mapping. Same shape as the
            // caption pipeline: anything outside the clip's trimmed
            // window is dropped, and `clip.timeRange.start` offsets the
            // rest into the timeline's coordinate space.
            let sourceStart = clip.sourceRange.start
            let sourceEnd = clip.sourceRange.end
            let projectOffset = clip.timeRange.start - sourceStart
            let beatsInProject = result.beats
                .filter { $0 >= sourceStart && $0 <= sourceEnd }
                .map { $0 + projectOffset }
            recordSnapshot()
            project.timeline.detectedBeats = beatsInProject.sorted()
            project.timeline.detectedTempo = result.tempo
            lastBeatDetectionError = nil
        } catch {
            lastBeatDetectionError = error.localizedDescription
        }
    }

    /// Wipe any previously-detected beats from the timeline. Undoable.
    func clearDetectedBeats() {
        guard !project.timeline.detectedBeats.isEmpty || project.timeline.detectedTempo != nil else { return }
        recordSnapshot()
        project.timeline.detectedBeats = []
        project.timeline.detectedTempo = nil
    }

    private struct ClipLocation {
        let trackIndex: Int
        let clipIndex: Int
    }

    private func locateClip(_ id: Clip.ID) -> ClipLocation? {
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            if let clipIndex = track.clips.firstIndex(where: { $0.id == id }) {
                return ClipLocation(trackIndex: trackIndex, clipIndex: clipIndex)
            }
        }
        return nil
    }

    // MARK: - Volume keyframes

    /// Replace a clip's gain envelope. Pass `nil` to clear (clip reverts
    /// to its scalar `volume`). Snapshots for undo + reloads composition
    /// so the player picks up the new ramps.
    func setVolumeKeyframes(_ keyframes: [VolumeKeyframe]?, on id: Clip.ID) {
        recordSnapshot()
        for trackIndex in project.timeline.tracks.indices {
            if let clipIndex = project.timeline.tracks[trackIndex].clips
                .firstIndex(where: { $0.id == id }) {
                project.timeline.tracks[trackIndex].clips[clipIndex].volumeKeyframes
                    = (keyframes?.isEmpty == false) ? keyframes : nil
                break
            }
        }
        Task { await reloadComposition() }
    }

    /// Drop a single keyframe at `localTime` (source-clip-local seconds).
    /// Used by the inspector's tap-to-add-keyframe gesture. `gain`
    /// defaults to whatever the envelope already interpolates to at
    /// that time, so adding a keyframe doesn't visibly change the
    /// envelope until the user drags it.
    func addVolumeKeyframe(_ time: TimeInterval, gain: Double, on id: Clip.ID) {
        recordSnapshot()
        for trackIndex in project.timeline.tracks.indices {
            if let clipIndex = project.timeline.tracks[trackIndex].clips
                .firstIndex(where: { $0.id == id }) {
                var existing = project.timeline.tracks[trackIndex].clips[clipIndex].volumeKeyframes ?? []
                existing.append(VolumeKeyframe(time: time, gain: gain))
                project.timeline.tracks[trackIndex].clips[clipIndex].volumeKeyframes
                    = existing.sorted { $0.time < $1.time }
                break
            }
        }
        Task { await reloadComposition() }
    }

    /// Mutate an existing keyframe. Used by the drag-handle gestures on
    /// the gain-envelope strip.
    func updateVolumeKeyframe(
        _ keyframeID: VolumeKeyframe.ID,
        on id: Clip.ID,
        time: TimeInterval? = nil,
        gain: Double? = nil
    ) {
        recordSnapshot()
        for trackIndex in project.timeline.tracks.indices {
            if let clipIndex = project.timeline.tracks[trackIndex].clips
                .firstIndex(where: { $0.id == id }) {
                guard var keyframes = project.timeline.tracks[trackIndex].clips[clipIndex].volumeKeyframes,
                      let kfIndex = keyframes.firstIndex(where: { $0.id == keyframeID })
                else { return }
                let original = keyframes[kfIndex]
                keyframes[kfIndex] = VolumeKeyframe(
                    id: original.id,
                    time: time ?? original.time,
                    gain: gain ?? original.gain
                )
                project.timeline.tracks[trackIndex].clips[clipIndex].volumeKeyframes
                    = keyframes.sorted { $0.time < $1.time }
                break
            }
        }
        Task { await reloadComposition() }
    }

    func removeVolumeKeyframe(_ keyframeID: VolumeKeyframe.ID, on id: Clip.ID) {
        recordSnapshot()
        for trackIndex in project.timeline.tracks.indices {
            if let clipIndex = project.timeline.tracks[trackIndex].clips
                .firstIndex(where: { $0.id == id }) {
                project.timeline.tracks[trackIndex].clips[clipIndex].volumeKeyframes?
                    .removeAll { $0.id == keyframeID }
                if project.timeline.tracks[trackIndex].clips[clipIndex].volumeKeyframes?.isEmpty == true {
                    project.timeline.tracks[trackIndex].clips[clipIndex].volumeKeyframes = nil
                }
                break
            }
        }
        Task { await reloadComposition() }
    }

    // MARK: - Transitions

    /// Set the outgoing transition for a clip. Pass `nil` to clear it
    /// (hard cut). The composition pipeline picks this up on its next
    /// rebuild — transitions overlap with the following clip and bake
    /// the blend into the rendered output.
    func setTransition(_ transition: Transition?, on id: Clip.ID) {
        recordSnapshot()
        for trackIndex in project.timeline.tracks.indices {
            if let clipIndex = project.timeline.tracks[trackIndex].clips
                .firstIndex(where: { $0.id == id }) {
                project.timeline.tracks[trackIndex].clips[clipIndex].transitionToNext = transition
                break
            }
        }
        Task { await reloadComposition() }
    }

    /// Returns the clip that immediately follows `id` on the same track,
    /// if any. Used by the inspector to decide whether the Transition
    /// section is meaningful (transitions only render between adjacent
    /// clips on the same track).
    func nextClip(on track: Track.ID, after id: Clip.ID) -> Clip? {
        guard let track = project.timeline.tracks.first(where: { $0.id == track }) else { return nil }
        let sorted = track.clips.sorted { $0.timeRange.start < $1.timeRange.start }
        guard let idx = sorted.firstIndex(where: { $0.id == id }) else { return nil }
        let next = idx + 1
        return next < sorted.count ? sorted[next] : nil
    }

    /// Convenience that finds the track and following clip for the given
    /// clip ID. Returns nil if the clip is the last on its track.
    func clipFollowing(_ id: Clip.ID) -> Clip? {
        for track in project.timeline.tracks {
            let sorted = track.clips.sorted { $0.timeRange.start < $1.timeRange.start }
            if let idx = sorted.firstIndex(where: { $0.id == id }) {
                let next = idx + 1
                return next < sorted.count ? sorted[next] : nil
            }
        }
        return nil
    }

    // MARK: - Markers

    /// Drop a marker at the current playhead. Auto-numbers the label
    /// ("Marker 1", "Marker 2", …) so the strip is immediately readable;
    /// the user can rename inline. Returns the new marker's id so callers
    /// can drive a rename UI right after creating it.
    @discardableResult
    func addMarkerAtPlayhead() -> Marker.ID {
        recordSnapshot()
        let nextNumber = project.timeline.markers.count + 1
        let marker = Marker(
            time: max(0, playback.currentTime),
            label: "Marker \(nextNumber)",
            color: .accent
        )
        project.timeline.markers.append(marker)
        project.timeline.markers.sort { $0.time < $1.time }
        return marker.id
    }

    /// Move a marker to a new time on the timeline. Clamps to ≥0 and
    /// re-sorts the markers array so subsequent lookups stay ordered.
    func moveMarker(_ id: Marker.ID, to time: TimeInterval) {
        recordSnapshot()
        guard let idx = project.timeline.markers.firstIndex(where: { $0.id == id }) else { return }
        project.timeline.markers[idx].time = max(0, time)
        project.timeline.markers.sort { $0.time < $1.time }
    }

    func renameMarker(_ id: Marker.ID, to label: String) {
        recordSnapshot()
        guard let idx = project.timeline.markers.firstIndex(where: { $0.id == id }) else { return }
        project.timeline.markers[idx].label = label
    }

    func setMarkerColor(_ id: Marker.ID, color: Marker.Color) {
        recordSnapshot()
        guard let idx = project.timeline.markers.firstIndex(where: { $0.id == id }) else { return }
        project.timeline.markers[idx].color = color
    }

    func deleteMarker(_ id: Marker.ID) {
        recordSnapshot()
        project.timeline.markers.removeAll { $0.id == id }
    }

    func clearAllMarkers() {
        guard !project.timeline.markers.isEmpty else { return }
        recordSnapshot()
        project.timeline.markers.removeAll()
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

    // MARK: - Speed ramping

    /// Replace the clip's speed-ramp curve. Recomputes the clip's
    /// effective display duration and ripple-pushes following clips on
    /// the same track to keep adjacency intact. Pass `nil` to clear the
    /// ramp and fall back to the scalar `speed`.
    func setSpeedKeyframes(_ keyframes: [SpeedKeyframe]?, on id: Clip.ID, preset: SpeedRampPreset? = nil) {
        recordSnapshot()
        guard let location = locateClipForSpeedRamp(id) else { return }
        var clip = project.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        clip.speedKeyframes = (keyframes?.isEmpty == false) ? keyframes : nil
        // Track which preset produced the current curve so the inspector
        // can mark the right menu item with a checkmark. Clear it on
        // manual / nil writes — the curve no longer matches a preset.
        clip.lastSpeedPreset = (clip.speedKeyframes == nil) ? nil : preset
        let newDuration = clip.effectiveDisplayDuration()
        let oldDuration = clip.timeRange.duration
        let delta = newDuration - oldDuration
        clip.timeRange = TimeRange(start: clip.timeRange.start, duration: newDuration)
        project.timeline.tracks[location.trackIndex].clips[location.clipIndex] = clip

        // Ripple-push subsequent clips on the same track so trailing
        // neighbours don't suddenly overlap (or leave a gap) when the
        // user changes the speed curve.
        if abs(delta) > 0.001 {
            for i in (location.clipIndex + 1)..<project.timeline.tracks[location.trackIndex].clips.count {
                let other = project.timeline.tracks[location.trackIndex].clips[i]
                project.timeline.tracks[location.trackIndex].clips[i].timeRange = TimeRange(
                    start: max(0, other.timeRange.start + delta),
                    duration: other.timeRange.duration
                )
            }
        }
        Task { await reloadComposition() }
    }

    /// Apply one of the canned speed-ramp curves. Convenience that wraps
    /// `setSpeedKeyframes` with a preset's keyframe list.
    func applySpeedPreset(_ preset: SpeedRampPreset, on id: Clip.ID) {
        guard let location = locateClipForSpeedRamp(id) else { return }
        let clip = project.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        let keyframes = preset.keyframes(forSourceDuration: clip.sourceRange.duration)
        // `.none` is "reset to 1×" — keyframes() returns nil, the
        // setter drops the ramp, and lastSpeedPreset clears with it.
        setSpeedKeyframes(keyframes, on: id, preset: preset == .none ? nil : preset)
    }

    private struct ClipPosition {
        let trackIndex: Int
        let clipIndex: Int
    }

    private func locateClipForSpeedRamp(_ id: Clip.ID) -> ClipPosition? {
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            if let clipIndex = track.clips.firstIndex(where: { $0.id == id }) {
                return ClipPosition(trackIndex: trackIndex, clipIndex: clipIndex)
            }
        }
        return nil
    }

    /// Move a clip horizontally along its track. CapCut-style:
    ///   1. The dragged clip is lifted off the track temporarily.
    ///   2. We compute its target start (with snapping against the rest of
    ///      the timeline and the playhead).
    ///   3. If the target start falls *inside* another clip's range, we
    ///      clamp to that clip's nearest free edge instead of overlapping.
    ///   4. Any clips after the new placement that would now overlap get
    ///      ripple-pushed forward together so the drop point makes room —
    ///      so you can move a clip into a gap between split halves even
    ///      when the gap is narrower than the clip.
    func moveClip(_ id: Clip.ID, toStart newStart: TimeInterval) {
        recordSnapshot()
        for trackIndex in project.timeline.tracks.indices {
            guard let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) else {
                continue
            }
            let originalClip = project.timeline.tracks[trackIndex].clips[clipIndex]
            let duration = originalClip.timeRange.duration

            // Lift the dragged clip off this track.
            var others = project.timeline.tracks[trackIndex].clips
            others.remove(at: clipIndex)
            others.sort { $0.timeRange.start < $1.timeRange.start }

            var candidate = max(0, newStart)

            // Snap to anchors: timeline origin, playhead, and the start/end
            // of every clip on every other track (so vertical alignment
            // across lanes still works). Skipped entirely when snap is off.
            if snapEnabled {
                let snapTolerance: TimeInterval = 0.08
                var snapPoints: [TimeInterval] = [0, playback.currentTime]
                for laneTrack in project.timeline.tracks {
                    for clip in laneTrack.clips where clip.id != id {
                        snapPoints.append(clip.timeRange.start)
                        snapPoints.append(clip.timeRange.end)
                    }
                }
                var snapTargets: [TimeInterval] = []
                for point in snapPoints {
                    snapTargets.append(point)
                    snapTargets.append(point - duration)
                }
                if let best = snapTargets
                    .filter({ $0 >= 0 })
                    .min(by: { abs($0 - candidate) < abs($1 - candidate) }),
                   abs(best - candidate) <= snapTolerance {
                    candidate = best
                }
            }

            // Where in chronological order does this drop fit? Use the
            // dragged clip's *centre* so a drop just past a clip's midpoint
            // is treated as "after that clip" — the CapCut feel users
            // expect.
            let dropCentre = candidate + duration / 2
            let insertIndex = others.firstIndex(where: { $0.timeRange.midpoint > dropCentre })
                ?? others.count

            // The dragged clip can't start before the previous neighbour's
            // end — that side is the hard wall. (Overlap with the *next*
            // neighbour is resolved by ripple-pushing it forward below.)
            let previousEnd: TimeInterval = (insertIndex > 0) ? others[insertIndex - 1].timeRange.end : 0
            let effectiveStart = max(previousEnd, candidate)
            let effectiveEnd = effectiveStart + duration

            // Ripple: if the dragged clip would overlap the clip at
            // `insertIndex` (or any after), push the whole subsequent run
            // forward in lock-step so they stay adjacent to each other.
            if insertIndex < others.count, others[insertIndex].timeRange.start < effectiveEnd {
                let push = effectiveEnd - others[insertIndex].timeRange.start
                for i in insertIndex..<others.count {
                    let c = others[i]
                    others[i].timeRange = TimeRange(
                        start: c.timeRange.start + push,
                        duration: c.timeRange.duration
                    )
                }
            }

            // Slot the dragged clip into its new home.
            var movedClip = originalClip
            movedClip.timeRange = TimeRange(start: effectiveStart, duration: duration)
            others.insert(movedClip, at: insertIndex)
            project.timeline.tracks[trackIndex].clips = others
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
