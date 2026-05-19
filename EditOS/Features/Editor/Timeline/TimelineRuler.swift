import SwiftUI

struct TimelineRuler: View {
    @Environment(\.theme) private var theme
    let duration: TimeInterval
    let pixelsPerSecond: CGFloat
    /// Beat positions in project-time seconds — drawn full-height with
    /// a filled accent dot on top so they read as a rhythm grid against
    /// the dimmer time-scale ticks below.
    var beats: [TimeInterval] = []
    var onScrub: (TimeInterval) -> Void = { _ in }

    /// 0…1 sweep progress for the beat-reveal animation. Animated from
    /// 0 → 1 over ~0.7s every time the beat array transitions from empty
    /// (or from one detection to a fresh one), so a freshly-detected
    /// rhythm grid sweeps in left-to-right instead of just appearing.
    @State private var beatRevealProgress: Double = 1.0
    /// Count tracked locally so `.onChange` can distinguish "user
    /// just ran detection" from "project loaded with beats already".
    @State private var lastBeatCount: Int = 0

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

                // Beat ticks — full ruler height with a filled accent
                // dot on top. The reveal-progress acts as a left-to-
                // right cutoff so newly-detected beats sweep in. Skipped
                // at zoom levels where adjacent beats would render < 2
                // px apart (visual soup that hurts more than it helps).
                let beatSpacing = beatRenderSpacing()
                if beatSpacing >= 2 && !beats.isEmpty {
                    let accent = theme.colors.accent
                    let lineColor = accent.opacity(0.45)
                    let dotColor = accent
                    let revealCutoff = max(0, duration) * beatRevealProgress
                    let dotRadius: CGFloat = 2.5
                    for time in beats where time >= 0 && time <= duration {
                        guard time <= revealCutoff else { continue }
                        let x = CGFloat(time) * pixelsPerSecond
                        // Vertical guide from just below the dot to
                        // just above the time-scale ticks.
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: 6))
                        line.addLine(to: CGPoint(x: x, y: size.height - 14))
                        context.stroke(line, with: .color(lineColor), lineWidth: 1)
                        // Accent dot on top — the visual anchor that
                        // catches the eye when the user first sees them.
                        let dot = CGRect(
                            x: x - dotRadius,
                            y: 1,
                            width: dotRadius * 2,
                            height: dotRadius * 2
                        )
                        context.fill(Path(ellipseIn: dot), with: .color(dotColor))
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
        .onAppear {
            // Project loaded with beats already present — show them
            // immediately, don't replay the intro sweep every reopen.
            lastBeatCount = beats.count
            beatRevealProgress = 1.0
        }
        .onChange(of: beats.count) { _, newCount in
            // Animate the sweep only when *detection* changed the count
            // (empty → some, or one set replaced by another). Clearing
            // beats just hides them instantly so the next detection
            // gets a clean intro.
            if newCount > 0 && newCount != lastBeatCount {
                beatRevealProgress = 0
                withAnimation(.easeOut(duration: 0.7)) {
                    beatRevealProgress = 1
                }
            } else if newCount == 0 {
                beatRevealProgress = 1
            }
            lastBeatCount = newCount
        }
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

    /// Median pixel distance between consecutive beats. Used to decide
    /// whether drawing beat ticks would just smear into a solid line at
    /// the current zoom. Returns 0 when there's nothing to draw.
    private func beatRenderSpacing() -> CGFloat {
        guard beats.count > 1 else { return beats.isEmpty ? 0 : .infinity }
        var deltas: [CGFloat] = []
        deltas.reserveCapacity(beats.count - 1)
        for i in 1..<beats.count {
            deltas.append(CGFloat(beats[i] - beats[i - 1]) * pixelsPerSecond)
        }
        let sorted = deltas.sorted()
        return sorted[sorted.count / 2]
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
