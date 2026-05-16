import Foundation

/// A named pin on the timeline. Markers help users navigate quickly
/// ("Hook", "Punchline", "B-roll start"), and double as chapter atoms in
/// the exported MP4 / MOV so YouTube / Apple Podcasts / Books pick them
/// up as chapters.
struct Marker: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    /// Position along the project timeline, in seconds.
    var time: TimeInterval
    /// User-visible label. Empty when the user hasn't named it yet.
    var label: String
    /// One of a small palette of tints. Stored as the case rawValue so
    /// the model stays simple and `Codable`-safe across schema changes.
    var color: Color

    init(
        id: UUID = UUID(),
        time: TimeInterval,
        label: String = "",
        color: Color = .accent
    ) {
        self.id = id
        self.time = max(0, time)
        self.label = label
        self.color = color
    }

    enum Color: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
        case accent
        case red
        case orange
        case yellow
        case green
        case blue
        case purple
        case pink

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .accent: return "Accent"
            case .red:    return "Red"
            case .orange: return "Orange"
            case .yellow: return "Yellow"
            case .green:  return "Green"
            case .blue:   return "Blue"
            case .purple: return "Purple"
            case .pink:   return "Pink"
            }
        }
    }
}
