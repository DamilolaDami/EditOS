import SwiftUI

struct TimelinePlayhead: View {
    @Environment(\.theme) private var theme
    let time: TimeInterval
    let pixelsPerSecond: CGFloat
    let duration: TimeInterval
    var onScrub: (TimeInterval) -> Void = { _ in }

    @State private var isScrubbing: Bool = false

    private let handleSize: CGFloat = 20
    private let hitPadding: CGFloat = 10

    var body: some View {
        ZStack(alignment: .top) {
            // Vertical guide line. allowsHitTesting(false) so taps on the line
            // fall through to clips (parent panel handles scrubbing anyway).
            Rectangle()
                .fill(theme.colors.accent)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

            VStack(spacing: 2) {
                // Time pill — CapCut-style live readout that pops while the
                // user scrubs and fades back to a subtle badge at rest.
                Text(format(time: time))
                    .font(theme.typography.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.colors.accent, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .opacity(isScrubbing ? 1 : 0.85)
                    .scaleEffect(isScrubbing ? 1.05 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: isScrubbing)
                    .allowsHitTesting(false)

                // Grab handle — also draggable on top of the parent's simultaneous
                // scrub gesture, so it works as a dedicated affordance.
                Circle()
                    .fill(theme.colors.accent)
                    .frame(width: handleSize, height: handleSize)
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(hitPadding)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        // Explicit set() rather than push/pop — push/pop can drift
                        // when hover events overlap with other interactive views,
                        // leaving the cursor stuck in the wrong state.
                        if hovering {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .highPriorityGesture(
                        DragGesture(
                            minimumDistance: 0,
                            coordinateSpace: .named(TimelineCoordinateSpace.name)
                        )
                        .onChanged { value in
                            isScrubbing = true
                            let t = max(0, Double(value.location.x / pixelsPerSecond))
                            onScrub(min(t, duration))
                        }
                        .onEnded { _ in
                            isScrubbing = false
                        }
                    )
                    .help("Drag to scrub")
            }
        }
        // Center the handle assembly on the playhead's time.
        .offset(x: CGFloat(time) * pixelsPerSecond - (handleSize / 2 + hitPadding))
    }

    private func format(time: TimeInterval) -> String {
        let total = max(0, time)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let frames = Int((total - floor(total)) * 30)
        return String(format: "%02d:%02d.%02d", minutes, seconds, frames)
    }
}

enum TimelineCoordinateSpace {
    static let name = "EditOS.timeline"
}
