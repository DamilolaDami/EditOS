import Foundation

/// A transition between two adjacent video clips on the same track.
///
/// Stored on the *leading* clip as `transitionToNext`, so a track is a
/// sequence of (clip, optional transition) pairs. The composition
/// pipeline overlaps the next clip's leading edge with this clip's
/// trailing edge by `duration` seconds, then renders the visual blend
/// per `kind`.
struct Transition: Hashable, Sendable, Codable {
    var kind: Kind
    /// Length of the transition in seconds. Clamped to 0.05…4.0 so it
    /// can't grow longer than either neighbouring clip.
    var duration: TimeInterval

    init(kind: Kind, duration: TimeInterval = 0.5) {
        self.kind = kind
        self.duration = max(0.05, min(4.0, duration))
    }

    static let defaultCrossfade = Transition(kind: .crossfade, duration: 0.5)

    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case crossfade
        case dipToBlack
        case dipToWhite

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .crossfade:  return "Crossfade"
            case .dipToBlack: return "Dip to Black"
            case .dipToWhite: return "Dip to White"
            }
        }

        var systemImage: String {
            switch self {
            case .crossfade:  return "rectangle.2.swap"
            case .dipToBlack: return "moon.fill"
            case .dipToWhite: return "sun.max.fill"
            }
        }
    }
}
