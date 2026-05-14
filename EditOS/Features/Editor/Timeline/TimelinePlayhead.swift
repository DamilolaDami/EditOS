import SwiftUI

struct TimelinePlayhead: View {
    @Environment(\.theme) private var theme
    let time: TimeInterval
    let pixelsPerSecond: CGFloat
    let duration: TimeInterval
    var onScrub: (TimeInterval) -> Void = { _ in }

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
                        let t = max(0, Double(value.location.x / pixelsPerSecond))
                        onScrub(min(t, duration))
                    }
                )
                .help("Drag to scrub")
        }
        // Center the handle assembly on the playhead's time.
        .offset(x: CGFloat(time) * pixelsPerSecond - (handleSize / 2 + hitPadding))
    }
}

enum TimelineCoordinateSpace {
    static let name = "EditOS.timeline"
}
