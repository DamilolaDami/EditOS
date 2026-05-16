import AVFoundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import OSLog

/// Result of compositing a project into AVFoundation primitives.
struct CompositionResult: Sendable {
    let composition: AVComposition
    /// Per-frame filter pipeline (CIFilter chains keyed off the video clip
    /// active at each timestamp). `nil` when no clip carries a filter — lets
    /// the player render the shared video track directly.
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
}

/// Builds an `AVComposition` (and matching `AVAudioMix`) from a `Project`.
///
/// Layout:
/// - One shared video composition track holds every clip's video stream so
///   AVPlayer renders continuously across clips. (Per-clip transforms will move
///   to an AVVideoComposition when we add that.)
/// - One audio composition track per clip so we can mix volumes independently.
/// - Clips are inserted in chronological order — `insertTimeRange(...at:)`
///   pushes existing content forward, so out-of-order inserts would shuffle
///   already-placed clips.
struct CompositionBuilder: Sendable {
    enum BuildError: Error {
        case missingAsset(MediaAsset.ID)
        case unreadableAsset(URL)
    }

    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "CompositionBuilder")

    func build(_ project: Project, assetResolver: AssetResolver) async throws -> CompositionResult {
        let composition = AVMutableComposition()
        // Single shared video track for every video clip. We deliberately
        // do NOT set the track's `preferredTransform` — that would force
        // every clip to inherit the first clip's orientation. Instead we
        // collect per-clip transforms below and apply them in the
        // CIFilter handler. `applyingCIFiltersWithHandler` reads from a
        // single track, so multiple tracks would leave the others black.
        var sharedVideoTrack: AVMutableCompositionTrack?
        var clipTransforms: [ClipVideoTransform] = []
        var audioParams: [AVMutableAudioMixInputParameters] = []

        // Collect every visible (track, clip) pair, then insert in chronological
        // order so insertTimeRange's auto-push doesn't re-arrange already-placed
        // clips.
        var entries: [(kind: Track.Kind, isMuted: Bool, clip: Clip)] = []
        for track in project.timeline.tracks where !track.isHidden {
            for clip in track.clips {
                entries.append((track.kind, track.isMuted, clip))
            }
        }
        entries.sort { $0.clip.timeRange.start < $1.clip.timeRange.start }

        // Track which audio mix params belong to voiceover clips so we can
        // skip ducking them (a voiceover doesn't duck itself).
        var voiceoverParamIDs: Set<ObjectIdentifier> = []

        for entry in entries {
            let clip = entry.clip
            // Text / sticker / overlay tracks don't composite into AV — the
            // preview renders them as a SwiftUI overlay on top of the player.
            guard entry.kind == .video || entry.kind == .audio else { continue }
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
                Self.log.error("Missing asset \(clip.assetID, privacy: .public) for clip \(clip.id, privacy: .public)")
                continue
            }
            do {
                let url = try await assetResolver.resolve(asset)
                let countBefore = audioParams.count
                try await insertClip(
                    clip,
                    asset: AVURLAsset(url: url),
                    kind: entry.kind,
                    isMuted: entry.isMuted,
                    into: composition,
                    sharedVideoTrack: &sharedVideoTrack,
                    clipTransforms: &clipTransforms,
                    audioParams: &audioParams
                )
                if clip.isVoiceover, audioParams.count > countBefore,
                   let last = audioParams.last {
                    voiceoverParamIDs.insert(ObjectIdentifier(last))
                }
            } catch {
                Self.log.error("Failed to insert clip \(clip.id, privacy: .public) (\(asset.displayName, privacy: .public)): \(String(describing: error), privacy: .public)")
                continue
            }
        }

        // Audio ducking — for every non-voiceover audio param, drop the
        // volume to 25% during voiceover time ranges with a short ramp at
        // each edge so the cut isn't abrupt. Voiceover clips themselves
        // keep their authored volume.
        let voiceoverRanges = Self.voiceoverRanges(in: project)
        if !voiceoverRanges.isEmpty {
            let rampDuration = CMTime(seconds: 0.25, preferredTimescale: 600)
            for param in audioParams where !voiceoverParamIDs.contains(ObjectIdentifier(param)) {
                for range in voiceoverRanges {
                    let downStart = range.start
                    let downEnd = CMTimeAdd(downStart, rampDuration)
                    param.setVolumeRamp(
                        fromStartVolume: 1.0,
                        toEndVolume: 0.25,
                        timeRange: CMTimeRange(start: downStart, end: downEnd)
                    )
                    let upStart = CMTimeSubtract(CMTimeAdd(range.start, range.duration), rampDuration)
                    let upEnd = CMTimeAdd(range.start, range.duration)
                    param.setVolumeRamp(
                        fromStartVolume: 0.25,
                        toEndVolume: 1.0,
                        timeRange: CMTimeRange(start: upStart, end: upEnd)
                    )
                }
            }
        }

        let mix: AVAudioMix?
        if audioParams.isEmpty {
            mix = nil
        } else {
            let m = AVMutableAudioMix()
            m.inputParameters = audioParams
            mix = m.copy() as? AVAudioMix
        }

        // Pad the composition out to cover the *full* timeline duration —
        // including text/sticker overlays that live past the last A/V clip.
        // Without this, AVPlayer's clock stops at the last media frame, so
        // the SwiftUI overlay (which keys off `currentTime`) never animates
        // the post-video title in. We extend by inserting an empty time
        // range on a video track so the AVVideoComposition handler still
        // gets called for those frames and the export bakes the overlay in.
        Self.padCompositionToFullTimeline(
            composition: composition,
            project: project,
            sharedVideoTrack: sharedVideoTrack
        )

        // After padding, the last A/V clip's stretched frame holds through
        // the overlay-only tail. Extend its transform window so the
        // CIFilter handler keeps applying the right orientation during
        // that held tail — otherwise the still frame snaps to raw pixel
        // orientation while overlays animate over it.
        if !clipTransforms.isEmpty {
            let lastIdx = clipTransforms.count - 1
            let last = clipTransforms[lastIdx]
            let timelineEnd = project.timeline.duration
            if timelineEnd > last.end {
                clipTransforms[lastIdx] = ClipVideoTransform(
                    start: last.start,
                    end: timelineEnd,
                    transform: last.transform,
                    naturalSize: last.naturalSize
                )
            }
        }

        let avComposition = composition.copy() as! AVComposition
        let videoComposition = await Self.buildVideoComposition(
            for: project,
            asset: avComposition,
            clipTransforms: clipTransforms
        )
        Self.log.info("Built composition: duration \(composition.duration.seconds, privacy: .public)s, \(composition.tracks.count, privacy: .public) tracks, \(audioParams.count, privacy: .public) audio params, videoComp \(videoComposition != nil, privacy: .public)")
        return CompositionResult(
            composition: avComposition,
            videoComposition: videoComposition,
            audioMix: mix
        )
    }

    /// Per-clip preferredTransform record. Used by the CIFilter handler to
    /// orient each clip's raw source pixels correctly without setting a
    /// single transform on the shared video track (which would force every
    /// clip into the first clip's orientation).
    struct ClipVideoTransform: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let transform: CGAffineTransform
        let naturalSize: CGSize
    }

    /// Builds the master `AVVideoComposition` that drives both playback and
    /// export. Three things happen per frame:
    ///   1. The source video is aspect-fit centered into the project's
    ///      canvas size (so wider / narrower canvases letterbox or pillarbox
    ///      the content instead of being silently dropped on export).
    ///   2. The active filter clip (if any) runs its CIFilter chain on the
    ///      positioned video.
    ///   3. Pre-rendered text / sticker overlay images are composited on
    ///      top at their canvas-space positions.
    ///
    /// Returns nil only when the project has no video tracks at all — the
    /// player and export then bypass CI entirely.
    private static func buildVideoComposition(
        for project: Project,
        asset: AVAsset,
        clipTransforms: [ClipVideoTransform]
    ) async -> AVVideoComposition? {
        let canvasSize = project.canvas.size
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        // Verify there's actually a video track to render — audio-only
        // projects don't need a video composition.
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !videoTracks.isEmpty else { return nil }

        // Pre-build overlay CIImages with canvas positions baked in. Done
        // up-front so the per-frame hot path is just composite calls — never
        // disk I/O, never string rasterisation. Animated GIFs return a
        // multi-frame `RenderedOverlay`; the handler picks the right frame
        // based on `compositionTime - clip.start`.
        struct OverlayInstance: Sendable {
            let start: TimeInterval
            let end: TimeInterval
            let frames: [CIImage]
            let durations: [TimeInterval]

            func image(at localTime: TimeInterval) -> CIImage? {
                guard let first = frames.first else { return nil }
                guard frames.count > 1, !durations.isEmpty else { return first }
                let loop = durations.reduce(0, +)
                guard loop > 0 else { return first }
                let t = localTime.truncatingRemainder(dividingBy: loop)
                var elapsed: TimeInterval = 0
                for (i, d) in durations.enumerated() {
                    elapsed += d
                    if t < elapsed { return frames[i] }
                }
                return frames.last
            }
        }
        var overlays: [OverlayInstance] = []
        for track in project.timeline.tracks where !track.isHidden {
            // Only render overlay-style tracks; video / audio / filter
            // lanes don't have visual chrome of their own.
            switch track.kind {
            case .caption, .sticker, .overlay:
                for clip in track.clips {
                    if let rendered = await renderOverlay(for: clip, canvas: canvasSize) {
                        overlays.append(OverlayInstance(
                            start: clip.timeRange.start,
                            end: clip.timeRange.end,
                            frames: rendered.frames,
                            durations: rendered.durations
                        ))
                    }
                }
            default:
                continue
            }
        }

        // Snapshot fade-in / fade-out ranges per video clip so the handler
        // can ramp opacity to / from black without walking the project tree.
        struct FadeRange: Sendable {
            let start: TimeInterval
            let end: TimeInterval
            let kind: FadeKind
            enum FadeKind: Sendable { case `in`, out }
        }
        var fades: [FadeRange] = []
        for track in project.timeline.tracks where track.kind == .video && !track.isHidden {
            for clip in track.clips {
                let duration = max(0.05, clip.fadeDuration)
                if clip.fadeIn {
                    fades.append(FadeRange(
                        start: clip.timeRange.start,
                        end: min(clip.timeRange.end, clip.timeRange.start + duration),
                        kind: .in
                    ))
                }
                if clip.fadeOut {
                    fades.append(FadeRange(
                        start: max(clip.timeRange.start, clip.timeRange.end - duration),
                        end: clip.timeRange.end,
                        kind: .out
                    ))
                }
            }
        }

        // Filter ranges — dedicated `.filter` tracks plus the legacy
        // per-video-clip filterPreset for older projects.
        struct FilteredRange: Sendable {
            let start: TimeInterval
            let end: TimeInterval
            let presetID: String
            let intensity: Double
        }
        var filters: [FilteredRange] = []
        for track in project.timeline.tracks where !track.isHidden {
            guard track.kind == .filter || track.kind == .video else { continue }
            for clip in track.clips {
                guard let preset = clip.filterPreset, preset != "none" else { continue }
                filters.append(FilteredRange(
                    start: clip.timeRange.start,
                    end: clip.timeRange.end,
                    presetID: preset,
                    intensity: clip.filterIntensity ?? 1.0
                ))
            }
        }

        let bgColor = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let frameRate = max(1.0, project.canvas.frameRate)

        do {
            // Use the mutable variant so we can override `renderSize` and
            // `frameDuration` after construction — the read-only base type
            // exposes them get-only.
            let videoComp = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
                // Every frame ends here. The handler is best-effort: if any
                // single composite step produces a degenerate image we
                // drop back to a known-good fallback and still call finish.
                // AVAsynchronousCIImageFilteringRequest.finish(with:)
                // asserts `filteredImage != nil`, so the *last* line of
                // defence is `safeFallback` — a freshly-built black canvas
                // built fresh per frame so its lifetime is never in doubt.
                let safeFallback = CIImage(color: bgColor).cropped(to: canvasRect)

                func isValid(_ image: CIImage) -> Bool {
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

                let t = request.compositionTime.seconds
                let raw = request.sourceImage
                let hasUsableSource = isValid(raw)

                // Apply the active clip's source preferredTransform so
                // portrait / landscape / rotated sources render in their
                // intended orientation. Skipped entirely when the source
                // frame has no usable extent (padded tail / between-clip
                // gap) — there's nothing to orient.
                var result = safeFallback
                if hasUsableSource {
                    let oriented: CIImage
                    if let active = clipTransforms.first(where: { t >= $0.start && t < $0.end }) {
                        let transformed = raw.transformed(by: active.transform)
                        if isValid(transformed) {
                            let bounds = transformed.extent
                            let translated = transformed.transformed(by: CGAffineTransform(
                                translationX: -bounds.origin.x,
                                y: -bounds.origin.y
                            ))
                            oriented = isValid(translated) ? translated : raw
                        } else {
                            oriented = raw
                        }
                    } else {
                        oriented = raw
                    }

                    let sourceExtent = oriented.extent
                    let sourceSize = sourceExtent.size

                    // Aspect-fit the source into the canvas. Guard the
                    // divisor against degenerate dimensions.
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
                    if scale.isFinite && tx.isFinite && ty.isFinite {
                        var positioned = oriented
                            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

                        // Apply active filter (if any) to the positioned
                        // video only, so filter effects don't bleed into
                        // the canvas background.
                        if let active = filters.first(where: { t >= $0.start && t < $0.end }) {
                            let filtered = FilterCatalog.apply(
                                presetID: active.presetID,
                                intensity: active.intensity,
                                to: positioned
                            )
                            if isValid(filtered) {
                                positioned = filtered
                            }
                        }

                        if isValid(positioned) {
                            let composited = positioned.composited(over: safeFallback)
                            if isValid(composited) {
                                result = composited
                            }
                        }
                    }
                }

                // Fade in / out — black overlay with ramped alpha. Single
                // shared video track means we can't crossfade between
                // clips, but fading to/from black is a usable approximation.
                if let fade = fades.first(where: { t >= $0.start && t < $0.end }) {
                    let span = max(0.001, fade.end - fade.start)
                    let progress = (t - fade.start) / span
                    let alpha: Double = fade.kind == .in
                        ? max(0, 1 - progress)
                        : max(0, progress)
                    if alpha > 0.001 {
                        let blackVeil = CIImage(color: CIColor.black).cropped(to: canvasRect)
                        let matrix = CIFilter.colorMatrix()
                        matrix.inputImage = blackVeil
                        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
                        if let veil = matrix.outputImage, isValid(veil) {
                            let veiled = veil.composited(over: result)
                            if isValid(veiled) {
                                result = veiled
                            }
                        }
                    }
                }

                // Overlays — text + stickers active at this timestamp.
                for overlay in overlays where t >= overlay.start && t < overlay.end {
                    let localTime = t - overlay.start
                    guard let frame = overlay.image(at: localTime), isValid(frame) else { continue }
                    let composited = frame.composited(over: result)
                    if isValid(composited) {
                        result = composited
                    }
                }

                // Final crop. If anything along the way left us with a
                // degenerate image, fall back to the always-valid fresh
                // black canvas. We *never* want to hand AVFoundation a
                // nil-backed image — it asserts filteredImage != nil and
                // tears the process down.
                let final: CIImage
                if isValid(result) {
                    let cropped = result.cropped(to: canvasRect)
                    final = isValid(cropped) ? cropped : safeFallback
                } else {
                    final = safeFallback
                }
                request.finish(with: final, context: nil)
            }
            videoComp.renderSize = canvasSize
            videoComp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            return videoComp
        } catch {
            Self.log.error("Failed to build video composition: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Overlay rasterisation

    /// Frames + per-frame durations for an overlay. Static overlays return
    /// a single frame and an empty durations array.
    struct RenderedOverlay: Sendable {
        let frames: [CIImage]
        let durations: [TimeInterval]
    }

    /// Returns the positioned frames + durations for a text / sticker / SF
    /// Symbol clip, or nil if the clip isn't an overlay. Animated GIFs come
    /// back with a frame per encoded image and matching delay durations.
    @MainActor
    private static func renderOverlay(for clip: Clip, canvas: CGSize) -> RenderedOverlay? {
        let dx = clip.transform.translation.width
        let dy = clip.transform.translation.height
        let opacity = max(0, min(1, clip.transform.opacity))

        if let text = clip.text {
            let size = clip.overlaySize ?? 64
            let color = clip.foregroundColor ?? .white
            if let image = renderTextOverlay(
                text: text, fontSize: size, color: color,
                canvas: canvas, dx: dx, dy: dy, opacity: opacity
            ) {
                return RenderedOverlay(frames: [image], durations: [])
            }
        }
        if let path = clip.stickerImagePath {
            let size = clip.overlaySize ?? 200
            return renderStickerOverlay(
                path: path, size: size,
                canvas: canvas, dx: dx, dy: dy, opacity: opacity
            )
        }
        if let symbol = clip.stickerSymbol {
            let size = clip.overlaySize ?? 96
            let color = clip.foregroundColor ?? .white
            if let image = renderSymbol(
                symbol: symbol, size: size, color: color,
                canvas: canvas, dx: dx, dy: dy, opacity: opacity
            ) {
                return RenderedOverlay(frames: [image], durations: [])
            }
        }
        return nil
    }

    private static func renderTextOverlay(
        text: String,
        fontSize: CGFloat,
        color: ColorRGBA,
        canvas: CGSize,
        dx: CGFloat,
        dy: CGFloat,
        opacity: Double
    ) -> CIImage? {
        let nsColor = NSColor(
            red: color.red, green: color.green, blue: color.blue, alpha: color.alpha
        )
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = max(2, fontSize / 18)
        shadow.shadowOffset = NSSize(width: 0, height: -max(1, fontSize / 28))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: nsColor,
            .shadow: shadow
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let measured = attributed.size()
        // Add a small inset so the drop shadow has room to render.
        let inset: CGFloat = ceil(shadow.shadowBlurRadius + 2)
        let bitmapSize = NSSize(
            width: max(1, ceil(measured.width) + inset * 2),
            height: max(1, ceil(measured.height) + inset * 2)
        )
        let image = NSImage(size: bitmapSize)
        image.lockFocus()
        attributed.draw(at: NSPoint(x: inset, y: inset))
        image.unlockFocus()
        guard let cg = bitmapCGImage(from: image) else { return nil }
        var ciImage = CIImage(cgImage: cg)
        ciImage = applyOpacity(opacity, to: ciImage)
        return positionInCanvas(ciImage, size: bitmapSize, canvas: canvas, dx: dx, dy: dy)
    }

    private static func renderStickerOverlay(
        path: String,
        size: CGFloat,
        canvas: CGSize,
        dx: CGFloat,
        dy: CGFloat,
        opacity: Double
    ) -> RenderedOverlay? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { return nil }

        var frames: [CIImage] = []
        var durations: [TimeInterval] = []
        for index in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            var frame = CIImage(cgImage: cgImage)
            let intrinsic = frame.extent.size
            let scale = size / max(1, max(intrinsic.width, intrinsic.height))
            let scaledSize = CGSize(width: intrinsic.width * scale, height: intrinsic.height * scale)
            frame = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            frame = applyOpacity(opacity, to: frame)
            frame = positionInCanvas(frame, size: scaledSize, canvas: canvas, dx: dx, dy: dy)
            frames.append(frame)

            if frameCount > 1,
               let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
               let gifProps = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                let delay = (gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
                    ?? (gifProps[kCGImagePropertyGIFDelayTime as String] as? Double)
                    ?? 0.1
                durations.append(max(0.02, delay))
            }
        }
        guard !frames.isEmpty else { return nil }
        return RenderedOverlay(
            frames: frames,
            durations: durations.count == frames.count ? durations : []
        )
    }

    private static func renderSymbol(
        symbol: String,
        size: CGFloat,
        color: ColorRGBA,
        canvas: CGSize,
        dx: CGFloat,
        dy: CGFloat,
        opacity: Double
    ) -> CIImage? {
        let nsColor = NSColor(
            red: color.red, green: color.green, blue: color.blue, alpha: color.alpha
        )
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        guard let baseImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        // Tint by drawing the symbol as a clipping mask over a solid fill.
        let glyphSize = baseImage.size
        let tinted = NSImage(size: glyphSize, flipped: false) { rect in
            nsColor.set()
            rect.fill()
            baseImage.draw(at: .zero, from: rect, operation: .destinationIn, fraction: 1.0)
            return true
        }
        guard let cg = bitmapCGImage(from: tinted) else { return nil }
        var ciImage = CIImage(cgImage: cg)
        ciImage = applyOpacity(opacity, to: ciImage)
        return positionInCanvas(ciImage, size: glyphSize, canvas: canvas, dx: dx, dy: dy)
    }

    /// Translates `image` so its centre lands at the canvas centre plus the
    /// user-supplied (`dx`, `dy`) offset, flipping `dy` from SwiftUI's
    /// "positive = down" to Core Image's "positive = up" convention.
    private static func positionInCanvas(
        _ image: CIImage,
        size: CGSize,
        canvas: CGSize,
        dx: CGFloat,
        dy: CGFloat
    ) -> CIImage {
        let baseX = (canvas.width - size.width) / 2 + dx
        let baseY = (canvas.height - size.height) / 2 - dy
        return image.transformed(by: CGAffineTransform(translationX: baseX, y: baseY))
    }

    /// Multiplies the alpha channel of `image` by `opacity` so per-clip
    /// transform opacity carries through into the export.
    private static func applyOpacity(_ opacity: Double, to image: CIImage) -> CIImage {
        guard opacity < 0.999 else { return image }
        let amount = max(0, min(1, opacity))
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: amount)
        return matrix.outputImage ?? image
    }

    /// NSImage → CGImage going through a TIFF representation. The standard
    /// `cgImage(forProposedRect:context:hints:)` path sometimes returns nil
    /// for vector images; the TIFF round-trip rasterises reliably.
    private static func bitmapCGImage(from image: NSImage) -> CGImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.cgImage
    }

    /// Extend the composition's overall duration to match the project's
    /// full timeline — including text/sticker/caption overlay clips that
    /// have no media in the AV composition. Adds an empty range on a video
    /// track so AVPlayer keeps ticking through the tail and the CIFilter
    /// handler still runs on those frames (which is where overlays get
    /// composited for export).
    private static func padCompositionToFullTimeline(
        composition: AVMutableComposition,
        project: Project,
        sharedVideoTrack: AVMutableCompositionTrack?
    ) {
        let timelineEnd = CMTime(seconds: project.timeline.duration, preferredTimescale: 600)
        let currentEnd = composition.duration
        guard CMTimeCompare(timelineEnd, currentEnd) > 0 else { return }
        let padDuration = CMTimeSubtract(timelineEnd, currentEnd)

        // Stretch the trailing microframe of the shared video track to
        // cover the gap. Holding the last frame on-screen is a much more
        // reliable way to extend composition.duration than
        // `insertEmptyTimeRange`, which is documented to extend a track
        // only when it already has an edit at the insertion point and is
        // routinely flaky in practice. Audio tracks are independent and
        // untouched.
        if let shared = sharedVideoTrack,
           CMTimeCompare(shared.timeRange.duration, .zero) > 0 {
            let microSlice = CMTime(value: 1, timescale: 600) // ~1.6ms
            let trackEnd = CMTimeAdd(shared.timeRange.start, shared.timeRange.duration)
            if CMTimeCompare(shared.timeRange.duration, microSlice) > 0 {
                let sliceStart = CMTimeSubtract(trackEnd, microSlice)
                let sliceRange = CMTimeRange(start: sliceStart, duration: microSlice)
                let newSliceDuration = CMTimeAdd(microSlice, padDuration)
                shared.scaleTimeRange(sliceRange, toDuration: newSliceDuration)
                return
            }
        }

        // Audio-only / overlay-only fallback: nothing to stretch — extend
        // an audio track's edit list with empty time instead so
        // composition.duration grows.
        if let audioTrack = composition.tracks(withMediaType: .audio).first {
            audioTrack.insertEmptyTimeRange(CMTimeRange(start: currentEnd, duration: padDuration))
        }
    }

    /// Compute the union of voiceover clip time ranges in the project. Used
    /// by audio ducking to fade non-voiceover audio down whenever any
    /// voiceover clip is playing.
    private static func voiceoverRanges(in project: Project) -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        for track in project.timeline.tracks where !track.isHidden {
            for clip in track.clips where clip.isVoiceover {
                ranges.append(clip.timeRange.cmTimeRange)
            }
        }
        return ranges
    }

    private func insertClip(
        _ clip: Clip,
        asset: AVURLAsset,
        kind: Track.Kind,
        isMuted: Bool,
        into composition: AVMutableComposition,
        sharedVideoTrack: inout AVMutableCompositionTrack?,
        clipTransforms: inout [ClipVideoTransform],
        audioParams: inout [AVMutableAudioMixInputParameters]
    ) async throws {
        let startCMTime = CMTime(seconds: clip.timeRange.start, preferredTimescale: 600)
        let sourceCMRange = clip.sourceRange.cmTimeRange
        let displayDuration = CMTime(seconds: clip.timeRange.duration, preferredTimescale: 600)
        let needsScale = abs(clip.timeRange.duration - clip.sourceRange.duration) > 0.001
        let speedSegments = Self.speedSegments(for: clip)

        // Video — only for non-audio tracks.
        if kind != .audio {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)

            if let sourceVideo = videoTracks.first {
                if sharedVideoTrack == nil {
                    sharedVideoTrack = composition.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }

                if let segments = speedSegments {
                    // Speed ramp: insert each piecewise sub-segment and
                    // scale it to the display duration that segment
                    // contributes. Scalar `speed` is implicit in each
                    // segment's average multiplier.
                    try Self.insertSpeedRampedSegments(
                        segments: segments,
                        clip: clip,
                        sourceTrack: sourceVideo,
                        compositionTrack: sharedVideoTrack,
                        compositionStart: startCMTime
                    )
                } else {
                    try sharedVideoTrack?.insertTimeRange(sourceCMRange, of: sourceVideo, at: startCMTime)
                    if needsScale {
                        let insertedRange = CMTimeRange(start: startCMTime, duration: sourceCMRange.duration)
                        sharedVideoTrack?.scaleTimeRange(insertedRange, toDuration: displayDuration)
                    }
                }

                // Snapshot this clip's source preferredTransform + natural
                // size so the CIFilter handler can orient its frames
                // correctly.
                let transform = try await sourceVideo.load(.preferredTransform)
                let natural = try await sourceVideo.load(.naturalSize)
                clipTransforms.append(ClipVideoTransform(
                    start: clip.timeRange.start,
                    end: clip.timeRange.end,
                    transform: transform,
                    naturalSize: natural
                ))
            }
        }

        // Audio — one track per clip so volumes mix independently.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let sourceAudio = audioTracks.first {
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            if let segments = speedSegments {
                try Self.insertSpeedRampedSegments(
                    segments: segments,
                    clip: clip,
                    sourceTrack: sourceAudio,
                    compositionTrack: audioTrack,
                    compositionStart: startCMTime
                )
            } else {
                try audioTrack?.insertTimeRange(sourceCMRange, of: sourceAudio, at: startCMTime)
                if needsScale {
                    let insertedRange = CMTimeRange(start: startCMTime, duration: sourceCMRange.duration)
                    audioTrack?.scaleTimeRange(insertedRange, toDuration: displayDuration)
                }
            }
            if let audioTrack {
                let params = AVMutableAudioMixInputParameters(track: audioTrack)
                params.setVolume(clip.volume, at: .zero)
                audioParams.append(params)
            }
        }
    }

    /// One piecewise segment of a speed ramp. `sourceRange` is in the
    /// source asset's coordinate space; `displayDuration` is how long that
    /// chunk should occupy on the composition timeline.
    fileprivate struct SpeedSegment {
        let sourceRange: CMTimeRange
        let displayDuration: CMTime
    }

    /// Slice a clip's source range into N piecewise-constant speed
    /// segments using the keyframe curve. Returns nil when the clip has
    /// no ramp (caller falls back to scalar-speed scaleTimeRange).
    fileprivate static func speedSegments(for clip: Clip) -> [SpeedSegment]? {
        guard let keyframes = clip.speedKeyframes, !keyframes.isEmpty else { return nil }
        let anchored = Clip.anchoredKeyframes(keyframes, sourceDuration: clip.sourceRange.duration)
        guard anchored.count >= 2 else { return nil }

        // Sample N evenly-spaced sub-segments across the source range.
        // 32 is fine for typical 1–30s clips — enough resolution that
        // linear-interp ramps look smooth, but cheap enough at composition
        // build time that even long clips don't blow the budget.
        let segmentCount = 32
        let sourceStart = clip.sourceRange.start
        let sourceDuration = clip.sourceRange.duration
        let dt = sourceDuration / Double(segmentCount)
        var segments: [SpeedSegment] = []
        segments.reserveCapacity(segmentCount)

        for i in 0..<segmentCount {
            let localStart = Double(i) * dt
            let localEnd = localStart + dt
            // Average multiplier across this sub-segment (sample at
            // midpoint of each end's interpolated rate).
            let rateStart = Self.interpolatedRate(at: localStart, keyframes: anchored)
            let rateEnd = Self.interpolatedRate(at: localEnd, keyframes: anchored)
            let avgRate = (rateStart + rateEnd) / 2
            let displaySeconds = dt / max(0.01, avgRate)
            let sourceCMStart = CMTime(seconds: sourceStart + localStart, preferredTimescale: 600)
            let sourceCMDur = CMTime(seconds: dt, preferredTimescale: 600)
            segments.append(SpeedSegment(
                sourceRange: CMTimeRange(start: sourceCMStart, duration: sourceCMDur),
                displayDuration: CMTime(seconds: displaySeconds, preferredTimescale: 600)
            ))
        }
        return segments
    }

    private static func interpolatedRate(at time: TimeInterval, keyframes: [SpeedKeyframe]) -> Double {
        // Linear interpolation between bracketing keyframes.
        guard let first = keyframes.first else { return 1.0 }
        if time <= first.time { return first.multiplier }
        guard let last = keyframes.last else { return 1.0 }
        if time >= last.time { return last.multiplier }
        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i]
            let b = keyframes[i + 1]
            if time >= a.time && time <= b.time {
                let span = max(0.001, b.time - a.time)
                let t = (time - a.time) / span
                return a.multiplier + (b.multiplier - a.multiplier) * t
            }
        }
        return last.multiplier
    }

    fileprivate static func insertSpeedRampedSegments(
        segments: [SpeedSegment],
        clip: Clip,
        sourceTrack: AVAssetTrack,
        compositionTrack: AVMutableCompositionTrack?,
        compositionStart: CMTime
    ) throws {
        guard let compositionTrack else { return }
        var cursor = compositionStart
        for segment in segments {
            try compositionTrack.insertTimeRange(segment.sourceRange, of: sourceTrack, at: cursor)
            let insertedRange = CMTimeRange(start: cursor, duration: segment.sourceRange.duration)
            // Only scale when the display duration meaningfully differs
            // from the source slice's own duration — saves AVFoundation
            // from re-encoding when the user's ramp passes through 1×.
            if abs(segment.displayDuration.seconds - segment.sourceRange.duration.seconds) > 0.001 {
                compositionTrack.scaleTimeRange(insertedRange, toDuration: segment.displayDuration)
            }
            cursor = CMTimeAdd(cursor, segment.displayDuration)
        }
    }
}

/// Resolves a `MediaAsset` to its on-disk URL, handling security-scoped bookmarks.
protocol AssetResolver: Sendable {
    func resolve(_ asset: MediaAsset) async throws -> URL
}
