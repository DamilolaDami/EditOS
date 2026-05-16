import SwiftUI

/// Stereo level meter shown alongside the preview transport controls.
///
/// V1 drives the bars from an animated function of the playback state
/// rather than tapping real audio output via MTAudioProcessingTap. The
/// effect is "the meter dances while playback is active", which is the
/// signal users actually want — when the bar is bouncing, audio is
/// playing; when it isn't, the player is paused / silent.
///
/// A follow-up can swap the animated source for a real
/// MTAudioProcessingTap-based level publisher without touching this
/// view — just publish `levels: [Float]` from `PlaybackEngine` and the
/// shape stays the same.
struct AudioMeter: View {
    @Environment(\.theme) private var theme
    @Bindable var playback: PlaybackEngine

    /// Width of each bar — slim enough to live next to the transport
    /// buttons without dominating them.
    var barWidth: CGFloat = 4
    /// Height of the strip.
    var height: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playback.isPlaying)) { context in
            HStack(spacing: 2) {
                bar(for: .left, at: context.date)
                bar(for: .right, at: context.date)
            }
            .frame(height: height)
        }
    }

    private enum Channel: CaseIterable, Hashable {
        case left, right
        /// A small per-channel phase offset so the two bars don't
        /// pulse in lockstep — gives the meter a sense of *stereo*
        /// activity rather than two synced mono pulses.
        var phase: Double {
            switch self {
            case .left:  return 0
            case .right: return 0.7
            }
        }
    }

    private func bar(for channel: Channel, at date: Date) -> some View {
        let level = currentLevel(for: channel, at: date)
        return ZStack(alignment: .bottom) {
            // Track background — full-height tint of the surface.
            Capsule()
                .fill(theme.colors.surface.opacity(0.7))
            // Filled portion sized by level. Capsule + linear gradient
            // gives the classic green→yellow→red VU look.
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            theme.colors.success,
                            theme.colors.warning,
                            theme.colors.danger
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(height: max(1, CGFloat(level) * height))
                .animation(.easeOut(duration: 0.08), value: level)
        }
        .frame(width: barWidth, height: height)
    }

    /// Produces a simulated 0…1 channel level. While playing, combines
    /// a few sine waves of different frequencies + a slow envelope so
    /// the bars look like real audio activity. When paused, decays
    /// quickly toward zero.
    private func currentLevel(for channel: Channel, at date: Date) -> Double {
        guard playback.isPlaying else { return 0 }
        let t = date.timeIntervalSince1970 + channel.phase
        // Two sine waves at incommensurate frequencies + a slow
        // envelope. The output sits in roughly 0.35…0.95.
        let pulse =
            0.5 + 0.25 * sin(t * 7.1)
                + 0.2 * sin(t * 13.3)
        let envelope = 0.7 + 0.3 * sin(t * 0.9)
        return max(0.05, min(0.98, pulse * envelope))
    }
}
