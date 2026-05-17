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
            // them why. Surface a tangible alert with the most likely
            // remediation steps.
            Logger(subsystem: "com.damioffice.EditOS", category: "RecorderCoordinator")
                .error("recorder.stop() returned nil — writer ended in non-completed state or no samples ever arrived")
            showFailureAlert()
        }
        return url
    }

    private func showFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Recording didn't save"
        alert.informativeText = """
        EditOS started the recording but the file didn't finish writing. \
        This usually means screen capture frames stopped flowing, or AVAssetWriter rejected \
        the configured codec on this machine.

        Check Console.app and filter for "ScreenRecorder" / "RecorderCoordinator" to see the underlying error.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private var toastWindow: NSWindow?

    private func openFinishedToast(for url: URL) {
        toastWindow?.orderOut(nil)

        guard let screen = NSScreen.main else { return }
        let size = CGSize(width: 320, height: 84)
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
            onOpen: {
                NSWorkspace.shared.open(url)
            }
        )
        window.contentView = NSHostingView(rootView: view)
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

        let size = CGSize(width: 220, height: 44)
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

        let view = RecordingControlsBar(recorder: recorder) { [weak self] in
            Task { @MainActor in _ = await self?.stop() }
        }
        panel.contentView = NSHostingView(rootView: view)
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
    case region(SCDisplay, CGRect)  // crop is in display-local pixels

    func makeFilterAndConfig(includeMicrophone: Bool) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = true
        if includeMicrophone {
            config.captureMicrophone = true
        }

        let filter: SCContentFilter
        switch self {
        case .fullDisplay(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
            config.width = Int(display.width)
            config.height = Int(display.height)
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
        case .region(let display, let rect):
            filter = SCContentFilter(display: display, excludingWindows: [])
            config.sourceRect = rect
            config.width = Int(rect.width)
            config.height = Int(rect.height)
        }

        return (filter, config)
    }
}
