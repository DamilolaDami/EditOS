import Foundation

/// One-tap speed-ramp curves exposed in the inspector. Each preset returns
/// a list of `SpeedKeyframe`s sized to the host clip's source duration.
enum SpeedRampPreset: String, CaseIterable, Identifiable, Sendable {
    case none
    case linearRampUp        // 1× → 2× across the clip
    case linearRampDown      // 2× → 1×
    case slowMoMiddle        // 1× → 0.5× → 1× (drama beat)
    case fastIntoSlow        // 2× → 0.5×
    case slowIntoFast        // 0.5× → 2×
    case freezeStart         // 0.05× for 1s, then 1×
    case freezeEnd           // 1×, then 0.05× for last 1s
    case jumpCut             // 1× → 4× → 1× (compress a beat)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:           return "Reset to 1×"
        case .linearRampUp:   return "Ramp up · 1→2×"
        case .linearRampDown: return "Ramp down · 2→1×"
        case .slowMoMiddle:   return "Slow-mo middle"
        case .fastIntoSlow:   return "Fast → slow"
        case .slowIntoFast:   return "Slow → fast"
        case .freezeStart:    return "Freeze first second"
        case .freezeEnd:      return "Freeze last second"
        case .jumpCut:        return "Compress middle (jump cut)"
        }
    }

    var systemImage: String {
        switch self {
        case .none:           return "1.circle"
        case .linearRampUp:   return "arrow.up.right"
        case .linearRampDown: return "arrow.down.right"
        case .slowMoMiddle:   return "tortoise.fill"
        case .fastIntoSlow:   return "hare.fill"
        case .slowIntoFast:   return "tortoise"
        case .freezeStart:    return "play.slash"
        case .freezeEnd:      return "pause.fill"
        case .jumpCut:        return "scissors"
        }
    }

    /// Materialise the preset as a concrete keyframe list scaled to fit
    /// `sourceDuration`. Returns nil for `.none` (caller should clear).
    func keyframes(forSourceDuration sourceDuration: TimeInterval) -> [SpeedKeyframe]? {
        let d = max(0.1, sourceDuration)
        switch self {
        case .none:
            return nil
        case .linearRampUp:
            return [
                SpeedKeyframe(time: 0, multiplier: 1.0),
                SpeedKeyframe(time: d, multiplier: 2.0)
            ]
        case .linearRampDown:
            return [
                SpeedKeyframe(time: 0, multiplier: 2.0),
                SpeedKeyframe(time: d, multiplier: 1.0)
            ]
        case .slowMoMiddle:
            return [
                SpeedKeyframe(time: 0, multiplier: 1.0),
                SpeedKeyframe(time: d * 0.4, multiplier: 0.5),
                SpeedKeyframe(time: d * 0.6, multiplier: 0.5),
                SpeedKeyframe(time: d, multiplier: 1.0)
            ]
        case .fastIntoSlow:
            return [
                SpeedKeyframe(time: 0, multiplier: 2.0),
                SpeedKeyframe(time: d, multiplier: 0.5)
            ]
        case .slowIntoFast:
            return [
                SpeedKeyframe(time: 0, multiplier: 0.5),
                SpeedKeyframe(time: d, multiplier: 2.0)
            ]
        case .freezeStart:
            let freezeUntil = min(1.0, d * 0.25)
            return [
                SpeedKeyframe(time: 0, multiplier: 0.1),
                SpeedKeyframe(time: freezeUntil, multiplier: 0.1),
                SpeedKeyframe(time: min(freezeUntil + 0.01, d), multiplier: 1.0),
                SpeedKeyframe(time: d, multiplier: 1.0)
            ]
        case .freezeEnd:
            let freezeFrom = max(0, d - min(1.0, d * 0.25))
            return [
                SpeedKeyframe(time: 0, multiplier: 1.0),
                SpeedKeyframe(time: max(freezeFrom - 0.01, 0), multiplier: 1.0),
                SpeedKeyframe(time: freezeFrom, multiplier: 0.1),
                SpeedKeyframe(time: d, multiplier: 0.1)
            ]
        case .jumpCut:
            return [
                SpeedKeyframe(time: 0, multiplier: 1.0),
                SpeedKeyframe(time: d * 0.3, multiplier: 1.0),
                SpeedKeyframe(time: d * 0.5, multiplier: 4.0),
                SpeedKeyframe(time: d * 0.7, multiplier: 1.0),
                SpeedKeyframe(time: d, multiplier: 1.0)
            ]
        }
    }
}
