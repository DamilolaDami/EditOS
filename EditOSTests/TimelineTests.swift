import XCTest
@testable import EditOS

/// Pure-model tests for `Timeline`, `TimeRange`, and friends. These don't
/// touch AVFoundation, SwiftData, or anything stateful — they exercise the
/// data primitives that the rest of the engine depends on, so they're a
/// good first line of defence against regressions in arithmetic.
final class TimelineTests: XCTestCase {

    // MARK: - TimeRange

    func testTimeRangeEndIsStartPlusDuration() {
        let range = TimeRange(start: 2.5, duration: 4.0)
        XCTAssertEqual(range.end, 6.5, accuracy: 0.0001)
    }

    func testTimeRangeMidpointIsHalfwayThrough() {
        let range = TimeRange(start: 10, duration: 6)
        XCTAssertEqual(range.midpoint, 13, accuracy: 0.0001)
    }

    func testTimeRangeContainsRespectsHalfOpenInterval() {
        let range = TimeRange(start: 5, duration: 3)
        XCTAssertTrue(range.contains(5))
        XCTAssertTrue(range.contains(6.5))
        XCTAssertFalse(range.contains(8))   // end is exclusive
        XCTAssertFalse(range.contains(4.9))
    }

    func testTimeRangeIntersectsOverlap() {
        let a = TimeRange(start: 0, duration: 5)
        let b = TimeRange(start: 3, duration: 4)
        XCTAssertTrue(a.intersects(b))
        XCTAssertTrue(b.intersects(a))
    }

    func testTimeRangeIntersectsTouchingEdgesDoNotIntersect() {
        // Half-open semantics: [0..5) and [5..10) are adjacent, not
        // overlapping.
        let a = TimeRange(start: 0, duration: 5)
        let b = TimeRange(start: 5, duration: 5)
        XCTAssertFalse(a.intersects(b))
        XCTAssertFalse(b.intersects(a))
    }

    func testTimeRangeIntersectsDisjoint() {
        let a = TimeRange(start: 0, duration: 3)
        let b = TimeRange(start: 10, duration: 2)
        XCTAssertFalse(a.intersects(b))
    }

    func testTimeRangeNormalizesNegativeStart() {
        // Init clamps start and duration to >= 0 so other arithmetic doesn't
        // produce nonsense.
        let range = TimeRange(start: -3, duration: 5)
        XCTAssertEqual(range.start, 0)
        XCTAssertEqual(range.duration, 5)
    }

    func testTimeRangeNormalizesNegativeDuration() {
        let range = TimeRange(start: 0, duration: -2)
        XCTAssertEqual(range.duration, 0)
    }

    func testTimeRangeFromStartAndEndInit() {
        let range = TimeRange(start: 4, end: 10)
        XCTAssertEqual(range.duration, 6, accuracy: 0.0001)
        XCTAssertEqual(range.end, 10, accuracy: 0.0001)
    }

    // MARK: - Timeline.duration

    func testTimelineDurationIsZeroWhenEmpty() {
        let timeline = Timeline(tracks: [Track(kind: .video)])
        XCTAssertEqual(timeline.duration, 0)
    }

    func testTimelineDurationIsMaxClipEnd() {
        let assetID = UUID()
        let clipA = Clip(
            assetID: assetID,
            timeRange: TimeRange(start: 0, duration: 3),
            sourceRange: TimeRange(start: 0, duration: 3)
        )
        let clipB = Clip(
            assetID: assetID,
            timeRange: TimeRange(start: 5, duration: 4),  // ends at 9
            sourceRange: TimeRange(start: 0, duration: 4)
        )
        let timeline = Timeline(tracks: [
            Track(kind: .video, clips: [clipA, clipB])
        ])
        XCTAssertEqual(timeline.duration, 9, accuracy: 0.0001)
    }

    func testTimelineDurationIncludesOverlayClipsPastLastVideo() {
        // Regression for the tail-padding work: an overlay clip placed
        // after the last video clip must count toward timeline duration,
        // so the composition pipeline knows to pad AVPlayer's clock.
        let assetID = UUID()
        let video = Clip(
            assetID: assetID,
            timeRange: TimeRange(start: 0, duration: 5),
            sourceRange: TimeRange(start: 0, duration: 5)
        )
        let title = Clip(
            assetID: UUID(),
            timeRange: TimeRange(start: 5, duration: 3),   // ends at 8
            sourceRange: TimeRange(start: 0, duration: 3),
            label: "Title",
            text: "Hello"
        )
        let timeline = Timeline(tracks: [
            Track(kind: .video, clips: [video]),
            Track(kind: .caption, clips: [title])
        ])
        XCTAssertEqual(timeline.duration, 8, accuracy: 0.0001)
    }

    func testTimelineDurationSpansMultipleTracks() {
        let asset = UUID()
        let video = Clip(
            assetID: asset,
            timeRange: TimeRange(start: 0, duration: 10),
            sourceRange: TimeRange(start: 0, duration: 10)
        )
        let audio = Clip(
            assetID: asset,
            timeRange: TimeRange(start: 8, duration: 6),  // ends at 14
            sourceRange: TimeRange(start: 0, duration: 6)
        )
        let timeline = Timeline(tracks: [
            Track(kind: .video, clips: [video]),
            Track(kind: .audio, clips: [audio])
        ])
        XCTAssertEqual(timeline.duration, 14, accuracy: 0.0001)
    }

    // MARK: - CMTimeRange bridging

    func testTimeRangeRoundTripsThroughCMTimeRange() {
        // Lossiness is bounded by the 600-timescale we use everywhere.
        let original = TimeRange(start: 1.5, duration: 2.25)
        let bridged = TimeRange(original.cmTimeRange)
        XCTAssertEqual(bridged.start, original.start, accuracy: 0.005)
        XCTAssertEqual(bridged.duration, original.duration, accuracy: 0.005)
    }
}
