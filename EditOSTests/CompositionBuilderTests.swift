import AVFoundation
import XCTest
@testable import EditOS

/// Tests for `CompositionBuilder`. AV-level tests need real media on disk
/// (an AVURLAsset has to be loadable for `insertClip` to do anything
/// meaningful), so the tests here either:
///
/// 1. Exercise the *resolver-fail* path — the builder logs per-clip errors
///    and continues, producing a (mostly empty) `CompositionResult`. This
///    verifies the pipeline doesn't crash on missing media.
///
/// 2. Verify pure-model helpers that the builder reads from (e.g. that
///    timeline duration includes overlay tracks, which the pad step depends
///    on).
///
/// Contributors with bandwidth: a follow-up PR could generate a 1-second
/// black-frame fixture at test-runtime via `AVAssetWriter` and unlock end-
/// to-end pipeline tests (audio ducking, clipTransforms, tail padding's
/// actual scaleTimeRange behaviour). Hooks for that fixture would live in
/// the helper at the bottom of this file.
final class CompositionBuilderTests: XCTestCase {

    // MARK: - Empty / failed-resolve paths

    func testEmptyProjectProducesZeroDurationComposition() async throws {
        let project = Project(
            name: "Empty",
            timeline: Timeline(tracks: [Track(kind: .video), Track(kind: .audio)])
        )
        let builder = CompositionBuilder()
        let result = try await builder.build(project, assetResolver: NullAssetResolver())

        XCTAssertEqual(result.composition.duration.seconds, 0, accuracy: 0.0001)
        XCTAssertNil(result.audioMix)
    }

    func testResolverFailureProducesGracefullyEmptyComposition() async throws {
        // Even with clips in the timeline, a failing resolver means
        // `insertClip` never runs — the builder should still return a
        // valid CompositionResult (just no media), not crash.
        let asset = MediaAsset(id: UUID(), displayName: "missing.mov", kind: .video, duration: 5)
        let clip = Clip(
            assetID: asset.id,
            timeRange: TimeRange(start: 0, duration: 5),
            sourceRange: TimeRange(start: 0, duration: 5)
        )
        let project = Project(
            name: "Missing media",
            assets: [asset],
            timeline: Timeline(tracks: [Track(kind: .video, clips: [clip])])
        )
        let builder = CompositionBuilder()
        let result = try await builder.build(project, assetResolver: NullAssetResolver())

        // Composition has no usable tracks because every resolve failed, so
        // duration is 0. We just care that the builder didn't throw.
        XCTAssertGreaterThanOrEqual(result.composition.duration.seconds, 0)
    }

    // MARK: - Overlay-only tail padding (model side)

    func testTextOverlayPastLastVideoExtendsTimelineDuration() {
        // CompositionBuilder.padCompositionToFullTimeline uses
        // `project.timeline.duration` as the pad target. Verifying that
        // duration is computed correctly is the test that protects the
        // tail-padding contract from regressing.
        let videoAsset = MediaAsset(id: UUID(), displayName: "v.mov", kind: .video, duration: 6)
        let video = Clip(
            assetID: videoAsset.id,
            timeRange: TimeRange(start: 0, duration: 6),
            sourceRange: TimeRange(start: 0, duration: 6)
        )
        let title = Clip(
            assetID: UUID(),
            timeRange: TimeRange(start: 6, duration: 4),
            sourceRange: TimeRange(start: 0, duration: 4),
            text: "After-video title"
        )
        let project = Project(
            name: "Tail title",
            assets: [videoAsset],
            timeline: Timeline(tracks: [
                Track(kind: .video, clips: [video]),
                Track(kind: .caption, clips: [title])
            ])
        )
        XCTAssertEqual(project.timeline.duration, 10, accuracy: 0.0001)
    }

    // MARK: - Result struct invariants

    func testCompositionResultCanBeReassembledWithNewVideoComposition() async throws {
        // The export sheet's `tunedComposition` constructs a new
        // `CompositionResult` with the same AVComposition but tweaked
        // `videoComposition` / `audioMix`. Make sure that pattern
        // compiles and that the result holds onto the original
        // composition pointer.
        let project = Project(
            name: "Tuned",
            timeline: Timeline(tracks: [Track(kind: .video)])
        )
        let builder = CompositionBuilder()
        let original = try await builder.build(project, assetResolver: NullAssetResolver())

        let tweaked = CompositionResult(
            composition: original.composition,
            videoComposition: nil,
            audioMix: nil
        )
        XCTAssertTrue(tweaked.composition === original.composition,
                      "Re-wrapping should reuse the same AVComposition reference")
    }
}

/// Shared with EditorViewModelTests for tests that don't need real media.
/// Always throws, which makes the builder skip every clip's insert.
private struct NullAssetResolver: AssetResolver {
    func resolve(_ asset: MediaAsset) async throws -> URL {
        throw NSError(domain: "EditOSTests.NullAssetResolver", code: -1)
    }
}
