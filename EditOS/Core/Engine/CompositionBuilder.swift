import AVFoundation
import CoreGraphics
import Foundation
import OSLog

/// Result of compositing a project into AVFoundation primitives.
struct CompositionResult: Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
}

/// Builds an `AVComposition` (and matching `AVVideoComposition` / `AVAudioMix`)
/// from a `Project`.
///
/// Layout:
/// - One composition video track *per clip*, so each clip can carry its own
///   `preferredTransform` and aspect-fit scaling via a layer instruction. This
///   is what makes clips render at their native aspect ratio inside the
///   project canvas (vertical clips letterbox, etc.) instead of stretching to
///   share a single track's transform.
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
        var audioParams: [AVMutableAudioMixInputParameters] = []
        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []

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

        for entry in entries {
            let clip = entry.clip
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
                Self.log.error("Missing asset \(clip.assetID, privacy: .public) for clip \(clip.id, privacy: .public)")
                continue
            }
            do {
                let url = try await assetResolver.resolve(asset)
                try await insertClip(
                    clip,
                    asset: AVURLAsset(url: url),
                    kind: entry.kind,
                    isMuted: entry.isMuted,
                    canvasSize: project.canvas.size,
                    into: composition,
                    audioParams: &audioParams,
                    layerInstructions: &layerInstructions
                )
            } catch {
                Self.log.error("Failed to insert clip \(clip.id, privacy: .public) (\(asset.displayName, privacy: .public)): \(String(describing: error), privacy: .public)")
                continue
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

        let videoComp = makeVideoComposition(
            duration: composition.duration,
            canvas: project.canvas,
            layerInstructions: layerInstructions
        )

        Self.log.info("Built composition: duration \(composition.duration.seconds, privacy: .public)s, \(composition.tracks.count, privacy: .public) tracks, \(layerInstructions.count, privacy: .public) video layers, \(audioParams.count, privacy: .public) audio params")
        return CompositionResult(
            composition: composition.copy() as! AVComposition,
            videoComposition: videoComp,
            audioMix: mix
        )
    }

    private func insertClip(
        _ clip: Clip,
        asset: AVURLAsset,
        kind: Track.Kind,
        isMuted: Bool,
        canvasSize: CGSize,
        into composition: AVMutableComposition,
        audioParams: inout [AVMutableAudioMixInputParameters],
        layerInstructions: inout [AVMutableVideoCompositionLayerInstruction]
    ) async throws {
        let startCMTime = CMTime(seconds: clip.timeRange.start, preferredTimescale: 600)
        let sourceCMRange = clip.sourceRange.cmTimeRange
        let displayDuration = CMTime(seconds: clip.timeRange.duration, preferredTimescale: 600)
        let needsScale = abs(clip.timeRange.duration - clip.sourceRange.duration) > 0.001

        // Video — only for non-audio tracks.
        if kind != .audio {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let sourceVideo = videoTracks.first,
               let videoTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try videoTrack.insertTimeRange(sourceCMRange, of: sourceVideo, at: startCMTime)

                let naturalSize = try await sourceVideo.load(.naturalSize)
                let preferred = try await sourceVideo.load(.preferredTransform)
                let aspectFit = Self.aspectFitTransform(
                    naturalSize: naturalSize,
                    preferred: preferred,
                    canvas: canvasSize
                )

                if needsScale {
                    let insertedRange = CMTimeRange(start: startCMTime, duration: sourceCMRange.duration)
                    videoTrack.scaleTimeRange(insertedRange, toDuration: displayDuration)
                }

                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                layer.setTransform(aspectFit, at: .zero)
                // Track only carries video for [startCMTime, clipEnd) — clamp
                // opacity to that range so an overlay or out-of-range frame
                // doesn't leak previous content.
                let clipEnd = CMTimeAdd(startCMTime, displayDuration)
                if startCMTime > .zero {
                    layer.setOpacity(0, at: .zero)
                    layer.setOpacity(1, at: startCMTime)
                }
                layer.setOpacity(0, at: clipEnd)
                layerInstructions.append(layer)
            }
        }

        // Audio — one track per clip so volumes mix independently.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let sourceAudio = audioTracks.first {
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            try audioTrack?.insertTimeRange(sourceCMRange, of: sourceAudio, at: startCMTime)
            if needsScale {
                let insertedRange = CMTimeRange(start: startCMTime, duration: sourceCMRange.duration)
                audioTrack?.scaleTimeRange(insertedRange, toDuration: displayDuration)
            }
            if let audioTrack {
                let params = AVMutableAudioMixInputParameters(track: audioTrack)
                params.setVolume(isMuted ? 0 : clip.volume, at: .zero)
                audioParams.append(params)
            }
        }
    }

    private func makeVideoComposition(
        duration: CMTime,
        canvas: CanvasFormat,
        layerInstructions: [AVMutableVideoCompositionLayerInstruction]
    ) -> AVVideoComposition? {
        guard !layerInstructions.isEmpty, duration > .zero else { return nil }

        let comp = AVMutableVideoComposition()
        comp.renderSize = canvas.size
        let fps = max(1, canvas.frameRate)
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        instruction.layerInstructions = layerInstructions
        comp.instructions = [instruction]

        return comp.copy() as? AVVideoComposition
    }

    /// Transform that orients a clip's source frame and scales it to fit the
    /// project canvas without cropping (aspect-fit, centered). Preserves the
    /// source's native aspect ratio — letterboxing/pillarboxing fills the gaps.
    static func aspectFitTransform(
        naturalSize: CGSize,
        preferred: CGAffineTransform,
        canvas: CGSize
    ) -> CGAffineTransform {
        // Where the source rect lands after the preferredTransform — this
        // captures any rotation/flip the source asset specifies.
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let displaySize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard displaySize.width > 0, displaySize.height > 0 else { return preferred }

        let scale = min(canvas.width / displaySize.width, canvas.height / displaySize.height)
        let scaledWidth = displaySize.width * scale
        let scaledHeight = displaySize.height * scale
        let dx = (canvas.width - scaledWidth) / 2 - oriented.origin.x * scale
        let dy = (canvas.height - scaledHeight) / 2 - oriented.origin.y * scale

        return preferred
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
    }
}

/// Resolves a `MediaAsset` to its on-disk URL, handling security-scoped bookmarks.
protocol AssetResolver: Sendable {
    func resolve(_ asset: MediaAsset) async throws -> URL
}
