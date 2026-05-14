import SwiftUI

struct TimelinePlayhead: View {
    @Environment(\.theme) private var theme
    let time: TimeInterval
    let pixelsPerSecond: CGFloat
    let duration: TimeInterval
    var onScrub: (TimeInterval) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .top) {
            // Vertical guide line — non-interactive so clicks fall through to clips.
            Rectangle()
                .fill(theme.colors.accent)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

            // Grab handle — big enough to easily click/drag, with a glyph so it
            // reads as interactive.
            Circle()
                .fill(theme.colors.accent)
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(6) // expands the hit target
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineCoordinateSpace.name))
                        .onChanged { value in
                            let t = max(0, Double(value.location.x / pixelsPerSecond))
                            onScrub(min(t, duration))
                        }
                )
                .help("Drag to scrub")
        }
        // Center the 30-wide handle assembly on the playhead's time.
        .offset(x: CGFloat(time) * pixelsPerSecond - 15)
    }
}

enum TimelineCoordinateSpace {
    static let name = "EditOS.timeline"
}
