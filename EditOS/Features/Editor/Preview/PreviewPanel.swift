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
                .contentShape(Rectangle())
                // Tapping in the preview area (anywhere outside the timeline)
                // clears the current clip selection — matches CapCut's "tap
                // out to deselect" behaviour.
                .onTapGesture {
                    if model.selectedClipID != nil {
                        model.selectClip(nil)
                    }
                }
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
            aspectRatioMenu
            Button {} label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.textSecondary)
        }
        .padding(.horizontal, theme.spacing.md)
        .padding(.vertical, theme.spacing.sm)
    }

    /// Quick aspect ratio switcher — picks the matching long-edge resolution
    /// so 16:9 → 1920×1080, 9:16 → 1080×1920, etc. Keeping the long edge at
    /// 1920 keeps export presets meaningful.
    private var aspectRatioMenu: some View {
        Menu {
            ForEach(AspectChoice.allCases, id: \.self) { choice in
                Button {
                    model.setCanvasSize(choice.size)
                } label: {
                    Label(choice.label, systemImage: choice.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentAspectChoice.symbol)
                Text(currentAspectChoice.label)
                    .font(theme.typography.caption)
            }
            .foregroundStyle(theme.colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(theme.colors.surfaceElevated, in: RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 78)
        .help("Aspect ratio")
    }

    private var currentAspectChoice: AspectChoice {
        let size = model.project.canvas.size
        guard size.height > 0 else { return .widescreen16x9 }
        let ratio = size.width / size.height
        return AspectChoice.allCases.min { a, b in
            abs(a.ratio - ratio) < abs(b.ratio - ratio)
        } ?? .widescreen16x9
    }

    private var canvasLabel: String {
        "\(Int(model.project.canvas.size.width)) × \(Int(model.project.canvas.size.height))"
    }

    private var framedPreview: some View {
        PreviewSurface(player: model.playback.player)
            .aspectRatio(canvasAspect, contentMode: .fit)
            .background(Color.black)
            .overlay {
                OverlayCanvas(model: model)
            }
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

private enum AspectChoice: CaseIterable, Hashable {
    case widescreen16x9
    case vertical9x16
    case square1x1
    case portrait4x5

    var label: String {
        switch self {
        case .widescreen16x9: return "16:9"
        case .vertical9x16:   return "9:16"
        case .square1x1:      return "1:1"
        case .portrait4x5:    return "4:5"
        }
    }

    var symbol: String {
        switch self {
        case .widescreen16x9: return "rectangle"
        case .vertical9x16:   return "rectangle.portrait"
        case .square1x1:      return "square"
        case .portrait4x5:    return "rectangle.portrait.fill"
        }
    }

    var ratio: CGFloat {
        switch self {
        case .widescreen16x9: return 16.0 / 9.0
        case .vertical9x16:   return 9.0 / 16.0
        case .square1x1:      return 1.0
        case .portrait4x5:    return 4.0 / 5.0
        }
    }

    /// Canvas size at this aspect, with the long edge at 1920 to keep the
    /// HD / 4K export presets aligned.
    var size: CGSize {
        switch self {
        case .widescreen16x9: return CGSize(width: 1920, height: 1080)
        case .vertical9x16:   return CGSize(width: 1080, height: 1920)
        case .square1x1:      return CGSize(width: 1080, height: 1080)
        case .portrait4x5:    return CGSize(width: 1080, height: 1350)
        }
    }
}

/// Renders text and sticker overlay clips active at the current playhead time
/// on top of the player view. Each overlay is independently selectable,
/// movable (drag body) and resizable (drag corner handle) — clicks on
/// empty space fall through to the parent so tap-out-to-deselect still works.
private struct OverlayCanvas: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        GeometryReader { proxy in
            let canvas = model.project.canvas.size
            let scale = canvas.width > 0 && canvas.height > 0
                ? min(proxy.size.width / canvas.width, proxy.size.height / canvas.height)
                : 1.0
            ZStack {
                ForEach(activeOverlays, id: \.id) { clip in
                    OverlayItem(
                        clip: clip,
                        canvasScale: scale,
                        isSelected: model.selectedClipID == clip.id,
                        onSelectAndPause: {
                            model.selectClip(clip.id)
                            model.playback.pause()
                        },
                        onMoveCommit: { canvasDelta in
                            model.updateClip(clip.id) { c in
                                c.transform.translation = CGSize(
                                    width: c.transform.translation.width + canvasDelta.width,
                                    height: c.transform.translation.height + canvasDelta.height
                                )
                            }
                        },
                        onResizeCommit: { newSize in
                            model.updateClip(clip.id) { c in
                                c.overlaySize = max(16, newSize)
                            }
                        }
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var activeOverlays: [Clip] {
        let t = model.playback.currentTime
        var clips: [Clip] = []
        for track in model.project.timeline.tracks where !track.isHidden {
            switch track.kind {
            case .caption, .sticker, .overlay:
                clips.append(contentsOf: track.clips.filter { $0.timeRange.contains(t) })
            default:
                continue
            }
        }
        return clips
    }
}

/// One overlay clip rendered on the preview canvas. Handles its own select /
/// move / resize gestures and shows a dashed selection box when selected.
private struct OverlayItem: View {
    @Environment(\.theme) private var theme
    let clip: Clip
    let canvasScale: CGFloat
    let isSelected: Bool
    let onSelectAndPause: () -> Void
    let onMoveCommit: (CGSize) -> Void
    let onResizeCommit: (CGFloat) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGFloat = 0

    private let handleDiameter: CGFloat = 12

    var body: some View {
        let baseSize = clip.overlaySize ?? (clip.text != nil ? 64 : 96)
        let canvasSize = max(16, baseSize + resizeDelta)
        let tx = clip.transform.translation.width * canvasScale + dragOffset.width
        let ty = clip.transform.translation.height * canvasScale + dragOffset.height

        // Content sizes to its own intrinsic bounds — fixed-size frames clip
        // text overlays. The selection box reads back the content size via
        // an overlay GeometryReader so handles always sit on the corners of
        // the rendered glyphs / image, not on an arbitrary square.
        content(canvasSize: canvasSize)
            .fixedSize()
            .contentShape(Rectangle())
            .overlay {
                if isSelected {
                    GeometryReader { proxy in
                        selectionBox(size: proxy.size)
                    }
                }
            }
            .offset(x: tx, y: ty)
            .onTapGesture { onSelectAndPause() }
            .simultaneousGesture(
                // Body drag — selects on first touch, then commits the
                // canvas-space delta on release. Local dragOffset gives
                // live feedback.
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if !isSelected { onSelectAndPause() }
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        let delta = CGSize(
                            width: value.translation.width / max(0.001, canvasScale),
                            height: value.translation.height / max(0.001, canvasScale)
                        )
                        dragOffset = .zero
                        onMoveCommit(delta)
                    }
            )
    }

    @ViewBuilder
    private func content(canvasSize: CGFloat) -> some View {
        let color = swiftUIColor(clip.foregroundColor ?? .white)
        let renderPt = max(8, canvasSize * canvasScale)
        Group {
            if let text = clip.text {
                Text(text)
                    .font(.system(size: renderPt, weight: .bold))
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            } else if let path = clip.stickerImagePath {
                StickerFileImage(path: path, size: renderPt)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            } else if let symbol = clip.stickerSymbol {
                Image(systemName: symbol)
                    .font(.system(size: renderPt, weight: .bold))
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            }
        }
        .opacity(clip.transform.opacity)
        .rotationEffect(.radians(clip.transform.rotation))
        .scaleEffect(clip.transform.scale)
    }

    private func selectionBox(size: CGSize) -> some View {
        ZStack {
            Rectangle()
                .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            // Four visual dots at each corner.
            ForEach(0..<4, id: \.self) { idx in
                let isResize = idx == 3  // bottom-right is the active resize handle
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(theme.colors.accent, lineWidth: 1.5))
                    .frame(width: handleDiameter, height: handleDiameter)
                    .position(handlePosition(for: idx, in: size))
                    .allowsHitTesting(isResize)
                    .gesture(
                        isResize
                        ? DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let avg = (value.translation.width + value.translation.height) / 2
                                resizeDelta = avg / max(0.001, canvasScale)
                            }
                            .onEnded { value in
                                let avg = (value.translation.width + value.translation.height) / 2
                                let delta = avg / max(0.001, canvasScale)
                                let base = clip.overlaySize ?? 64
                                resizeDelta = 0
                                onResizeCommit(base + delta)
                            }
                        : nil
                    )
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func handlePosition(for index: Int, in size: CGSize) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: 0, y: 0)                          // top-leading
        case 1: return CGPoint(x: size.width, y: 0)                 // top-trailing
        case 2: return CGPoint(x: 0, y: size.height)                // bottom-leading
        default: return CGPoint(x: size.width, y: size.height)      // bottom-trailing
        }
    }

    private func swiftUIColor(_ rgba: ColorRGBA) -> Color {
        Color(red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

/// Loads a GIF / PNG / WebP sticker from disk once per path change and
/// renders the first decoded frame. Doing the load inside a `.task(id:)`
/// keeps each render cheap when the playhead ticks. File-scope so both the
/// preview canvas and the timeline cell can use the same cached view.
struct StickerFileImage: View {
    let path: String
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: max(8, size), height: max(8, size))
        .task(id: path) {
            image = NSImage(contentsOfFile: path)
        }
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
