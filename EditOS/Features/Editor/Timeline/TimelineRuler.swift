import SwiftUI

struct TimelineRuler: View {
    @Environment(\.theme) private var theme
    let duration: TimeInterval
    let pixelsPerSecond: CGFloat
    var onScrub: (TimeInterval) -> Void = { _ in }

    private let height: CGFloat = 36

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Subtle background band so the ruler reads as its own region.
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .fill(theme.colors.surfaceElevated.opacity(0.45))

            Canvas { context, size in
                let minor = minorTickInterval()
                let labelStride = labelStrideInterval()
                let totalMinor = Int(ceil(duration / minor))
                let labelEvery = max(1, Int(round(labelStride / minor)))

                for index in 0...totalMinor {
                    let time = Double(index) * minor
                    let x = CGFloat(time) * pixelsPerSecond
                    let isLabelTick = index % labelEvery == 0
                    let tickHeight: CGFloat = isLabelTick ? 10 : 5
                    let tickColor = isLabelTick
                        ? theme.colors.textSecondary.opacity(0.85)
                        : theme.colors.textTertiary.opacity(0.7)

                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height - tickHeight - 1))
                    path.addLine(to: CGPoint(x: x, y: size.height - 1))
                    context.stroke(path, with: .color(tickColor), lineWidth: 1)

                    if isLabelTick {
                        let label = Text(format(time: time))
                            .font(theme.typography.caption.monospacedDigit())
                            .foregroundStyle(theme.colors.textSecondary)
                        context.draw(
                            label,
                            at: CGPoint(x: x + 4, y: 3),
                            anchor: .topLeading
                        )
                    }
                }

                // Hairline rule along the bottom edge to separate ruler from tracks.
                var bottom = Path()
                bottom.move(to: CGPoint(x: 0, y: size.height - 0.5))
                bottom.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                context.stroke(bottom, with: .color(theme.colors.border), lineWidth: 1)
            }
        }
        .frame(width: CGFloat(duration) * pixelsPerSecond, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named(TimelineCoordinateSpace.name)
            )
            .onChanged { value in
                let time = max(0, Double(value.location.x / pixelsPerSecond))
                onScrub(min(time, duration))
            }
        )
    }

    /// Spacing between minor (un-labeled) ticks in seconds. Tightens as the user
    /// zooms in so the ruler always reads clearly.
    private func minorTickInterval() -> TimeInterval {
        switch pixelsPerSecond {
        case ..<30: 1
        case ..<60: 0.5
        case ..<120: 0.25
        case ..<240: 0.1
        default: 0.05
        }
    }

    /// Spacing between labeled ticks in seconds. Roughly one label every
    /// ~80–100px so labels don't run together.
    private func labelStrideInterval() -> TimeInterval {
        switch pixelsPerSecond {
        case ..<30: 5
        case ..<60: 2
        case ..<120: 1
        case ..<240: 0.5
        default: 0.25
        }
    }

    private func format(time: TimeInterval) -> String {
        let total = Int(time)
        let minutes = total / 60
        let seconds = total % 60
        if pixelsPerSecond >= 240 {
            // Tight zoom: show fractional seconds.
            let frac = Int((time - floor(time)) * 100)
            return String(format: "%02d:%02d.%02d", minutes, seconds, frac)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
