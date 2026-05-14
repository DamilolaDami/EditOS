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
                PreviewSurface(player: model.playback.player, canvas: model.project.canvas)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(theme.colors.border)
                PreviewControls(model: model)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Player")
                .font(theme.typography.title)
                .foregroundStyle(theme.colors.textPrimary)
            Spacer()
            Menu {
                Text("Ratio").font(theme.typography.caption)
            } label: {
                Image(systemName: "rectangle.ratio.4.to.3")
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(theme.colors.textSecondary)
        }
        .padding(theme.spacing.sm)
    }
}

private struct PreviewSurface: NSViewRepresentable {
    let player: AVPlayer
    let canvas: CanvasFormat

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
                .foregroundStyle(theme.colors.textSecondary)
            timeReadout(model.playback.duration)
                .font(theme.typography.displayMono)
                .foregroundStyle(theme.colors.textSecondary)
            Spacer()
            Button {
                model.playback.seek(to: 0)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            Button {
                model.playback.togglePlayback()
            } label: {
                Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .medium))
            }
            Button {
                model.playback.seek(to: model.playback.duration)
            } label: {
                Image(systemName: "forward.end.fill")
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.colors.textPrimary)
        .padding(theme.spacing.sm)
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
