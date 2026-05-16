import SwiftUI

/// Inline gain-envelope editor for an audio clip's volume keyframes.
/// Renders a thin strip showing the piecewise-linear gain curve, with
/// draggable diamond handles at each control point. Tap anywhere on the
/// strip to drop a new keyframe; right-click a handle to remove it.
///
/// Mirrors the `SpeedRampCurveView` pattern, but bidirectional — the
/// user actually edits the curve here rather than just observing it.
struct VolumeEnvelopeView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel
    let clip: Clip
    var height: CGFloat = 60

    /// Render the resolved envelope including the implicit start/end
    /// anchors so the curve always spans the full clip duration even
    /// when the user has only placed one or two keyframes in the middle.
    private var resolved: [VolumeKeyframe] {
        Clip.anchoredVolumeKeyframes(
            clip.volumeKeyframes ?? [],
            sourceDuration: clip.sourceRange.duration
        )
    }

    private var userKeyframes: [VolumeKeyframe] {
        clip.volumeKeyframes ?? []
    }

    private let maxGain: Double = 2.0  // matches the model clamp

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                background(proxy: proxy)
                curve(proxy: proxy)
                handles(proxy: proxy)
            }
            .contentShape(Rectangle())
            // Plain tap drops a new keyframe at the click point.
            // Translate the tap location into clip-local time and gain.
            .gesture(
                SpatialTapGesture()
                    .onEnded { event in
                        let time = clipTime(forX: event.location.x, width: proxy.size.width)
                        let gain = gainValue(forY: event.location.y, height: proxy.size.height)
                        model.addVolumeKeyframe(time, gain: gain, on: clip.id)
                    }
            )
        }
        .frame(height: height)
    }

    // MARK: - Layers

    private func background(proxy: GeometryProxy) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.colors.surface.opacity(0.6))
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.colors.border.opacity(0.5), lineWidth: 1)
            // Unity (1.0) baseline so the user has a visual anchor.
            let unityY = yPosition(forGain: 1.0, height: proxy.size.height)
            Path { path in
                path.move(to: CGPoint(x: 8, y: unityY))
                path.addLine(to: CGPoint(x: proxy.size.width - 8, y: unityY))
            }
            .stroke(theme.colors.border.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func curve(proxy: GeometryProxy) -> some View {
        let points = resolved.map {
            CGPoint(
                x: xPosition(forTime: $0.time, width: proxy.size.width),
                y: yPosition(forGain: $0.gain, height: proxy.size.height)
            )
        }
        let baselineY = yPosition(forGain: 1.0, height: proxy.size.height)

        return ZStack {
            // Filled area between the curve and the unity baseline, so
            // the user can see at a glance where the clip is louder or
            // quieter than its base volume.
            if points.count >= 2 {
                Path { path in
                    path.move(to: CGPoint(x: points[0].x, y: baselineY))
                    for point in points {
                        path.addLine(to: point)
                    }
                    path.addLine(to: CGPoint(x: points.last!.x, y: baselineY))
                    path.closeSubpath()
                }
                .fill(theme.colors.accent.opacity(0.15))

                Path { path in
                    path.move(to: points[0])
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(theme.colors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func handles(proxy: GeometryProxy) -> some View {
        ForEach(userKeyframes) { kf in
            let pos = CGPoint(
                x: xPosition(forTime: kf.time, width: proxy.size.width),
                y: yPosition(forGain: kf.gain, height: proxy.size.height)
            )
            VolumeHandle(
                isHovered: false,
                onDrag: { translation in
                    let newX = max(0, min(proxy.size.width, pos.x + translation.width))
                    let newY = max(0, min(proxy.size.height, pos.y + translation.height))
                    let newTime = clipTime(forX: newX, width: proxy.size.width)
                    let newGain = gainValue(forY: newY, height: proxy.size.height)
                    model.updateVolumeKeyframe(kf.id, on: clip.id, time: newTime, gain: newGain)
                },
                onDelete: {
                    model.removeVolumeKeyframe(kf.id, on: clip.id)
                }
            )
            .position(pos)
        }
    }

    // MARK: - Mapping

    private func xPosition(forTime time: TimeInterval, width: CGFloat) -> CGFloat {
        let duration = max(0.001, clip.sourceRange.duration)
        let inset: CGFloat = 8
        let normalized = CGFloat(time / duration)
        return inset + normalized * max(0, width - inset * 2)
    }

    private func clipTime(forX x: CGFloat, width: CGFloat) -> TimeInterval {
        let inset: CGFloat = 8
        let span = max(1, width - inset * 2)
        let normalized = (x - inset) / span
        return Double(max(0, min(1, normalized))) * clip.sourceRange.duration
    }

    private func yPosition(forGain gain: Double, height: CGFloat) -> CGFloat {
        let inset: CGFloat = 8
        let usable = max(1, height - inset * 2)
        // Higher gain → smaller y (top of the view), per SwiftUI's
        // top-left origin convention.
        let normalized = gain / maxGain
        return inset + (1 - CGFloat(normalized)) * usable
    }

    private func gainValue(forY y: CGFloat, height: CGFloat) -> Double {
        let inset: CGFloat = 8
        let usable = max(1, height - inset * 2)
        let normalized = 1 - ((y - inset) / usable)
        return Double(max(0, min(1, normalized))) * maxGain
    }
}

/// Draggable diamond handle for a keyframe. Right-click → delete. Drag →
/// reposition (time + gain). Tap → no-op (parent handles tap to *add*).
private struct VolumeHandle: View {
    @Environment(\.theme) private var theme
    let isHovered: Bool
    let onDrag: (CGSize) -> Void
    let onDelete: () -> Void

    @State private var dragOffset: CGSize?

    var body: some View {
        Rectangle()
            .fill(theme.colors.accent)
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(45))
            .overlay(
                Rectangle()
                    .stroke(.white, lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(45))
            )
            .shadow(color: theme.colors.accent.opacity(0.4), radius: 3)
            .contentShape(Rectangle().inset(by: -6))  // big enough hit area
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // Drag fires on every move; forward the cumulative
                        // translation so the parent maps it to time/gain
                        // each tick.
                        onDrag(value.translation)
                    }
            )
            .contextMenu {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Keyframe", systemImage: "trash")
                }
            }
    }
}
