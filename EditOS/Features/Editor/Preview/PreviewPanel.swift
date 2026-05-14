import SwiftUI
import AVKit

struct PreviewPanel: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel

    var body: some View {
        EditorPanel {
            VStack(spacing: 0) {
                header
                Divider().overlay(theme.colors.border)
                ZStack {
                    theme.colors.background
                    framedPreview
                        .padding(theme.spacing.lg)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(theme.colors.border)
                PreviewControls(model: model)
            }
        }
    }

    private var header: some View {
        HStack(spacing: theme.spacing.md) {
            Text("Player")
                .font(theme.typography.title)
                .foregroundStyle(theme.colors.textPrimary)
            Text(canvasLabel)
                .font(theme.typography.caption.monospacedDigit())
                .foregroundStyle(theme.colors.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.colors.surfaceElevated, in: Capsule())
            Spacer()
            Button {} label: {
                Image(systemName: "rectangle.ratio.4.to.3")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.textSecondary)
            Button {} label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.textSecondary)
        }
        .padding(.horizontal, theme.spacing.md)
        .padding(.vertical, theme.spacing.sm)
    }

    private var canvasLabel: String {
        "\(Int(model.project.canvas.size.width)) × \(Int(model.project.canvas.size.height))"
    }

    private var framedPreview: some View {
        PreviewSurface(player: model.playback.player)
            .aspectRatio(canvasAspect, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.sm)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
    }

    private var canvasAspect: CGFloat {
        let size = model.project.canvas.size
        guard size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }
}

private struct PreviewSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private struct PreviewControls: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel

    var body: some View {
        HStack(spacing: theme.spacing.md) {
            timeReadout(model.playback.currentTime)
                .font(theme.typography.displayMono)
                .foregroundStyle(theme.colors.textPrimary)
            Text("/")
                .foregroundStyle(theme.colors.textTertiary)
            timeReadout(model.playback.duration)
                .font(theme.typography.displayMono)
                .foregroundStyle(theme.colors.textSecondary)
            Spacer()
            TransportButton(systemImage: "backward.end.fill") {
                model.playback.seek(to: 0)
            }
            TransportButton(
                systemImage: model.playback.isPlaying ? "pause.fill" : "play.fill",
                isPrimary: true
            ) {
                model.playback.togglePlayback()
            }
            TransportButton(systemImage: "forward.end.fill") {
                model.playback.seek(to: model.playback.duration)
            }
            Spacer()
            Text("EditOS")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .opacity(0)  // keeps the controls visually centered
        }
        .padding(.horizontal, theme.spacing.md)
        .padding(.vertical, theme.spacing.sm)
    }

    private func timeReadout(_ seconds: TimeInterval) -> Text {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        let frames = Int((seconds - floor(seconds)) * 30)
        return Text(String(format: "%02d:%02d:%02d.%02d", hours, minutes, secs, frames))
    }
}

private struct TransportButton: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    var isPrimary: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isPrimary ? 16 : 13, weight: .medium))
                .foregroundStyle(isPrimary ? .white : theme.colors.textPrimary)
                .frame(width: isPrimary ? 36 : 28, height: isPrimary ? 36 : 28)
                .background(
                    Circle().fill(
                        isPrimary
                            ? (isHovering ? theme.colors.accent.opacity(0.95) : theme.colors.accent)
                            : (isHovering ? theme.colors.surfaceElevated : Color.clear)
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}
