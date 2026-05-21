import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import OSLog

// MARK: - Shared per-frame metadata
//
// These types are lifted out of `CompositionBuilder` so both the
// builder and the compositor can read them. They're carried into the
// compositor on `EditorCompositionInstruction`.

/// Per-clip preferred-transform record. The compositor uses this to
/// orient each clip's source frame correctly without setting a
/// composition-level transform on the shared video track (that would
/// force every clip into the first clip's orientation).
struct ClipVideoTransform: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let transform: CGAffineTransform
    let naturalSize: CGSize
}

/// Fade / dip range — a coloured veil with ramped alpha applied over
/// the frame for `[start, end]`. Drives clip-level fade-in / fade-out
/// AND the cross-clip dip-to-black / dip-to-white transitions.
struct FadeRange: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let kind: Kind
    let dipColor: (r: Double, g: Double, b: Double)

    enum Kind: Sendable { case `in`, out }
}

/// Active filter clip range. The compositor applies the named preset
/// at the given intensity for any frame whose time falls inside.
struct FilteredRange: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let presetID: String
    let intensity: Double
}

/// Overlay (text / sticker / animated) pre-rendered into the canvas
/// coordinate space. Multi-frame overlays (GIFs / text animations)
/// pick the right frame via `image(at:)` based on local time.
struct OverlayInstance: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let frames: [CIImage]
    let durations: [TimeInterval]
    /// True for animated stickers / GIFs (they loop forever). False
    /// for text animations (they run once and latch on the final
    /// frame for the rest of the clip).
    let loops: Bool

    func image(at localTime: TimeInterval) -> CIImage? {
        guard let first = frames.first else { return nil }
        guard frames.count > 1, !durations.isEmpty else { return first }
        let loopDuration = durations.reduce(0, +)
        guard loopDuration > 0 else { return first }
        let t = loops
            ? localTime.truncatingRemainder(dividingBy: loopDuration)
            : min(localTime, loopDuration)
        var elapsed: TimeInterval = 0
        for (i, d) in durations.enumerated() {
            elapsed += d
            if t < elapsed { return frames[i] }
        }
        return frames.last
    }
}

// MARK: - Compositor

/// Custom `AVVideoCompositing` implementation. Replaces the
/// `applyingCIFiltersWithHandler` factory the project used until #65,
/// running the same per-frame pipeline through the multi-track-aware
/// `AVVideoCompositing` protocol.
///
/// Milestone 1 (this file): pixel-identical render to the prior
/// CIFilter handler — single source layer per frame, exactly the same
/// orient → aspect-fit → filter → dip → overlay pipeline. No behaviour
/// change for users.
///
/// Milestone 2 (later): alternating composition tracks for crossfade
/// pairs + layer-instruction opacity ramps, retiring `TransitionCache`.
///
/// Milestone 3 (later): PIP overlay (#15), clip masks (#51),
/// adjustment layer (#56), Magic Mask (#63) plumb through here.
///
/// Lifecycle: AVFoundation instantiates one compositor per
/// composition (via the `customVideoCompositorClass` reference). It
/// calls `renderContextChanged(_:)` once when the player attaches and
/// `startRequest(_:)` once per frame. All per-frame data we need is
/// on the `EditorCompositionInstruction` attached to the request.
final class EditorCompositor: NSObject, AVVideoCompositing {
    private static let logger = Logger(subsystem: "com.damioffice.EditOS", category: "EditorCompositor")

    // Required attributes — match what the prior CIFilter handler
    // produced. 32BGRA is what `CIContext.render(_:to:)` works with
    // most cheaply.
    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    /// Render work runs on a serial queue so we never race two frames
    /// against the same CIContext / pixel-buffer pool.
    private let renderQueue = DispatchQueue(
        label: "com.damioffice.EditOS.compositor",
        qos: .userInitiated
    )
    /// Long-lived CIContext — building one per frame would be wasteful.
    /// Defaults are fine; no need to pin a Metal device explicitly.
    private let ciContext = CIContext()

    /// Set by AVFoundation when the player attaches. We read its
    /// `newPixelBuffer()` for each frame's output buffer.
    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync {
            self.renderContext = newRenderContext
        }
    }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        // Hop to the render queue so the CIContext and pool aren't
        // touched concurrently. AVFoundation can call this from any
        // queue; on macOS the render thread is usually a non-main
        // background queue.
        renderQueue.async { [weak self] in
            self?.handle(asyncVideoCompositionRequest)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // No external pending state — every request resolves
        // synchronously inside `handle(_:)`. Implementing the method
        // is still required by the protocol so AVFoundation's lifecycle
        // hooks can call it on teardown.
    }

    // MARK: - Per-frame work

    private func handle(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? EditorCompositionInstruction else {
            // Defensive: if we ever attach to a composition with the
            // wrong instruction shape, finish with the request's own
            // source frame so AVFoundation doesn't stall.
            if let trackID = request.sourceTrackIDs.first?.int32Value,
               let buffer = request.sourceFrame(byTrackID: trackID),
               let copy = Self.copyBuffer(buffer, into: renderContext) {
                request.finish(withComposedVideoFrame: copy)
            } else {
                request.finish(with: CompositorError.invalidInstruction)
            }
            return
        }

        let canvasSize = instruction.canvasSize
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let bgColor = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        let safeFallback = CIImage(color: bgColor).cropped(to: canvasRect)

        let t = request.compositionTime.seconds

        // Source layer (M1: single track). Pull the frame via the
        // instruction's first declared source track ID. Missing source
        // is normal — happens during padded tails or between-clip gaps
        // — and we fall back to the canvas-coloured fallback.
        var result = safeFallback
        if let trackIDValue = instruction.requiredSourceTrackIDs?.first,
           let trackID = (trackIDValue as? NSNumber)?.int32Value,
           let buffer = request.sourceFrame(byTrackID: trackID) {
            let raw = CIImage(cvPixelBuffer: buffer)
            result = renderSourceLayer(
                raw,
                at: t,
                instruction: instruction,
                canvasSize: canvasSize,
                safeFallback: safeFallback
            )
        }

        // Fades / dip transitions — same ramped-alpha overlay
        // machinery as the old handler. Multiple fades may overlap
        // (e.g. one clip's transition out at the same time as another's
        // transition in on a different track) so we composite each in
        // turn, top-down.
        for fade in instruction.fades where t >= fade.start && t < fade.end {
            let span = max(0.001, fade.end - fade.start)
            let progress = (t - fade.start) / span
            let alpha: Double = fade.kind == .in
                ? max(0, 1 - progress)
                : max(0, progress)
            guard alpha > 0.001 else { continue }
            let veilColor = CIColor(
                red: fade.dipColor.r,
                green: fade.dipColor.g,
                blue: fade.dipColor.b
            )
            let baseVeil = CIImage(color: veilColor).cropped(to: canvasRect)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = baseVeil
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
            if let veil = matrix.outputImage, Self.isValid(veil) {
                let veiled = veil.composited(over: result)
                if Self.isValid(veiled) {
                    result = veiled
                }
            }
        }

        // Overlays — text + stickers active at this timestamp.
        for overlay in instruction.overlays where t >= overlay.start && t < overlay.end {
            let localTime = t - overlay.start
            guard let frame = overlay.image(at: localTime), Self.isValid(frame) else { continue }
            let composited = frame.composited(over: result)
            if Self.isValid(composited) {
                result = composited
            }
        }

        // Final crop. If anything along the way left us with a
        // degenerate image, fall back to the always-valid fresh
        // black canvas. We *never* hand AVFoundation a nil buffer —
        // it'll tear the process down.
        let final: CIImage
        if Self.isValid(result) {
            let cropped = result.cropped(to: canvasRect)
            final = Self.isValid(cropped) ? cropped : safeFallback
        } else {
            final = safeFallback
        }

        guard let renderContext = self.renderContext,
              let outputBuffer = renderContext.newPixelBuffer() else {
            request.finish(with: CompositorError.bufferAllocFailed)
            return
        }
        ciContext.render(final, to: outputBuffer)
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    /// Run the orient → aspect-fit → filter pipeline on a single source
    /// frame. Returns the canvas-positioned, filtered image composited
    /// over the safe fallback so downstream fades / overlays can layer
    /// on top.
    private func renderSourceLayer(
        _ raw: CIImage,
        at t: TimeInterval,
        instruction: EditorCompositionInstruction,
        canvasSize: CGSize,
        safeFallback: CIImage
    ) -> CIImage {
        guard Self.isValid(raw) else { return safeFallback }

        // Orient via the active clip's preferredTransform. Skipped
        // entirely when no clip range matches the timestamp (e.g.
        // padded tail) — there's nothing to orient.
        let oriented: CIImage
        if let active = instruction.clipTransforms.first(where: { t >= $0.start && t < $0.end }) {
            let transformed = raw.transformed(by: active.transform)
            if Self.isValid(transformed) {
                let bounds = transformed.extent
                let translated = transformed.transformed(by: CGAffineTransform(
                    translationX: -bounds.origin.x,
                    y: -bounds.origin.y
                ))
                oriented = Self.isValid(translated) ? translated : raw
            } else {
                oriented = raw
            }
        } else {
            oriented = raw
        }

        let sourceExtent = oriented.extent
        let sourceSize = sourceExtent.size
        let safeWidth = max(1, sourceSize.width)
        let safeHeight = max(1, sourceSize.height)
        let scale = min(
            canvasSize.width / safeWidth,
            canvasSize.height / safeHeight
        )
        let scaledW = sourceSize.width * scale
        let scaledH = sourceSize.height * scale
        let tx = (canvasSize.width - scaledW) / 2 - sourceExtent.origin.x * scale
        let ty = (canvasSize.height - scaledH) / 2 - sourceExtent.origin.y * scale
        guard scale.isFinite, tx.isFinite, ty.isFinite else { return safeFallback }

        var positioned = oriented
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

        // Filter only the positioned video, so effects don't bleed
        // into the canvas background outside the source's extent.
        if let active = instruction.filters.first(where: { t >= $0.start && t < $0.end }) {
            let filtered = FilterCatalog.apply(
                presetID: active.presetID,
                intensity: active.intensity,
                to: positioned
            )
            if Self.isValid(filtered) {
                positioned = filtered
            }
        }

        guard Self.isValid(positioned) else { return safeFallback }
        let composited = positioned.composited(over: safeFallback)
        return Self.isValid(composited) ? composited : safeFallback
    }

    // MARK: - Helpers

    private static func isValid(_ image: CIImage) -> Bool {
        let e = image.extent
        return !e.isNull
            && !e.isInfinite
            && !e.isEmpty
            && e.width > 0
            && e.height > 0
            && e.width.isFinite
            && e.height.isFinite
            && e.origin.x.isFinite
            && e.origin.y.isFinite
    }

    /// Allocate an output buffer and copy `source` into it. Used as a
    /// last-ditch passthrough when the instruction is malformed — we
    /// still need to hand AVFoundation a valid frame buffer.
    private static func copyBuffer(
        _ source: CVPixelBuffer,
        into context: AVVideoCompositionRenderContext?
    ) -> CVPixelBuffer? {
        guard let context, let dest = context.newPixelBuffer() else { return nil }
        let ciContext = CIContext()
        ciContext.render(CIImage(cvPixelBuffer: source), to: dest)
        return dest
    }

    enum CompositorError: Error {
        case invalidInstruction
        case bufferAllocFailed
    }
}

// MARK: - Instruction

/// Custom `AVVideoCompositionInstructionProtocol` carrying everything
/// the compositor needs to reproduce the old CIFilter handler's per-
/// frame logic. All properties are `let` after init, so the instance
/// is safely readable from the compositor's render queue without locks.
///
/// M1 emits a single instance spanning the whole composition. M2 will
/// emit one per unique time range (and per crossfade pair will declare
/// two source track IDs so the compositor sees both clips at once).
final class EditorCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    // MARK: AVVideoCompositionInstructionProtocol

    let timeRange: CMTimeRange
    /// Defaults to `true` for post-processing (matches what the prior
    /// `applyingCIFiltersWithHandler` factory set).
    let enablePostProcessing: Bool = true
    /// Tells AVFoundation the output may differ between frames — set
    /// to true because virtually every project has motion / fades /
    /// overlays that animate per frame.
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    /// `kCMPersistentTrackID_Invalid` because we never want
    /// AVFoundation to skip the compositor and pass a track through
    /// — even single-clip frames go through the orient / aspect-fit
    /// pipeline.
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    // MARK: Custom metadata (read by EditorCompositor)

    let canvasSize: CGSize
    let clipTransforms: [ClipVideoTransform]
    let fades: [FadeRange]
    let filters: [FilteredRange]
    let overlays: [OverlayInstance]

    init(
        timeRange: CMTimeRange,
        trackIDs: [CMPersistentTrackID],
        canvasSize: CGSize,
        clipTransforms: [ClipVideoTransform],
        fades: [FadeRange],
        filters: [FilteredRange],
        overlays: [OverlayInstance]
    ) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        self.canvasSize = canvasSize
        self.clipTransforms = clipTransforms
        self.fades = fades
        self.filters = filters
        self.overlays = overlays
        super.init()
    }
}
