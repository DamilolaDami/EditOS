import Foundation

struct Timeline: Hashable, Sendable, Codable {
    var tracks: [Track]

    init(tracks: [Track] = Timeline.defaultTracks()) {
        self.tracks = tracks
    }

    var duration: TimeInterval {
        tracks
            .flatMap(\.clips)
            .map(\.timeRange.end)
            .max() ?? 0
    }

    static func defaultTracks() -> [Track] {
        [
            Track(kind: .video),
            Track(kind: .overlay),
            Track(kind: .audio)
        ]
    }
}
