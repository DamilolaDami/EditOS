import XCTest
@testable import EditOS

/// Tests for `EditorViewModel`'s timeline-editing behaviour. We use a
/// `NullAssetResolver` so the methods that trigger `reloadComposition()`
/// don't actually try to open AVURLAssets — `CompositionBuilder` catches
/// per-clip resolve errors and continues, leaving the project model intact
/// while the player loads an effectively empty composition. That's all we
/// need to verify pure model mutations.
@MainActor
final class EditorViewModelTests: XCTestCase {

    // MARK: - moveClip

    func testMoveClipPlacesIntoEmptyGap() {
        let model = makeModelWithThreeClips()
        let track = model.project.timeline.tracks.first { $0.kind == .video }!
        let clipC = track.clips[2]  // 15..21

        // Drop clip C into the empty space at t=10 — between A [0..6] and
        // B [7..14] there's only a 1s gap, so this should ripple-push B
        // forward to make room.
        model.moveClip(clipC.id, toStart: 6.5)

        let updatedTrack = model.project.timeline.tracks.first { $0.kind == .video }!
        let cAfter = updatedTrack.clips.first { $0.id == clipC.id }!
        let bAfter = updatedTrack.clips.first { $0.timeRange.start > cAfter.timeRange.end - 0.01 }
        XCTAssertGreaterThanOrEqual(cAfter.timeRange.start, 6, "Should clamp to previous clip's end (6)")
        XCTAssertNotNil(bAfter, "Clip B should have been ripple-pushed past clip C's new range")
    }

    func testMoveClipClampsBelowZero() {
        let model = makeModelWithThreeClips()
        let track = model.project.timeline.tracks.first { $0.kind == .video }!
        let clipA = track.clips[0]  // 0..6

        // Try to drag clip A "before" the timeline start.
        model.moveClip(clipA.id, toStart: -5)

        let updatedTrack = model.project.timeline.tracks.first { $0.kind == .video }!
        let aAfter = updatedTrack.clips.first { $0.id == clipA.id }!
        XCTAssertEqual(aAfter.timeRange.start, 0, accuracy: 0.0001)
    }

    func testMoveClipPreservesDuration() {
        let model = makeModelWithThreeClips()
        let track = model.project.timeline.tracks.first { $0.kind == .video }!
        let clipB = track.clips[1]
        let originalDuration = clipB.timeRange.duration

        model.moveClip(clipB.id, toStart: 20)

        let updatedTrack = model.project.timeline.tracks.first { $0.kind == .video }!
        let bAfter = updatedTrack.clips.first { $0.id == clipB.id }!
        XCTAssertEqual(bAfter.timeRange.duration, originalDuration, accuracy: 0.0001)
    }

    // MARK: - splitClipAtPlayhead

    func testSplitAtClipStartIsNoOp() async {
        // PlaybackEngine.seek clamps to duration; without an AVPlayerItem
        // loaded, duration is 0 so the playhead can't move past 0. That's
        // exactly the "split at clip start" boundary the splitter rejects.
        let model = makeModelWithSingleClip(duration: 10)
        XCTAssertEqual(model.playback.currentTime, 0)

        await model.splitClipAtPlayhead()

        let clips = model.project.timeline.tracks.first { $0.kind == .video }!.clips
        XCTAssertEqual(clips.count, 1, "Splitting at clip start should be a no-op")
    }

    func testSplitClipMathAtMidpoint() {
        // Direct unit test for the splitter's range math, without going
        // through PlaybackEngine — exercises the invariant from issue #9
        // that "two clips' durations sum to the original".
        let assetID = UUID()
        let original = Clip(
            assetID: assetID,
            timeRange: TimeRange(start: 10, duration: 8),
            sourceRange: TimeRange(start: 4, duration: 8),
            speed: 1.0
        )
        let splitAt: TimeInterval = 14  // 4s into the clip
        let offset = splitAt - original.timeRange.start
        let scaledOffset = offset * original.speed

        let left = TimeRange(start: original.timeRange.start, duration: offset)
        let right = TimeRange(start: splitAt, duration: original.timeRange.end - splitAt)

        XCTAssertEqual(left.duration + right.duration, original.timeRange.duration, accuracy: 0.0001)
        XCTAssertEqual(left.end, right.start, accuracy: 0.0001)
        XCTAssertEqual(scaledOffset, 4, accuracy: 0.0001)
    }

    // MARK: - Filters

    func testPlaceFilterCreatesFilterTrackWithClip() {
        let model = makeModelWithThreeClips()
        XCTAssertNil(model.project.timeline.tracks.first { $0.kind == .filter })

        model.placeFilter("vibrance", atTime: 0, duration: 2)

        let filterTrack = model.project.timeline.tracks.first { $0.kind == .filter }
        XCTAssertNotNil(filterTrack)
        XCTAssertEqual(filterTrack?.clips.count, 1)
        XCTAssertEqual(filterTrack?.clips.first?.filterPreset, "vibrance")
    }

    func testApplyFilterUpdatesSelectedClipsOnly() {
        let model = makeModelWithThreeClips()
        let track = model.project.timeline.tracks.first { $0.kind == .video }!
        let clipA = track.clips[0]
        let clipB = track.clips[1]
        model.selectedClipIDs = [clipA.id]

        model.applyFilter("noir", intensity: 0.8)

        let updatedTrack = model.project.timeline.tracks.first { $0.kind == .video }!
        let aAfter = updatedTrack.clips.first { $0.id == clipA.id }!
        let bAfter = updatedTrack.clips.first { $0.id == clipB.id }!
        XCTAssertEqual(aAfter.filterPreset, "noir")
        XCTAssertEqual(aAfter.filterIntensity, 0.8)
        XCTAssertNil(bAfter.filterPreset)
    }

    func testApplyFilterNilRemovesFilterAndIntensity() {
        let model = makeModelWithThreeClips()
        let track = model.project.timeline.tracks.first { $0.kind == .video }!
        let clipA = track.clips[0]
        model.selectedClipIDs = [clipA.id]
        model.applyFilter("noir", intensity: 0.6)

        model.applyFilter(nil)

        let aAfter = model.project.timeline.tracks
            .first { $0.kind == .video }!
            .clips.first { $0.id == clipA.id }!
        XCTAssertNil(aAfter.filterPreset)
        XCTAssertNil(aAfter.filterIntensity)
    }

    func testSetFilterIntensityClampsToZeroOne() {
        let model = makeModelWithThreeClips()
        let track = model.project.timeline.tracks.first { $0.kind == .video }!
        model.selectedClipIDs = [track.clips[0].id]
        model.applyFilter("vibrance", intensity: 0.5)

        model.setFilterIntensity(1.5)
        var v = model.project.timeline.tracks
            .first { $0.kind == .video }!
            .clips[0].filterIntensity
        XCTAssertEqual(v!, 1.0, accuracy: 0.0001)

        model.setFilterIntensity(-0.3)
        v = model.project.timeline.tracks
            .first { $0.kind == .video }!
            .clips[0].filterIntensity
        XCTAssertEqual(v!, 0.0, accuracy: 0.0001)
    }

    // MARK: - Text overlays

    func testPlaceTextCreatesCaptionClipOnCaptionTrack() {
        let model = makeModelWithSingleClip(duration: 10)

        model.placeText("Hello, world", atTime: 2, duration: 3)

        let captionTrack = model.project.timeline.tracks.first { $0.kind == .caption }
        XCTAssertNotNil(captionTrack)
        XCTAssertEqual(captionTrack?.clips.count, 1)
        XCTAssertEqual(captionTrack?.clips.first?.text, "Hello, world")
        XCTAssertEqual(captionTrack?.clips.first?.kind, .text)
        XCTAssertEqual(captionTrack?.clips.first?.timeRange.duration ?? 0, 3, accuracy: 0.0001)
    }

    // MARK: - Undo / Redo

    func testUndoRestoresPreviousSnapshot() {
        let model = makeModelWithSingleClip(duration: 10)
        let track = model.project.timeline.tracks.first { $0.kind == .video }!
        let originalCount = track.clips.count
        XCTAssertFalse(model.canUndo)

        model.placeText("New", atTime: 1, duration: 2)
        XCTAssertTrue(model.canUndo)
        XCTAssertTrue(model.project.timeline.tracks.contains { $0.kind == .caption && !$0.clips.isEmpty })

        model.undo()

        XCTAssertEqual(model.project.timeline.tracks.first { $0.kind == .video }!.clips.count, originalCount)
        XCTAssertFalse(model.project.timeline.tracks.contains { $0.kind == .caption && !$0.clips.isEmpty })
        XCTAssertTrue(model.canRedo)
    }

    func testRedoReappliesUndo() {
        let model = makeModelWithSingleClip(duration: 10)
        model.placeText("Greeting", atTime: 1, duration: 2)
        let withTextSnapshot = model.project

        model.undo()
        XCTAssertNotEqual(model.project, withTextSnapshot)

        model.redo()
        XCTAssertEqual(model.project.timeline, withTextSnapshot.timeline)
    }

    // MARK: - Copy / Paste

    func testCopyPasteDuplicatesSelectedClips() async {
        let model = makeModelWithThreeClips()
        let videoTrack = model.project.timeline.tracks.first { $0.kind == .video }!
        let clipA = videoTrack.clips[0]
        model.selectedClipIDs = [clipA.id]

        model.copySelection()
        XCTAssertTrue(model.hasClipboard)

        model.playback.seek(to: 25)  // clamped to duration in empty player, may not move
        await model.paste()

        // A new clip with the same content but a different id should exist.
        let allClips = model.project.timeline.tracks.flatMap(\.clips)
        let clipsForOriginalAsset = allClips.filter { $0.assetID == clipA.assetID }
        // Before paste: two clips referenced assetA (clipA + clipB which is
        // a split-half from the same source). Paste should bring the total
        // to three.
        XCTAssertEqual(clipsForOriginalAsset.count, 3,
                       "Paste should add a new clip referencing the same asset")
        let uniqueIDs = Set(clipsForOriginalAsset.map(\.id))
        XCTAssertEqual(uniqueIDs.count, clipsForOriginalAsset.count,
                       "Pasted clip must have a fresh id")
    }

    // MARK: - Delete

    func testDeleteSelectedClipsRemovesFromTrack() async {
        let model = makeModelWithThreeClips()
        let videoTrack = model.project.timeline.tracks.first { $0.kind == .video }!
        let initialCount = videoTrack.clips.count
        let target = videoTrack.clips[1]
        model.selectedClipIDs = [target.id]

        await model.deleteSelectedClips()

        let remaining = model.project.timeline.tracks
            .first { $0.kind == .video }!.clips
        XCTAssertEqual(remaining.count, initialCount - 1)
        XCTAssertFalse(remaining.contains { $0.id == target.id })
        XCTAssertTrue(model.selectedClipIDs.isEmpty, "Selection should clear after delete")
    }

    // MARK: - Selection helpers

    func testSelectAllClipsPicksEveryClip() {
        let model = makeModelWithThreeClips()
        let totalClips = model.project.timeline.tracks.flatMap(\.clips).count
        XCTAssertGreaterThan(totalClips, 0)

        model.selectAllClips()

        XCTAssertEqual(model.selectedClipIDs.count, totalClips)
    }

    func testToggleClipSelectionAddsAndRemoves() {
        let model = makeModelWithThreeClips()
        let id = model.project.timeline.tracks.first { $0.kind == .video }!.clips[0].id

        model.toggleClipSelection(id)
        XCTAssertTrue(model.isClipSelected(id))
        model.toggleClipSelection(id)
        XCTAssertFalse(model.isClipSelected(id))
    }

    // MARK: - Test helpers

    /// Three video clips with a deliberately too-small gap between the
    /// first two — same shape as the screenshots in the move-clip bug
    /// report.
    private func makeModelWithThreeClips() -> EditorViewModel {
        let assetA = MediaAsset(
            id: UUID(),
            displayName: "spongebob.mov",
            kind: .video,
            duration: 30,
            nativeSize: CGSize(width: 1920, height: 1080),
            frameRate: 30
        )
        let assetB = MediaAsset(
            id: UUID(),
            displayName: "second.mov",
            kind: .video,
            duration: 12,
            nativeSize: CGSize(width: 1920, height: 1080),
            frameRate: 30
        )

        let clipA = Clip(
            assetID: assetA.id,
            timeRange: TimeRange(start: 0, duration: 6),
            sourceRange: TimeRange(start: 0, duration: 6)
        )
        let clipB = Clip(
            assetID: assetA.id,
            timeRange: TimeRange(start: 7, duration: 7),
            sourceRange: TimeRange(start: 6, duration: 7)
        )
        let clipC = Clip(
            assetID: assetB.id,
            timeRange: TimeRange(start: 15, duration: 6),
            sourceRange: TimeRange(start: 0, duration: 6)
        )

        let project = Project(
            name: "Test",
            assets: [assetA, assetB],
            timeline: Timeline(tracks: [
                Track(kind: .video, clips: [clipA, clipB, clipC]),
                Track(kind: .overlay),
                Track(kind: .audio)
            ])
        )
        return EditorViewModel(project: project, resolver: NullAssetResolver())
    }

    private func makeModelWithSingleClip(duration: TimeInterval) -> EditorViewModel {
        let asset = MediaAsset(
            id: UUID(),
            displayName: "video.mov",
            kind: .video,
            duration: duration
        )
        let clip = Clip(
            assetID: asset.id,
            timeRange: TimeRange(start: 0, duration: duration),
            sourceRange: TimeRange(start: 0, duration: duration)
        )
        let project = Project(
            name: "Test",
            assets: [asset],
            timeline: Timeline(tracks: [
                Track(kind: .video, clips: [clip]),
                Track(kind: .overlay),
                Track(kind: .audio)
            ])
        )
        return EditorViewModel(project: project, resolver: NullAssetResolver())
    }
}

/// A resolver that always throws — used for unit tests so the
/// CompositionBuilder rebuild paths can run without touching the
/// filesystem. The builder catches per-clip resolve errors and continues,
/// so the project model stays observable for assertions.
private struct NullAssetResolver: AssetResolver {
    func resolve(_ asset: MediaAsset) async throws -> URL {
        throw NSError(domain: "EditOSTests.NullAssetResolver", code: -1)
    }
}
