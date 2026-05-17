import AppKit
import ScreenCaptureKit
import SwiftUI

/// Full-screen overlay shown before recording starts. Three modes:
///
/// - **Full** — the entire display is the capture target.
/// - **Window** — hovering over an on-screen window highlights it;
///   click locks the selection.
/// - **Region** — drag anywhere to draw a rectangle.
///
/// The bottom floating bar mirrors CapCut / Screen Studio's design:
/// dimensions readout on the left, mic toggle in the middle, big red
/// Start button on the right. Esc cancels.
struct SelectionOverlay: View {
    @Environment(\.theme) private var theme

    let content: SCShareableContent?
    /// Display bounds in display-local pixels — used to derive the
    /// capture `sourceRect` when the user is in Region mode.
    let displayBounds: CGRect
    let onCancel: () -> Void
    /// `screenRect` is the SwiftUI-space rectangle (top-left origin,
    /// points — not pixels) so the coordinator can position its
    /// recording-active dim overlay over the same area without
    /// re-doing the display-pixel ↔ screen-point conversion.
    let onConfirm: (RecorderTarget, _ includeMicrophone: Bool, _ screenRect: CGRect?) -> Void

    @State private var mode: Mode = .region
    @State private var includeMicrophone: Bool = true

    /// User's draft rectangle in *screen* (AppKit) coordinates. Lives
    /// here so dragging is responsive; converted to display-local
    /// pixels only when the user confirms.
    @State private var draftRect: CGRect = .zero
    /// Snapshot of `draftRect` at the start of a move-or-resize drag.
    /// All in-flight resize math derives from this anchor so the user's
    /// cumulative `translation` value maps deterministically.
    @State private var dragAnchor: CGRect?
    /// Picked window in Window mode (nil until the user chooses one).
    @State private var selectedWindow: SCWindow?

    /// Smallest allowable rectangle. Anything smaller can't be seen,
    /// and SCStream rejects sourceRects under a few pixels.
    private let minimumSize: CGFloat = 60

    enum Mode: String, CaseIterable, Identifiable {
        case full, window, region
        var id: String { rawValue }
        var label: String {
            switch self {
            case .full:   return "Full"
            case .window: return "Window"
            case .region: return "Region"
            }
        }
        var systemImage: String {
            switch self {
            case .full:   return "rectangle.inset.filled"
            case .window: return "macwindow"
            case .region: return "rectangle.dashed"
            }
        }
    }

    var body: some View {
        ZStack {
            // Dim layer covers the full screen. The selected rectangle
            // gets "cut" out via mask so the underlying screen content
            // shows through clearly — classic Screen Studio aesthetic.
            dimMask

            // Selection rectangle stroke + dimensions label.
            if let rect = selectionRectForDisplay {
                selectionFrame(rect: rect)
            }

            // Top-center: mode picker.
            VStack {
                modePicker
                    .padding(.top, 24)
                Spacer()
                controlsBar
                    .padding(.bottom, 36)
            }
        }
        // No outer drag gesture — that was hijacking touches from the
        // resize handles and the move-inside-the-rect gesture. The
        // rect's own gestures handle everything now; to "draw a fresh
        // rect" the user picks Region mode again or hits the Reset
        // chip in the controls bar.
        .onChange(of: mode) { _, newMode in
            applyMode(newMode)
        }
        .onAppear {
            // SwiftUI uses top-left origin inside the overlay window;
            // NSScreen uses bottom-left. Stay in screen-size land and
            // build the default rect from the size, not from
            // `screen.frame` directly.
            let size = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
            switch mode {
            case .region:
                let w: CGFloat = min(800, size.width * 0.6)
                let h: CGFloat = min(500, size.height * 0.6)
                draftRect = CGRect(
                    x: (size.width - w) / 2,
                    y: (size.height - h) / 2,
                    width: w,
                    height: h
                )
            case .full:
                draftRect = CGRect(origin: .zero, size: size)
            case .window:
                break
            }
        }
        .background(KeyEventCatcher(onEscape: onCancel))
    }

    // MARK: - Layers

    private var dimMask: some View {
        // Cut the selection rectangle out of the dim using the even-odd
        // fill rule so everything outside the selection is dimmed and
        // the inside is fully transparent.
        GeometryReader { proxy in
            Path { path in
                path.addRect(proxy.frame(in: .local))
                if let rect = selectionRectForDisplay {
                    path.addRect(rect)
                }
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true, antialiased: true))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func selectionFrame(rect: CGRect) -> some View {
        ZStack {
            // White-outlined selection rectangle. The Color.clear fill
            // under the stroke gives the gesture a hit-test area that
            // covers the entire rect interior so the user can grab
            // anywhere inside to translate the selection.
            ZStack {
                Color.clear
                Rectangle()
                    .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 2))
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle())
            // highPriority so this beats any default gesture SwiftUI
            // would otherwise resolve at the parent ZStack level.
            .highPriorityGesture(moveGesture)
            .onHover { hovering in
                if hovering { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }

            // Top-anchored dimensions pill.
            Text("\(Int(rect.width)) × \(Int(rect.height))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.7), in: Capsule())
                .position(x: rect.midX, y: max(20, rect.minY - 18))
                .allowsHitTesting(false)

            // Eight resize handles — four corners + four edge midpoints.
            // Each carries its own anchor handle gesture so the user
            // can grab any edge / corner and resize from there.
            ForEach(Handle.allCases, id: \.self) { handle in
                ResizeHandle(handle: handle, rect: rect, onDrag: applyResize)
            }
        }
    }

    /// Translate the entire rectangle when the user drags inside it.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragAnchor == nil { dragAnchor = draftRect }
                guard let anchor = dragAnchor else { return }
                let screenSize = NSScreen.main?.frame.size ?? .zero
                let newOrigin = CGPoint(
                    x: max(0, min(screenSize.width - anchor.width,
                                  anchor.minX + value.translation.width)),
                    y: max(0, min(screenSize.height - anchor.height,
                                  anchor.minY + value.translation.height))
                )
                draftRect = CGRect(origin: newOrigin, size: anchor.size)
            }
            .onEnded { _ in dragAnchor = nil }
    }

    /// Apply a per-handle resize. `handle` says which corner / edge is
    /// being dragged; `translation` is the cumulative drag since touch
    /// down. The math is a switch on each anchor point — fewer special
    /// cases than they look, since most edges fix two sides and move
    /// the other two.
    private func applyResize(_ handle: Handle, translation: CGSize, beganAt anchor: CGRect) {
        let screenSize = NSScreen.main?.frame.size ?? .zero
        var minX = anchor.minX
        var minY = anchor.minY
        var maxX = anchor.maxX
        var maxY = anchor.maxY

        switch handle {
        case .topLeft:
            minX += translation.width
            minY += translation.height
        case .top:
            minY += translation.height
        case .topRight:
            maxX += translation.width
            minY += translation.height
        case .right:
            maxX += translation.width
        case .bottomRight:
            maxX += translation.width
            maxY += translation.height
        case .bottom:
            maxY += translation.height
        case .bottomLeft:
            minX += translation.width
            maxY += translation.height
        case .left:
            minX += translation.width
        }

        // Clamp inside the screen and enforce the minimum size by
        // pushing the moving edge back toward the fixed one.
        minX = max(0, min(maxX - minimumSize, minX))
        minY = max(0, min(maxY - minimumSize, minY))
        maxX = min(screenSize.width, max(minX + minimumSize, maxX))
        maxY = min(screenSize.height, max(minY + minimumSize, maxY))

        draftRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight
        case right
        case bottomRight, bottom, bottomLeft
        case left
    }

    /// Reset the rect when the user picks a different mode so each
    /// mode has a sensible starting state.
    private func applyMode(_ newMode: Mode) {
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        switch newMode {
        case .full:
            draftRect = CGRect(origin: .zero, size: size)
            selectedWindow = nil
        case .region:
            let w: CGFloat = min(800, size.width * 0.6)
            let h: CGFloat = min(500, size.height * 0.6)
            draftRect = CGRect(
                x: (size.width - w) / 2,
                y: (size.height - h) / 2,
                width: w,
                height: h
            )
            selectedWindow = nil
        case .window:
            // Clear the rect; the actual rectangle gets snapped to the
            // window the user picks from the dropdown.
            selectedWindow = nil
            draftRect = .zero
        }
    }

    /// Snap the rect to a window's screen-space frame so the user can
    /// confirm visually before hitting Start.
    private func selectWindow(_ window: SCWindow) {
        selectedWindow = window
        // SCWindow.frame is in screen coordinates with origin
        // top-left at the menu bar — same as our SwiftUI overlay.
        draftRect = window.frame
    }

    /// On-screen, non-system windows the user might want to record.
    /// Filtered to ones with a visible title + reasonable size so the
    /// menu isn't cluttered with tooltips / menubar items.
    private var pickableWindows: [SCWindow] {
        guard let windows = content?.windows else { return [] }
        return windows.filter { window in
            window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width > 100
                && window.frame.height > 60
                && window.owningApplication?.applicationName != "EditOS"
        }.sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases) { kind in
                ModeChip(
                    label: kind.label,
                    systemImage: kind.systemImage,
                    isSelected: mode == kind
                ) {
                    mode = kind
                }
            }
        }
        .padding(4)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            // Cancel
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)")

            Divider().frame(height: 16).overlay(.white.opacity(0.18))

            // Mic toggle
            Button {
                includeMicrophone.toggle()
            } label: {
                Image(systemName: includeMicrophone ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(includeMicrophone ? .white : .white.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help(includeMicrophone ? "Microphone is on" : "Microphone is off")

            // Window picker — only visible in Window mode. Pops a menu
            // of the on-screen windows so the user can snap the rect
            // to one of them.
            if mode == .window {
                Menu {
                    if pickableWindows.isEmpty {
                        Button("No pickable windows") {}.disabled(true)
                    } else {
                        ForEach(pickableWindows, id: \.windowID) { window in
                            Button {
                                selectWindow(window)
                            } label: {
                                let app = window.owningApplication?.applicationName ?? "Window"
                                let title = window.title?.isEmpty == false ? window.title! : "Untitled"
                                Text("\(app) — \(title)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11, weight: .semibold))
                        Text(selectedWindow.map { window in
                            window.owningApplication?.applicationName ?? "Window"
                        } ?? "Choose window")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
                    .frame(maxWidth: 220)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            // Reset region — only shown in Region mode, lets the user
            // bail on a current rect and start fresh.
            if mode == .region {
                Button {
                    applyMode(.region)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Reset region")
            }

            Spacer().frame(width: 8)

            // Start
            Button {
                if let target = resolveTarget() {
                    onConfirm(target, includeMicrophone, screenRectForOverlay)
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                    Text("Start recording")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color(red: 0.95, green: 0.32, blue: 0.32))
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(resolveTarget() == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.75), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    // MARK: - Selection geometry

    /// The current selection rectangle in *display* coordinates (screen-
    /// origin top-left, matching what the dim mask draws). Returns nil
    /// when nothing has been picked yet.
    private var selectionRectForDisplay: CGRect? {
        guard draftRect.width > 1, draftRect.height > 1 else { return nil }
        return draftRect
    }

    /// Screen-space (top-left origin, points) rectangle to highlight in
    /// the recording-active overlay. `nil` for `.full` mode (the
    /// overlay draws a perimeter glow instead of a cut-out).
    private var screenRectForOverlay: CGRect? {
        switch mode {
        case .full:    return nil
        case .window:  return selectedWindow?.frame
        case .region:  return draftRect.width > 4 && draftRect.height > 4 ? draftRect : nil
        }
    }

    private func resolveTarget() -> RecorderTarget? {
        guard let display = content?.displays.first else { return nil }
        switch mode {
        case .full:
            return .fullDisplay(display)
        case .window:
            // SCContentFilter wants the window itself, not a region.
            guard let window = selectedWindow else { return nil }
            return .window(window)
        case .region:
            // Convert the SwiftUI rectangle into display-local pixels.
            // SwiftUI inside the overlay uses top-left origin; SCStream
            // `sourceRect` is also top-left origin in display pixels.
            // Multiply by the screen's backing scale for the 1:1 map
            // on a single primary monitor; multi-monitor lives in a
            // follow-up.
            guard let screen = NSScreen.main, draftRect.width > 4, draftRect.height > 4 else {
                return nil
            }
            let scale = screen.backingScaleFactor
            let pixels = CGRect(
                x: draftRect.minX * scale,
                y: draftRect.minY * scale,
                width: draftRect.width * scale,
                height: draftRect.height * scale
            )
            return .region(display, pixels)
        }
    }
}

/// Small white circle that sits on a corner or edge of the selection
/// rectangle and resizes it when dragged. Each one knows which handle
/// it represents and forwards the drag's cumulative translation to the
/// parent's resize math.
private struct ResizeHandle: View {
    let handle: SelectionOverlay.Handle
    let rect: CGRect
    let onDrag: (SelectionOverlay.Handle, CGSize, CGRect) -> Void

    @State private var anchor: CGRect?

    /// 14pt hit area, 10pt visual. Big enough to grab comfortably but
    /// not so big that the handles collide on a tiny rectangle.
    private let visualSize: CGFloat = 10
    private let hitSize: CGFloat = 22

    var body: some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
            .frame(width: visualSize, height: visualSize)
            .frame(width: hitSize, height: hitSize)  // larger invisible hit area
            .contentShape(Circle().inset(by: -6))
            .position(position)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if anchor == nil { anchor = rect }
                        guard let anchor else { return }
                        onDrag(handle, value.translation, anchor)
                    }
                    .onEnded { _ in anchor = nil }
            )
            .onHover { hovering in
                if hovering {
                    cursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }

    /// Compute where the handle sits on the rectangle.
    private var position: CGPoint {
        switch handle {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Cursor matches what macOS uses elsewhere for window-resize so
    /// the gesture feels native.
    private var cursor: NSCursor {
        switch handle {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // No diagonal-resize cursor in public AppKit, but
            // resizeUpDown reads as "you can move this edge" well
            // enough on macOS 14+.
            return .crosshair
        }
    }
}

/// Pill-button chip used for the Region / Window / Full mode picker.
private struct ModeChip: View {
    let label: String
    let systemImage: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.65))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Tiny NSView that listens for the Escape key to cancel the selection
/// overlay — SwiftUI's `keyboardShortcut(.cancelAction)` doesn't fire
/// inside a non-activating NSPanel, so we drop one layer down.
private struct KeyEventCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.onEscape = onEscape
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyView)?.onEscape = onEscape
    }

    final class KeyView: NSView {
        var onEscape: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            // Esc keycode is 53.
            if event.keyCode == 53 {
                onEscape?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
