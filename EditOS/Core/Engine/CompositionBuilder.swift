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

        // Crossfade pre-pass (#1) — for each adjacent pair of video
        // clips on the same track that's marked for a `.crossfade`
        // transition, pre-render the blend into a cached .mov via
        // TransitionCache. We then trim half of `transition.duration`
        // off each clip's composition contribution and slot the
        // rendered .mov into the gap, so the live render gets a true
        // pixel blend without needing a custom AVVideoCompositing.
        //
        // Dip-to-black / dip-to-white still go through the existing
        // veil path in the CIFilter handler — they don't need the
        // multi-source machinery and the veil already nails the look.
        let crossfadePlan = await Self.planCrossfades(project: project, assetResolver: assetResolver)

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
                let leadingTrim = crossfadePlan.leadingTrim[clip.id] ?? 0
                let trailingTrim = crossfadePlan.trailingTrim[clip.id] ?? 0
                try await insertClip(
                    clip,
                    asset: AVURLAsset(url: url),
                    kind: entry.kind,
                    isMuted: entry.isMuted,
                    into: composition,
                    sharedVideoTrack: &sharedVideoTrack,
                    clipTransforms: &clipTransforms,
                    audioParams: &audioParams,
                    leadingTrim: leadingTrim,
                    trailingTrim: trailingTrim
                )
                if clip.isVoiceover, audioParams.count > countBefore,
                   let last = audioParams.last {
                    voiceoverParamIDs.insert(ObjectIdentifier(last))
                }
                // If this is the leading clip of a crossfade pair, drop
                // the cached transition .mov into the gap immediately
                // after — order matters because the next clip's
                // insertTimeRange will pick up at the track's end.
                if let insert = crossfadePlan.transitionAfter[clip.id] {
                    try await Self.appendTransitionMov(
                        insert: insert,
                        into: composition,
                        sharedVideoTrack: &sharedVideoTrack
                    )
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
        // multi-frame `RenderedOverlay`; the compositor picks the right
        // frame based on `compositionTime - clip.start`.
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
                            durations: rendered.durations, loops: rendered.loops
                        ))
                    }
                }
            default:
                continue
            }
        }

        // Snapshot fade-in / fade-out ranges per video clip so the
        // compositor can ramp opacity to / from black without walking
        // the project tree on each frame.
        var fades: [FadeRange] = []
        for track in project.timeline.tracks where track.kind == .video && !track.isHidden {
            for clip in track.clips {
                let duration = max(0.05, clip.fadeDuration)
                if clip.fadeIn {
                    fades.append(FadeRange(
                        start: clip.timeRange.start,
                        end: min(clip.timeRange.end, clip.timeRange.start + duration),
                        kind: .in,
                        dipColor: (0, 0, 0)
                    ))
                }
                if clip.fadeOut {
                    fades.append(FadeRange(
                        start: max(clip.timeRange.start, clip.timeRange.end - duration),
                        end: clip.timeRange.end,
                        kind: .out,
                        dipColor: (0, 0, 0)
                    ))
                }
            }
        }

        // Cross-clip dip transitions are rendered as a back-to-back
        // dip-out / dip-in pair around the cut. `.crossfade` pairs are
        // handled separately in the pre-render pass above — they get a
        // true pixel-blended `.mov` slotted into the timeline so we
        // skip them here (otherwise we'd composite a dip on top of an
        // already-blended frame).
        for track in project.timeline.tracks where track.kind == .video && !track.isHidden {
            let sortedClips = track.clips.sorted { $0.timeRange.start < $1.timeRange.start }
            for (idx, clip) in sortedClips.enumerated() {
                guard let transition = clip.transitionToNext else { continue }
                guard transition.kind != .crossfade else { continue }
                guard idx + 1 < sortedClips.count else { continue }
                let next = sortedClips[idx + 1]

                // Only meaningful when the clips actually abut (or are
                // close to it). Skip if there's a gap larger than 0.1s.
                guard abs(next.timeRange.start - clip.timeRange.end) < 0.1 else { continue }

                // Clamp so the dip never grows past either clip's bounds.
                let half = min(
                    transition.duration / 2,
                    clip.timeRange.duration * 0.5,
                    next.timeRange.duration * 0.5
                )
                guard half > 0.01 else { continue }

                let dipColor: (Double, Double, Double)
                switch transition.kind {
                case .dipToBlack: dipColor = (0, 0, 0)
                case .dipToWhite: dipColor = (1, 1, 1)
                case .crossfade:  continue   // handled by the cache
                }

                // Outgoing leg: clip's last `half` seconds ramp to dipColor.
                fades.append(FadeRange(
                    start: clip.timeRange.end - half,
                    end: clip.timeRange.end,
                    kind: .out,
                    dipColor: dipColor
                ))
                // Incoming leg: next clip's first `half` seconds ramp in.
                fades.append(FadeRange(
                    start: next.timeRange.start,
                    end: next.timeRange.start + half,
                    kind: .in,
                    dipColor: dipColor
                ))
            }
        }

        // Filter ranges — dedicated `.filter` tracks plus the legacy
        // per-video-clip filterPreset for older projects.
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

        let frameRate = max(1.0, project.canvas.frameRate)

        // #65 M1: per-frame work moved into `EditorCompositor`. We
        // build a single `EditorCompositionInstruction` covering the
        // whole composition (M2 will split per time range), wire the
        // custom compositor class, and return a manually-built
        // `AVMutableVideoComposition`.
        guard let firstVideoTrack = videoTracks.first else { return nil }
        let durationCM: CMTime
        do {
            durationCM = try await asset.load(.duration)
        } catch {
            Self.log.error("Failed to load composition duration: \(String(describing: error), privacy: .public)")
            return nil
        }
        let instruction = EditorCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: durationCM),
            trackIDs: [firstVideoTrack.trackID],
            canvasSize: canvasSize,
            clipTransforms: clipTransforms,
            fades: fades,
            filters: filters,
            overlays: overlays
        )

        let videoComp = AVMutableVideoComposition()
        videoComp.customVideoCompositorClass = EditorCompositor.self
        videoComp.instructions = [instruction]
        videoComp.renderSize = canvasSize
        videoComp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        return videoComp
    }

    // MARK: - Overlay rasterisation

    /// Frames + per-frame durations for an overlay. Static overlays return
    /// a single frame and an empty durations array.
    struct RenderedOverlay: Sendable {
        let frames: [CIImage]
        let durations: [TimeInterval]
        /// Animated stickers / GIFs loop forever. Text animations
        /// don't — they run once and latch the final frame for the
        /// remainder of the clip's range.
        let loops: Bool

        init(frames: [CIImage], durations: [TimeInterval], loops: Bool = true) {
            self.frames = frames
            self.durations = durations
            self.loops = loops
        }
    }

    /// Returns the positioned frames + durations for a text / sticker / SF
    /// Symbol clip, or nil if the clip isn't an overlay. Animated GIFs come
    /// back with a frame per encoded image and matching delay durations.
    /// Text clips with a `textAnimation` set come back as a sequence of
    /// frames covering the intro animation, plus one final frame for the
    /// post-animation static portion, with `loops = false` so the overlay
    /// instance latches the final frame instead of cycling.
    @MainActor
    private static func renderOverlay(for clip: Clip, canvas: CGSize) -> RenderedOverlay? {
        let dx = clip.transform.translation.width
        let dy = clip.transform.translation.height
        let opacity = max(0, min(1, clip.transform.opacity))

        if let text = clip.text {
            let size = clip.overlaySize ?? 64
            let color = clip.foregroundColor ?? .white
            if let animation = clip.textAnimation {
                return renderAnimatedTextOverlay(
                    text: text, fontSize: size, color: color,
                    canvas: canvas, dx: dx, dy: dy, opacity: opacity,
                    animation: animation
                )
            }
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

    /// Pre-rasterise the text animation as a sequence of frames sampled
    /// at ~30 fps across `animation.duration`, plus one final static
    /// frame for the remainder of the clip's range. Setting `loops` to
    /// `false` makes `OverlayInstance.image(at:)` latch onto that final
    /// frame after the animation finishes instead of cycling.
    @MainActor
    private static func renderAnimatedTextOverlay(
        text: String,
        fontSize: CGFloat,
        color: ColorRGBA,
        canvas: CGSize,
        dx: CGFloat,
        dy: CGFloat,
        opacity: Double,
        animation: TextAnimation
    ) -> RenderedOverlay? {
        let frameCount = max(2, Int(animation.duration * 30))
        let dtAnimation = animation.duration / Double(frameCount)

        var frames: [CIImage] = []
        var durations: [TimeInterval] = []

        for i in 0..<frameCount {
            let progress = Double(i + 1) / Double(frameCount)
            if let frame = renderTextFrame(
                text: text, fontSize: fontSize, color: color,
                canvas: canvas, dx: dx, dy: dy, opacity: opacity,
                animation: animation, progress: progress
            ) {
                frames.append(frame)
                durations.append(dtAnimation)
            }
        }

        // Final frame: full text, no animation effect, held for the
        // remainder of the clip. We don't know the clip's full duration
        // here so we pick a very-long hold value; `loops = false` makes
        // the overlay instance latch this frame instead of cycling.
        if let final = renderTextOverlay(
            text: text, fontSize: fontSize, color: color,
            canvas: canvas, dx: dx, dy: dy, opacity: opacity
        ) {
            frames.append(final)
            durations.append(86_400)  // 1 day — effectively "forever"
        }

        guard !frames.isEmpty else { return nil }
        return RenderedOverlay(frames: frames, durations: durations, loops: false)
    }

    /// Renders a single frame of the animation at `progress` ∈ [0, 1].
    /// The animation kinds vary which aspect of the text gets tweened:
    /// - `.typewriter` reveals characters one at a time.
    /// - `.fadeInWord` fades words in left-to-right.
    /// - `.slideFromBottom/Left/Right` tween position from off-canvas.
    /// - `.popBounce` scales 0 → 1 with overshoot.
    /// - `.scaleUp` linear scale 0 → 1.
    @MainActor
    private static func renderTextFrame(
        text: String,
        fontSize: CGFloat,
        color: ColorRGBA,
        canvas: CGSize,
        dx: CGFloat,
        dy: CGFloat,
        opacity: Double,
        animation: TextAnimation,
        progress: Double
    ) -> CIImage? {
        switch animation.kind {
        case .typewriter:
            let count = text.count
            let visibleCount = max(0, Int(Double(count) * progress))
            let visible = String(text.prefix(visibleCount))
            return renderTextOverlay(
                text: visible.isEmpty ? " " : visible,
                fontSize: fontSize, color: color,
                canvas: canvas, dx: dx, dy: dy, opacity: opacity
            )

        case .fadeInWord:
            // Fade each word in over its slice of the progress range.
            // The simplest convincing version: hold the *full* text and
            // ramp opacity linearly. For per-word control we'd need to
            // render each word separately, which is heavier; the linear
            // ramp reads as "fade-in" already.
            let eased = TextAnimation.easeOut(progress)
            return renderTextOverlay(
                text: text, fontSize: fontSize, color: color,
                canvas: canvas, dx: dx, dy: dy, opacity: opacity * eased
            )

        case .slideFromBottom:
            let eased = TextAnimation.easeOut(progress)
            let offset = canvas.height * 0.5 * (1 - eased)
            return renderTextOverlay(
                text: text, fontSize: fontSize, color: color,
                canvas: canvas, dx: dx, dy: dy + offset, opacity: opacity * eased
            )

        case .slideFromLeft:
            let eased = TextAnimation.easeOut(progress)
            let offset = canvas.width * 0.5 * (1 - eased)
            return renderTextOverlay(
                text: text, fontSize: fontSize, color: color,
                canvas: canvas, dx: dx - offset, dy: dy, opacity: opacity * eased
            )

        case .slideFromRight:
            let eased = TextAnimation.easeOut(progress)
            let offset = canvas.width * 0.5 * (1 - eased)
            return renderTextOverlay(
                text: text, fontSize: fontSize, color: color,
                canvas: canvas, dx: dx + offset, dy: dy, opacity: opacity * eased
            )

        case .popBounce:
            let scale = TextAnimation.easeOutBack(progress)
            // Render at the *scaled* font size; cheap approximation of
            // a scale transform that doesn't require CIImage warping.
            return renderTextOverlay(
                text: text, fontSize: max(1, fontSize * CGFloat(scale)),
                color: color, canvas: canvas, dx: dx, dy: dy,
                opacity: opacity * min(1, progress * 2)
            )

        case .scaleUp:
            let eased = TextAnimation.easeOut(progress)
            return renderTextOverlay(
                text: text, fontSize: max(1, fontSize * CGFloat(eased)),
                color: color, canvas: canvas, dx: dx, dy: dy,
                opacity: opacity * eased
            )
        }
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
        audioParams: inout [AVMutableAudioMixInputParameters],
        leadingTrim: TimeInterval = 0,
        trailingTrim: TimeInterval = 0
    ) async throws {
        // Crossfade transitions trim a slice off each side of the cut
        // (composition-side, not model-side). `leadingTrim` /
        // `trailingTrim` are in *timeline* seconds; we map them through
        // the clip's uniform speed ratio to the corresponding source
        // window so a 2× clip's trim costs half as much source.
        // Speed-ramp + crossfade are V1-incompatible — the segmented
        // inserter doesn't honour trims yet — so we fall back to a
        // single insert whenever trim is active.
        let timelineDur = max(0.001, clip.timeRange.duration)
        let sourceDur = max(0.001, clip.sourceRange.duration)
        let speedRatio = sourceDur / timelineDur
        let requestedTrim = leadingTrim + trailingTrim
        let safeTrim = min(
            requestedTrim,
            max(0, min(timelineDur, sourceDur) - 0.05)
        )
        let effectiveLeading: TimeInterval
        let effectiveTrailing: TimeInterval
        if requestedTrim > 0.0001, safeTrim < requestedTrim {
            // Clamped — proportion both ends so the centre of the trim
            // stays where the user asked.
            effectiveLeading = leadingTrim * (safeTrim / requestedTrim)
            effectiveTrailing = safeTrim - effectiveLeading
        } else {
            effectiveLeading = leadingTrim
            effectiveTrailing = trailingTrim
        }

        let leadingSourceTrim = effectiveLeading * speedRatio
        let trailingSourceTrim = effectiveTrailing * speedRatio
        let startCMTime = CMTime(seconds: clip.timeRange.start + effectiveLeading, preferredTimescale: 600)
        let sourceCMRange = CMTimeRange(
            start: CMTime(seconds: clip.sourceRange.start + leadingSourceTrim, preferredTimescale: 600),
            duration: CMTime(seconds: sourceDur - leadingSourceTrim - trailingSourceTrim, preferredTimescale: 600)
        )
        let displayDuration = CMTime(seconds: timelineDur - safeTrim, preferredTimescale: 600)
        let needsScale = abs(displayDuration.seconds - sourceCMRange.duration.seconds) > 0.001
        let speedSegments = (safeTrim > 0.001) ? nil : Self.speedSegments(for: clip)

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
                // correctly. When crossfade trim is in play, narrow the
                // range to the clip's composition contribution so the
                // handler doesn't try to apply this clip's transform to
                // the cached transition .mov frames that occupy the gap.
                let transform = try await sourceVideo.load(.preferredTransform)
                let natural = try await sourceVideo.load(.naturalSize)
                clipTransforms.append(ClipVideoTransform(
                    start: clip.timeRange.start + effectiveLeading,
                    end: clip.timeRange.end - effectiveTrailing,
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
                // When the clip has a gain envelope, emit a setVolumeRamp
                // per adjacent keyframe pair so AVFoundation interpolates
                // smoothly between them on playback / export. The ramps
                // are in *composition* time (clip.timeRange.start +
                // keyframe.time), since the audioMix lives on the
                // composition timeline. Falls back to the scalar volume
                // when no envelope is set so existing clips behave
                // identically.
                if let keyframes = clip.volumeKeyframes, !keyframes.isEmpty {
                    let anchored = Clip.anchoredVolumeKeyframes(
                        keyframes,
                        sourceDuration: clip.sourceRange.duration
                    )
                    for (a, b) in zip(anchored, anchored.dropFirst()) {
                        let startTime = CMTime(
                            seconds: clip.timeRange.start + a.time,
                            preferredTimescale: 600
                        )
                        let endTime = CMTime(
                            seconds: clip.timeRange.start + b.time,
                            preferredTimescale: 600
                        )
                        params.setVolumeRamp(
                            fromStartVolume: Float(a.gain) * clip.volume,
                            toEndVolume: Float(b.gain) * clip.volume,
                            timeRange: CMTimeRange(start: startTime, end: endTime)
                        )
                    }
                } else {
                    params.setVolume(clip.volume, at: .zero)
                }
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

    // MARK: - Crossfade pre-render (issue #1)

    /// Composition-side instructions for one crossfade pair. The lead
    /// clip's tail is trimmed by `duration / 2`, the trail clip's head
    /// by the same amount, and the cached `.mov` slots into the
    /// resulting gap.
    fileprivate struct CrossfadePlan: Sendable {
        var leadingTrim: [Clip.ID: TimeInterval] = [:]
        var trailingTrim: [Clip.ID: TimeInterval] = [:]
        /// Keyed by the *leading* clip's ID — produced right after the
        /// leading clip is inserted into the composition.
        var transitionAfter: [Clip.ID: TransitionInsert] = [:]
    }

    fileprivate struct TransitionInsert: Sendable {
        let url: URL
        let compositionStart: TimeInterval
        let duration: TimeInterval
    }

    /// Walk every visible video track, identify adjacent crossfade
    /// pairs, render their transitions via `TransitionCache` (in
    /// parallel via a task group), and return a `CrossfadePlan` keyed
    /// by clip ID. Pairs that fail to render fall back to no trim — the
    /// existing dip-veil path picks them up.
    fileprivate static func planCrossfades(
        project: Project,
        assetResolver: AssetResolver
    ) async -> CrossfadePlan {
        var pairs: [(lead: Clip, trail: Clip, duration: TimeInterval)] = []
        for track in project.timeline.tracks where !track.isHidden && track.kind == .video {
            let sorted = track.clips.sorted { $0.timeRange.start < $1.timeRange.start }
            for (idx, lead) in sorted.enumerated() {
                guard let transition = lead.transitionToNext,
                      transition.kind == .crossfade else { continue }
                guard idx + 1 < sorted.count else { continue }
                let trail = sorted[idx + 1]
                // Only render true crossfades when the clips actually
                // abut — gaps would need a dip-through-canvas which is
                // the veil path's job.
                guard abs(trail.timeRange.start - lead.timeRange.end) < 0.1 else { continue }
                // Clamp so the rendered transition can't be longer than
                // half of either clip's source — matches the existing
                // veil-path clamp so swapping kinds doesn't change the
                // visible duration.
                let safeDuration = min(
                    transition.duration,
                    lead.sourceRange.duration,
                    trail.sourceRange.duration
                )
                guard safeDuration > 0.05 else { continue }
                pairs.append((lead, trail, safeDuration))
            }
        }
        guard !pairs.isEmpty else { return CrossfadePlan() }

        // Render in parallel — each transition's I/O is independent.
        // Results join into the plan in any order; the keying by clip
        // ID makes that safe.
        var plan = CrossfadePlan()
        await withTaskGroup(of: (Clip.ID, Clip.ID, TimeInterval, URL?).self) { group in
            for pair in pairs {
                let lead = pair.lead
                let trail = pair.trail
                let duration = pair.duration
                group.addTask {
                    let url = await renderTransition(
                        lead: lead,
                        trail: trail,
                        duration: duration,
                        project: project,
                        assetResolver: assetResolver
                    )
                    return (lead.id, trail.id, duration, url)
                }
            }
            for await (leadID, trailID, duration, url) in group {
                guard let url else { continue }
                // Find lead clip again to get its timeline end — the
                // pair tuple isn't captured here because TaskGroup's
                // result is a value type.
                let leadTimelineEnd = pairs.first { $0.lead.id == leadID }?.lead.timeRange.end ?? 0
                let half = duration / 2
                plan.leadingTrim[trailID] = half
                plan.trailingTrim[leadID] = half
                plan.transitionAfter[leadID] = TransitionInsert(
                    url: url,
                    compositionStart: leadTimelineEnd - half,
                    duration: duration
                )
            }
        }
        return plan
    }

    /// Render the transition for one pair. Returns nil on any failure
    /// so the caller can fall through to the dip path — a broken
    /// transition shouldn't break the whole composition build.
    private static func renderTransition(
        lead: Clip,
        trail: Clip,
        duration: TimeInterval,
        project: Project,
        assetResolver: AssetResolver
    ) async -> URL? {
        guard
            let leadAsset = project.assets.first(where: { $0.id == lead.assetID }),
            let trailAsset = project.assets.first(where: { $0.id == trail.assetID })
        else { return nil }
        do {
            let leadURL = try await assetResolver.resolve(leadAsset)
            let trailURL = try await assetResolver.resolve(trailAsset)
            let request = TransitionCache.Request(
                leadURL: leadURL,
                trailURL: trailURL,
                leadEndSeconds: lead.sourceRange.end,
                trailStartSeconds: trail.sourceRange.start,
                duration: duration,
                canvasSize: project.canvas.size,
                frameRate: project.canvas.frameRate,
                kind: .crossfade
            )
            return try await TransitionCache.shared.transitionURL(for: request)
        } catch {
            Self.log.error("Crossfade render failed (lead=\(lead.id.uuidString, privacy: .public)): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Append a rendered transition `.mov` onto the shared video track
    /// at the planned composition time. Pulled out so the main loop
    /// stays readable.
    fileprivate static func appendTransitionMov(
        insert: TransitionInsert,
        into composition: AVMutableComposition,
        sharedVideoTrack: inout AVMutableCompositionTrack?
    ) async throws {
        let asset = AVURLAsset(url: insert.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { return }
        if sharedVideoTrack == nil {
            sharedVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        let assetDuration = try await asset.load(.duration).seconds
        let actualDuration = min(assetDuration, insert.duration)
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: actualDuration, preferredTimescale: 600)
        )
        let at = CMTime(seconds: insert.compositionStart, preferredTimescale: 600)
        try sharedVideoTrack?.insertTimeRange(range, of: track, at: at)
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
