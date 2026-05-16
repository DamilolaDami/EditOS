import Foundation

/// Kinetic-typography preset attached to a text overlay clip. The
/// animation runs across the first `duration` seconds of the clip's
/// time range, then the text stays static for the rest of the clip.
///
/// Why on the clip rather than a separate track: each text overlay
/// already owns its own time range + position + style; the animation
/// is just one more property on that overlay. Keeping it on the clip
/// means the composition pipeline can reuse the same renderTextOverlay
/// path and just vary the output per-frame inside the animation window.
struct TextAnimation: Hashable, Sendable, Codable {
    var kind: Kind
    /// Length of the intro animation in seconds. Clamped to 0.1…5 so a
    /// stray slider can't park the text off-screen indefinitely.
    var duration: TimeInterval

    init(kind: Kind, duration: TimeInterval = 0.6) {
        self.kind = kind
        self.duration = max(0.1, min(5.0, duration))
    }

    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case typewriter
        case fadeInWord
        case slideFromBottom
        case slideFromLeft
        case slideFromRight
        case popBounce
        case scaleUp

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .typewriter:        return "Typewriter"
            case .fadeInWord:        return "Fade In Word"
            case .slideFromBottom:   return "Slide Up"
            case .slideFromLeft:     return "Slide Right"
            case .slideFromRight:    return "Slide Left"
            case .popBounce:         return "Pop"
            case .scaleUp:           return "Scale Up"
            }
        }

        var systemImage: String {
            switch self {
            case .typewriter:        return "keyboard"
            case .fadeInWord:        return "text.alignleft"
            case .slideFromBottom:   return "arrow.up"
            case .slideFromLeft:     return "arrow.right"
            case .slideFromRight:    return "arrow.left"
            case .popBounce:         return "sparkles"
            case .scaleUp:           return "plus.magnifyingglass"
            }
        }
    }

    /// Apply easing — most of our animations want an ease-out so they
    /// settle into place rather than slamming into their final state.
    static func easeOut(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        return 1 - pow(1 - clamped, 3)
    }

    /// A gentle overshoot for the pop-bounce preset.
    static func easeOutBack(_ t: Double, overshoot: Double = 1.7) -> Double {
        let clamped = max(0, min(1, t))
        let s = overshoot
        let x = clamped - 1
        return 1 + (s + 1) * pow(x, 3) + s * pow(x, 2)
    }
}
