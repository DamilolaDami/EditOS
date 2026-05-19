import Foundation

struct Timeline: Hashable, Sendable, Codable {
    var tracks: [Track]
    /// Named pins along the timeline. Optional in the encoded form so
    /// older project files that pre-date markers decode cleanly with an
    /// empty array.
    var markers: [Marker] = []
    /// Beat positions (project-time seconds) returned by `BeatDetector`.
    /// Powers tick-mark rendering on the ruler and feeds snap targets
    /// for clip-edge drags. Empty until the user runs Detect Beats on
    /// an audio clip.
    var detectedBeats: [TimeInterval] = []
    /// Estimated tempo for `detectedBeats`. Surfaced in the inspector
    /// next to the Detect Beats button so the user can sanity-check the
    /// analysis.
    var detectedTempo: Double? = nil

    init(
        tracks: [Track] = Timeline.defaultTracks(),
        markers: [Marker] = [],
        detectedBeats: [TimeInterval] = [],
        detectedTempo: Double? = nil
    ) {
        self.tracks = tracks
        self.markers = markers
        self.detectedBeats = detectedBeats
        self.detectedTempo = detectedTempo
    }

    // Custom decoder so projects saved before markers / beats existed
    // still load. Swift's synthesized init(from:) throws on missing
    // keys; this lets the newer fields default cleanly when the blob
    // doesn't carry them.
    private enum CodingKeys: String, CodingKey {
        case tracks, markers, detectedBeats, detectedTempo
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tracks = try container.decode([Track].self, forKey: .tracks)
        self.markers = (try? container.decode([Marker].self, forKey: .markers)) ?? []
        self.detectedBeats = (try? container.decode([TimeInterval].self, forKey: .detectedBeats)) ?? []
        self.detectedTempo = try? container.decode(Double.self, forKey: .detectedTempo)
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
