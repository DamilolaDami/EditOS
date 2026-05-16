import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSImageView` with `animates = true`. macOS already
/// knows how to render animated GIFs frame-by-frame — `NSImage(contentsOf:)`
/// produces a multi-rep image and the view ticks through them automatically.
/// Use this for the canvas-side sticker rendering so GIPHY stickers actually
/// move in the player. (Export uses its own per-frame extraction path.)
struct AnimatedImage: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.canDrawSubviewsIntoLayer = true
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        guard let url else {
            nsView.image = nil
            return
        }
        // Reload only when the file URL actually changes so AppKit keeps
        // playing the existing animation between SwiftUI re-renders.
        if nsView.image?.name() != url.path {
            let image = NSImage(contentsOf: url)
            image?.setName(url.path)
            nsView.image = image
            nsView.animates = true
        }
    }
}
