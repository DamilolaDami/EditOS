import AVFoundation
import AppKit
import SwiftUI

/// SwiftUI wrapper around `AVCaptureVideoPreviewLayer`. Renders the
/// live feed of an `AVCaptureSession` — used by both the selection
/// overlay (so the user sees their face before hitting Start) and the
/// recording-active frame overlay (so they can monitor framing while
/// the recording is in progress).
///
/// Layer-hosting NSView with the preview layer set as the backing
/// layer; SwiftUI sizes the view, AVFoundation drives the pixels.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = previewLayer
            // The preview layer needs to know it's the backing layer
            // so it sizes itself with the view instead of staying at
            // its default zero frame.
            layerContentsRedrawPolicy = .duringViewResize
            autoresizingMask = [.width, .height]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
