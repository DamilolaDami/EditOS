import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import Observation
import OSLog
import ScreenCaptureKit
import SwiftUI

/// Top-level controller for the in-app screen recorder. Owns the
/// `ScreenRecorder` engine, the selection overlay window (visible
/// before recording starts), and the floating mini controls window
/// (visible while recording is active).
///
/// The flow:
///   1. `present()` opens the selection overlay across every screen.
///      The user picks Region / Window / Full, then taps **Start**.
///   2. `beginRecording()` resolves the chosen target into an
///      `SCContentFilter`, hides the overlay, opens the mini controls
///      window with an elapsed-time readout, and starts the engine.
///   3. The user taps **Stop** in the mini window → engine finalises
///      the writer, mini window closes, a HUD bubbles up with
///      Reveal / Open / Add-to-Timeline actions.
@MainActor
@Observable
final class RecorderCoordinator: NSObject {
    let recorder = ScreenRecorder()

    /// Back-ref to the host environment so `openInEditor()` can import
    /// the recording into a new project and ask the SwiftUI scene to
    /// open the editor for it. Weak to avoid a retain cycle —
    /// `AppEnvironment` owns the coordinator.
    private weak var environment: AppEnvironment?

    func attach(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Most recently saved recording — drives the post-recording HUD.
    private(set) var lastRecording: URL?

    private var selectionWindow: NSWindow?
    private var controlsWindow: NSWindow?
    /// Always-on-top decorative overlay shown DURING recording so the
    /// user can see which slice of the screen is being captured. The
    /// window's `sharingType` is set to `.none` so SCStream skips it
    /// when assembling the recording.
    private var frameOverlayWindow: NSWindow?

    /// Caches what the selection UI resolved to, so when the user taps
    /// Start we know whether they were dragging a region or had picked
    /// a window etc.
    private var pendingTarget: RecorderTarget?
    private var pendingIncludeMicrophone = true
    /// Selection rect in SwiftUI (top-left origin, points — not pixels)
    /// captured at confirm time. Used to draw the recording-active
    /// frame overlay at the correct location.
    private var pendingScreenRect: CGRect?

    // MARK: - Entry point

    /// Open the selection UI. Idempotent — calling again while a
    /// selection is already up just brings it back to the front.
    func present() {
        if let selectionWindow {
            selectionWindow.makeKeyAndOrderFront(nil)
            return
        }

        // Pre-flight: the Screen Recording TCC prompt can't appear if
        // our `modalPanel`-level overlay is already on top of it. Check
        // (and request) permission *before* opening any window.
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                showPermissionAlert()
                return
            }
        }

        Task { await openSelectionWindow() }
    }

    /// Surface a friendly alert pointing the user at System Settings →
    /// Privacy & Security → Screen Recording. Tapping the primary
    /// action opens that pane directly via the `x-apple.systempreferences`
    /// URL scheme.
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "EditOS needs Screen Recording permission"
        alert.informativeText = """
        macOS asks every app for permission before it can record the screen. \
        Open System Settings → Privacy & Security → Screen Recording, toggle EditOS on, \
        then come back and try again. You may need to relaunch EditOS afterwards.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSelectionWindow() async {
        // Pre-fetch shareable content so the Window-picker mode has the
        // window list to work with by the time the user clicks into it.
        let content = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
        let primaryDisplay = content?.displays.first
        let displayBounds = primaryDisplay.map { CGRect(x: 0, y: 0, width: CGFloat($0.width), height: CGFloat($0.height)) }
            ?? NSScreen.main?.frame
            ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Span the entire primary screen so the dim overlay covers
        // every pixel. Multi-monitor V2: union of all screen frames.
        guard let screen = NSScreen.main else { return }

        // Custom NSWindow subclass that returns `canBecomeKey = true`.
        // The previous build used an `.nonactivatingPanel` NSPanel,
        // which kept the window from receiving SwiftUI `DragGesture`
        // events (buttons still worked because they're tap-only). A
        // borderless NSWindow that explicitly becomes key fixes both
        // the move + resize gestures and the Window-picker menu.
        let window = SelectionWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        let view = SelectionOverlay(
            content: content,
            displayBounds: displayBounds,
            onCancel: { [weak self] in self?.closeSelection() },
            onConfirm: { [weak self] target, includeMic, screenRect in
                self?.pendingTarget = target
                self?.pendingIncludeMicrophone = includeMic
                self?.pendingScreenRect = screenRect
                Task { @MainActor in await self?.beginRecording() }
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hosting)
        selectionWindow = window
    }

    /// Borderless windows don't become key by default; SwiftUI's drag
    /// gestures need a key window to fire reliably. Override to opt in.
    final class SelectionWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private func closeSelection() {
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
    }

    // MARK: - Start / stop

    private func beginRecording() async {
        guard let target = pendingTarget else { return }
        do {
            let (filter, configuration) = try await target.makeFilterAndConfig(
                includeMicrophone: pendingIncludeMicrophone
            )
            let url = try await recorder.start(
                filter: filter,
                configuration: configuration,
                includeMicrophone: pendingIncludeMicrophone
            )
            closeSelection()
            openFrameOverlay(for: target, screenRect: pendingScreenRect)
            openControlsWindow()
            lastRecording = url
        } catch {
            // Bubble the error back into the selection UI by closing it
            // and printing — the actual user-visible alert is wired
            // through the SelectionOverlay's state in a later pass; for
            // V1 we just log and bail.
            Logger(subsystem: "com.damioffice.EditOS", category: "RecorderCoordinator")
                .error("Start failed: \(error.localizedDescription, privacy: .public)")
            closeSelection()
        }
    }

    func stop() async -> URL? {
        let url = await recorder.stop()
        closeControlsWindow()
        closeFrameOverlay()
        if let url {
            lastRecording = url
            // Two confirmation signals: a floating toast in the corner
            // with action buttons, plus Finder springs open with the
            // file selected. Either one alone is fragile — the toast
            // disappears in 8s if the user looks away, and revealing
            // in Finder doesn't tell them the duration / give them a
            // direct "Open in EditOS" path. Together they make the
            // result of Stop unmissable.
            openFinishedToast(for: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Silent failure was the worst possible UX — the user
            // tapped Stop, the controls disappeared, and nothing told
            // them why. Surface a tangible alert with the actual error
            // the writer reported, so the next debugging round has
            // something specific to chase.
            let err = recorder.lastError
            Logger(subsystem: "com.damioffice.EditOS", category: "RecorderCoordinator")
                .error("recorder.stop() returned nil — \(err?.localizedDescription ?? "no error attached", privacy: .public)")
            showFailureAlert(error: err)
        }
        return url
    }

    /// Import the most recent recording into a freshly-created project
    /// and surface the editor window. This is the "the whole point" of
    /// the recorder — capturing footage and dropping it straight into a
    /// timeline ready to edit.
    func openInEditor(url: URL) {
        guard let env = environment else { return }
        Task { @MainActor in
            do {
                let asset = try await env.mediaImporter.makeAsset(from: url)
                // Drop the toast now so it doesn't linger behind the new
                // editor window.
                self.dismissToast()
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d, h:mm a"
                let name = "Screen recording — \(formatter.string(from: .now))"
                var project = env.projectStore.createProject(named: name)
                project.assets.append(asset)
                env.projectStore.update(project)
                env.recentProjects.recordOpen(project.id)
                env.openProjectInEditor(project.id)
            } catch {
                Logger(subsystem: "com.damioffice.EditOS", category: "RecorderCoordinator")
                    .error("openInEditor failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func showFailureAlert(error: Error?) {
        let alert = NSAlert()
        alert.messageText = "Recording didn't save"
        if let error {
            alert.informativeText = "AVAssetWriter failed to finalize:\n\n\(Self.describe(error))"
        } else {
            alert.informativeText = """
            EditOS started the recording but the file didn't finish writing. \
            Check Console.app and filter for "ScreenRecorder" to see the underlying error.
            """
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Recursively unwrap NSError chains so the failure alert exposes
    /// the deepest underlying error code/domain — that's the only level
    /// where we get a useful clue when AVFoundation packages the real
    /// problem behind a "operation couldn't be completed" wrapper.
    private static func describe(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        let indent = String(repeating: "  ", count: depth)
        var lines = [
            "\(indent)\(ns.localizedDescription)",
            "\(indent)Domain: \(ns.domain) Code: \(ns.code)"
        ]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, depth < 3 {
            lines.append("\(indent)↓ Underlying:")
            lines.append(describe(underlying, depth: depth + 1))
        }
        if depth == 0 {
            let extras = ns.userInfo.filter { key, _ in
                key != NSUnderlyingErrorKey && key != NSLocalizedDescriptionKey
            }
            if !extras.isEmpty {
                for (k, v) in extras {
                    lines.append("\(indent)• \(k): \(v)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private var toastWindow: NSWindow?

    private func openFinishedToast(for url: URL) {
        toastWindow?.orderOut(nil)

        guard let screen = NSScreen.main else { return }
        let size = CGSize(width: 340, height: 108)
        let origin = CGPoint(
            x: screen.frame.maxX - size.width - 24,
            y: screen.frame.maxY - size.height - 80
        )
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false

        let view = RecordingFinishedToast(
            url: url,
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            onOpenInEditor: { [weak self] in
                self?.openInEditor(url: url)
            },
            onPreview: {
                NSWorkspace.shared.open(url)
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hosting
        window.orderFrontRegardless()
        toastWindow = window

        // Auto-dismiss after 8s if the user doesn't interact with it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self.dismissToast()
        }
    }

    private func dismissToast() {
        toastWindow?.orderOut(nil)
        toastWindow = nil
    }

    // MARK: - Controls window (the floating mini panel while recording)

    private func openControlsWindow() {
        guard controlsWindow == nil else { return }
        guard let screen = NSScreen.main else { return }

        // Build the hosting view first so we can size the panel to its
        // intrinsic content size. Any extra padding inside the panel
        // shows the dim mask through as a darker rectangle behind the
        // pill — sizing to fit eliminates that completely.
        let view = RecordingControlsBar(recorder: recorder) { [weak self] in
            Task { @MainActor in _ = await self?.stop() }
        }
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        let fitting = hosting.fittingSize
        let size = CGSize(
            width: max(fitting.width, 120),
            height: max(fitting.height, 32)
        )
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + 60
        )
        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above `.floating` so we stay on top of the recording-active
        // frame overlay (which is also a floating window covering the
        // whole screen). If they were at the same level, the overlay's
        // dim layer would obscure the Stop button.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none  // don't record our own UI
        // Reuse the hosting view we built up top to size the panel.
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        controlsWindow = panel
    }

    private func closeControlsWindow() {
        controlsWindow?.orderOut(nil)
        controlsWindow = nil
    }

    // MARK: - Frame overlay (the dim "what's being recorded" indicator)

    /// Open a full-screen, click-through, non-recordable window that
    /// shows the dim-around / clear-inside indicator on top of the
    /// active recording. `sharingType = .none` keeps the overlay out of
    /// the recording stream itself; otherwise we'd be capturing our own
    /// dim layer.
    private func openFrameOverlay(for target: RecorderTarget, screenRect: CGRect?) {
        guard frameOverlayWindow == nil else { return }
        guard let screen = NSScreen.main else { return }

        // Resolve a screen-coordinate rect (top-left origin, points) to
        // highlight. Region uses the pending screenRect captured from
        // the selection UI; Window uses SCWindow.frame which is already
        // in screen-points; Full uses nil to draw just a perimeter glow.
        let highlightRect: CGRect?
        switch target {
        case .fullDisplay:
            highlightRect = nil
        case .window(let window):
            highlightRect = window.frame
        case .region:
            highlightRect = screenRect
        }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // `.floating` is intentional — must stay BELOW the controls
        // window so the Stop button stays visible & clickable. The
        // controls window is bumped to `.statusBar` for that reason.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // The key bit: keep this overlay out of the recording. Without
        // it, SCStream would capture our own dim layer and we'd be
        // recording a permanently-dim screen.
        window.sharingType = .none

        let view = RecordingFrameOverlay(highlight: highlightRect)
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        window.orderFrontRegardless()
        frameOverlayWindow = window
    }

    private func closeFrameOverlay() {
        frameOverlayWindow?.orderOut(nil)
        frameOverlayWindow = nil
    }
}

// MARK: - Target

/// What the user picked in the selection UI. Each variant knows how to
/// resolve itself into an SCContentFilter + SCStreamConfiguration.
enum RecorderTarget: Equatable {
    case fullDisplay(SCDisplay)
    case window(SCWindow)
    /// Region capture. The rect is in **display-local points** — same
    /// space SwiftUI uses for the overlay. The output width/height get
    /// multiplied by the display's backing scale separately so the
    /// resulting .mov is retina-quality, but `sourceRect` itself stays
    /// in points (which is what `SCStreamConfiguration` expects).
    case region(SCDisplay, CGRect)

    func makeFilterAndConfig(includeMicrophone: Bool) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        // V1 audio model: mic toggle = microphone-only. Feeding both
        // system audio (.audio at 48 kHz) AND microphone audio into
        // the same AVAssetWriterInput trips OSStatus -12737 because
        // their format descriptions don't match and AVAssetWriter has
        // no built-in mixer. Proper system + mic mixing via
        // AVAudioEngine is a v2 task.
        if includeMicrophone {
            config.captureMicrophone = true
        }

        let filter: SCContentFilter
        switch self {
        case .fullDisplay(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
            config.width = Self.evenDown(CGFloat(display.width))
            config.height = Self.evenDown(CGFloat(display.height))
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            // SCWindow.frame is in points; output dimensions are in
            // pixels. Scale up so the recording captures the window
            // at retina resolution.
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            config.width = Self.evenDown(window.frame.width * scale)
            config.height = Self.evenDown(window.frame.height * scale)
        case .region(let display, let rect):
            filter = SCContentFilter(display: display, excludingWindows: [])
            // sourceRect is in display POINTS (matches SwiftUI's space
            // for the overlay). Output dimensions are in PIXELS — scale
            // up so a 800×500-point region on a 2x retina renders as
            // 1600×1000 in the .mov. H.264 wants even pixel dimensions
            // or the hardware encoder silently fails, so we round down
            // to even at the pixel layer and pull the sourceRect's
            // width/height in step so the buffers match.
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let evenW = Self.evenDown(rect.width * scale)
            let evenH = Self.evenDown(rect.height * scale)
            let pointW = CGFloat(evenW) / scale
            let pointH = CGFloat(evenH) / scale
            config.sourceRect = CGRect(x: rect.minX, y: rect.minY, width: pointW, height: pointH)
            config.width = evenW
            config.height = evenH
        }

        return (filter, config)
    }

    private static func evenDown(_ value: CGFloat) -> Int {
        let i = Int(value)
        return i - (i % 2)
    }
}
