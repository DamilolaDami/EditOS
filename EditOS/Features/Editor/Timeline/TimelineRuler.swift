import SwiftUI

struct TimelineRuler: View {
    @Environment(\.theme) private var theme
    let duration: TimeInterval
    let pixelsPerSecond: CGFloat
    var onScrub: (TimeInterval) -> Void = { _ in }

    private let height: CGFloat = 40
    private let labelLineHeight: CGFloat = 20

    var body: some View {
        Canvas { context, size in
            let stride = tickStride()
            let tickCount = Int(ceil(duration / stride))
            for index in 0...tickCount {
                let time = Double(index) * stride
                let x = CGFloat(time) * pixelsPerSecond
                let isMajor = index % 5 == 0
                let tickLength: CGFloat = isMajor ? 12 : 6

                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - tickLength))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    path,
                    with: .color(isMajor ? theme.colors.textSecondary : theme.colors.border),
                    lineWidth: 1
                )

                if isMajor {
                    let label = Text(format(time: time))
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                    context.draw(label, at: CGPoint(x: x + 4, y: 2), anchor: .topLeading)
                }
            }
        }
        .frame(width: CGFloat(duration) * pixelsPerSecond, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let time = max(0, Double(value.location.x / pixelsPerSecond))
                    onScrub(min(time, duration))
                }
        )
    }

    private func tickStride() -> TimeInterval {
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
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
