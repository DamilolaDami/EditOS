import AVFoundation
import Foundation
import OSLog

/// Result of compositing a project into AVFoundation primitives.
struct CompositionResult: Sendable {
    let composition: AVComposition
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
        var sharedVideoTrack: AVMutableCompositionTrack?
        var didSetVideoTransform = false
        var audioParams: [AVMutableAudioMixInputParameters] = []

        // Collect every visible (track, clip) pair, then insert in chronological
        // order so insertTimeRange's auto-push doesn't re-arrange already-placed
        // clips.
        var entries: [(kind: Track.Kind, clip: Clip)] = []
        for track in project.timeline.tracks where !track.isHidden {
            for clip in track.clips {
                entries.append((track.kind, clip))
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
                    into: composition,
                    sharedVideoTrack: &sharedVideoTrack,
                    didSetVideoTransform: &didSetVideoTransform,
                    audioParams: &audioParams
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
        Self.log.info("Built composition: duration \(composition.duration.seconds, privacy: .public)s, \(composition.tracks.count, privacy: .public) tracks, \(audioParams.count, privacy: .public) audio params")
        return CompositionResult(
            composition: composition.copy() as! AVComposition,
            audioMix: mix
        )
    }

    private func insertClip(
        _ clip: Clip,
        asset: AVURLAsset,
        kind: Track.Kind,
        into composition: AVMutableComposition,
        sharedVideoTrack: inout AVMutableCompositionTrack?,
        didSetVideoTransform: inout Bool,
        audioParams: inout [AVMutableAudioMixInputParameters]
    ) async throws {
        let startCMTime = CMTime(seconds: clip.timeRange.start, preferredTimescale: 600)
        let sourceCMRange = clip.sourceRange.cmTimeRange
        let displayDuration = CMTime(seconds: clip.timeRange.duration, preferredTimescale: 600)
        let needsScale = abs(clip.timeRange.duration - clip.sourceRange.duration) > 0.001

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
                try sharedVideoTrack?.insertTimeRange(sourceCMRange, of: sourceVideo, at: startCMTime)
                if !didSetVideoTransform {
                    sharedVideoTrack?.preferredTransform = try await sourceVideo.load(.preferredTransform)
                    didSetVideoTransform = true
                }
                if needsScale {
                    let insertedRange = CMTimeRange(start: startCMTime, duration: sourceCMRange.duration)
                    sharedVideoTrack?.scaleTimeRange(insertedRange, toDuration: displayDuration)
                }
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
                params.setVolume(clip.volume, at: .zero)
                audioParams.append(params)
            }
        }
    }
}

/// Resolves a `MediaAsset` to its on-disk URL, handling security-scoped bookmarks.
protocol AssetResolver: Sendable {
    func resolve(_ asset: MediaAsset) async throws -> URL
}
