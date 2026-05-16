import SwiftUI

/// Tiny inline curve viz for a clip's speed-ramp keyframe array.
/// Renders the multiplier as a path across the source-time x-axis and
/// drops markers at each keyframe. Read-only in V1 — keyframe editing
/// flows through the preset menu. (A future PR can add drag handles to
/// reposition keyframes; the layout already reserves the gesture space.)
struct SpeedRampCurveView: View {
    @Environment(\.theme) private var theme
    let keyframes: [SpeedKeyframe]
    let sourceDuration: TimeInterval
    var height: CGFloat = 56

    /// Multiplier range to map vertically. Includes a small headroom above
    /// the max so the curve doesn't touch the top edge.
    private var range: ClosedRange<Double> {
        let multipliers = keyframes.map(\.multiplier)
        let lo = (multipliers.min() ?? 0.5) - 0.2
        let hi = (multipliers.max() ?? 2.0) + 0.2
        return min(0.1, lo)...max(2.0, hi)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.colors.surface.opacity(0.6))
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.colors.border.opacity(0.5), lineWidth: 1)

                // Y-axis baseline at 1× — the "natural speed" reference.
                let baselineY = yPosition(for: 1.0, height: proxy.size.height)
                Path { path in
                    path.move(to: CGPoint(x: 8, y: baselineY))
                    path.addLine(to: CGPoint(x: proxy.size.width - 8, y: baselineY))
                }
                .stroke(theme.colors.border.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                if !keyframes.isEmpty, sourceDuration > 0.001 {
                    // Filled area under the curve, anchored at the baseline.
                    Path { path in
                        path.move(to: CGPoint(x: xPosition(for: 0, width: proxy.size.width), y: baselineY))
                        for kf in sortedKeyframes {
                            path.addLine(to: pointFor(kf, width: proxy.size.width, height: proxy.size.height))
                        }
                        path.addLine(to: CGPoint(x: xPosition(for: sourceDuration, width: proxy.size.width), y: baselineY))
                        path.closeSubpath()
                    }
                    .fill(theme.colors.accent.opacity(0.18))

                    // Curve stroke
                    Path { path in
                        let sorted = sortedKeyframes
                        guard let first = sorted.first else { return }
                        path.move(to: pointFor(first, width: proxy.size.width, height: proxy.size.height))
                        for kf in sorted.dropFirst() {
                            path.addLine(to: pointFor(kf, width: proxy.size.width, height: proxy.size.height))
                        }
                    }
                    .stroke(theme.colors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    // Keyframe markers
                    ForEach(Array(sortedKeyframes.enumerated()), id: \.offset) { _, kf in
                        let p = pointFor(kf, width: proxy.size.width, height: proxy.size.height)
                        Circle()
                            .fill(theme.colors.accent)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .position(p)
                    }
                } else {
                    Text("Flat 1× — no ramp")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
        }
        .frame(height: height)
    }

    private var sortedKeyframes: [SpeedKeyframe] {
        keyframes.sorted { $0.time < $1.time }
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        let normalized = sourceDuration > 0.001 ? (time / sourceDuration) : 0
        let inset: CGFloat = 8
        return inset + CGFloat(normalized) * max(0, width - inset * 2)
    }

    private func yPosition(for multiplier: Double, height: CGFloat) -> CGFloat {
        let r = range
        let span = r.upperBound - r.lowerBound
        guard span > 0 else { return height / 2 }
        let normalized = (multiplier - r.lowerBound) / span
        let inset: CGFloat = 6
        // SwiftUI's y grows downward; invert so higher multiplier = higher
        // on screen.
        return inset + (1 - CGFloat(normalized)) * max(0, height - inset * 2)
    }

    private func pointFor(_ kf: SpeedKeyframe, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(
            x: xPosition(for: kf.time, width: width),
            y: yPosition(for: kf.multiplier, height: height)
        )
    }
}
