import Foundation

struct Timeline: Hashable, Sendable, Codable {
    var tracks: [Track]
    /// Named pins along the timeline. Optional in the encoded form so
    /// older project files that pre-date markers decode cleanly with an
    /// empty array.
    var markers: [Marker] = []

    init(tracks: [Track] = Timeline.defaultTracks(), markers: [Marker] = []) {
        self.tracks = tracks
        self.markers = markers
    }

    // Custom decoder so projects saved before markers existed still load.
    // Swift's synthesized init(from:) throws on missing keys; this lets
    // `markers` default to empty when the blob doesn't carry it.
    private enum CodingKeys: String, CodingKey {
        case tracks, markers
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tracks = try container.decode([Track].self, forKey: .tracks)
        self.markers = (try? container.decode([Marker].self, forKey: .markers)) ?? []
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
