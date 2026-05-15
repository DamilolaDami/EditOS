import AVFoundation
import CoreImage
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
        var sharedVideoTrack: AVMutableCompositionTrack?
        var didSetVideoTransform = false
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
                try await insertClip(
                    clip,
                    asset: AVURLAsset(url: url),
                    kind: entry.kind,
                    isMuted: entry.isMuted,
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
        let avComposition = composition.copy() as! AVComposition
        let videoComposition = await Self.buildFilterComposition(for: project, asset: avComposition)
        Self.log.info("Built composition: duration \(composition.duration.seconds, privacy: .public)s, \(composition.tracks.count, privacy: .public) tracks, \(audioParams.count, privacy: .public) audio params, videoComp \(videoComposition != nil, privacy: .public)")
        return CompositionResult(
            composition: avComposition,
            videoComposition: videoComposition,
            audioMix: mix
        )
    }

    /// Builds an `AVVideoComposition` that runs CIFilter chains based on
    /// filter clips placed on dedicated `.filter` tracks. Each filter clip
    /// carries a `filterPreset` id and an intensity; the per-frame closure
    /// looks up the active filter clip(s) at `request.compositionTime`.
    /// Returns nil when no filter clip exists so the player skips CI entirely.
    private static func buildFilterComposition(
        for project: Project,
        asset: AVAsset
    ) async -> AVVideoComposition? {
        // Snapshot the filter ranges up-front so the hot path stays cheap.
        struct FilteredRange: Sendable {
            let start: TimeInterval
            let end: TimeInterval
            let presetID: String
            let intensity: Double
        }
        var ranges: [FilteredRange] = []

        // 1) Filter tracks — the primary path now. Filter clips on dedicated
        // lanes affect whatever video is beneath them during their
        // timeRange — same model as overlay clips.
        for track in project.timeline.tracks where track.kind == .filter && !track.isHidden {
            for clip in track.clips {
                guard let preset = clip.filterPreset, preset != "none" else { continue }
                ranges.append(
                    FilteredRange(
                        start: clip.timeRange.start,
                        end: clip.timeRange.end,
                        presetID: preset,
                        intensity: clip.filterIntensity ?? 1.0
                    )
                )
            }
        }

        // 2) Legacy per-clip filters set via `Clip.filterPreset` on video
        // tracks still render (backward compat for projects saved with the
        // earlier filter model).
        for track in project.timeline.tracks where track.kind == .video && !track.isHidden {
            for clip in track.clips {
                guard let preset = clip.filterPreset, preset != "none" else { continue }
                ranges.append(
                    FilteredRange(
                        start: clip.timeRange.start,
                        end: clip.timeRange.end,
                        presetID: preset,
                        intensity: clip.filterIntensity ?? 1.0
                    )
                )
            }
        }
        guard !ranges.isEmpty else { return nil }

        do {
            return try await AVVideoComposition.videoComposition(with: asset) { request in
                let source = request.sourceImage
                let t = request.compositionTime.seconds
                // First range covering this time wins. Video clips don't
                // overlap on a single timeline track, so at most one matches.
                if let range = ranges.first(where: { t >= $0.start && t < $0.end }) {
                    let filtered = FilterCatalog.apply(
                        presetID: range.presetID,
                        intensity: range.intensity,
                        to: source
                    )
                    request.finish(with: filtered.cropped(to: source.extent), context: nil)
                } else {
                    request.finish(with: source, context: nil)
                }
            }
        } catch {
            Self.log.error("Failed to build filter video composition: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func insertClip(
        _ clip: Clip,
        asset: AVURLAsset,
        kind: Track.Kind,
        isMuted: Bool,
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
