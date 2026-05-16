import CoreMedia
import Foundation

/// A half-open time range, measured in seconds. UI-friendly and `Codable`;
/// bridges to `CMTimeRange` at the AVFoundation boundary.
struct TimeRange: Hashable, Sendable, Codable {
    var start: TimeInterval
    var duration: TimeInterval

    var end: TimeInterval { start + duration }
    var midpoint: TimeInterval { start + duration / 2 }

    static let zero = TimeRange(start: 0, duration: 0)

    init(start: TimeInterval, duration: TimeInterval) {
        self.start = max(0, start)
        self.duration = max(0, duration)
    }

    init(start: TimeInterval, end: TimeInterval) {
        self.init(start: start, duration: end - start)
    }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    func intersects(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }
}

extension TimeRange {
    var cmTimeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    init(_ cmTimeRange: CMTimeRange) {
        self.init(
            start: cmTimeRange.start.seconds,
            duration: cmTimeRange.duration.seconds
        )
    }
}
