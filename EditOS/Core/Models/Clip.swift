import CoreGraphics
import Foundation

/// A trimmed reference to a `MediaAsset`, positioned on a `Track`.
struct Clip: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var assetID: MediaAsset.ID
    /// Position on the timeline (project time).
    var timeRange: TimeRange
    /// Selected portion of the asset's source media.
    var sourceRange: TimeRange
    var transform: ClipTransform
    var volume: Float
    var speed: Double
    var label: String?

    // MARK: - Overlay payload

    /// Text content when the clip lives on a `.caption` track. Optional so
    /// media clips can ignore it.
    var text: String?
    /// SF Symbol name when the clip lives on a `.sticker` track.
    var stickerSymbol: String?
    /// Absolute file path to a downloaded sticker image (e.g. a GIPHY GIF).
    /// Takes precedence over `stickerSymbol` when present.
    var stickerImagePath: String?
    /// Color used by text/sticker clips when rendering on the canvas.
    var foregroundColor: ColorRGBA?
    /// Font / sticker size in canvas points.
    var overlaySize: CGFloat?
    /// Identifier of a `FilterCatalog` preset applied to this clip. `nil`
    /// means no filter (raw source).
    var filterPreset: String?
    /// Filter strength in 0…1. Filters blend with the original at lower
    /// values so the user can dial in subtlety.
    var filterIntensity: Double?
    /// Fade-in at the clip's leading edge — black → source.
    var fadeIn: Bool = false
    /// Fade-out at the clip's trailing edge — source → black.
    var fadeOut: Bool = false
    /// Duration in seconds for each fade (default 0.5s).
    var fadeDuration: TimeInterval = 0.5
    /// Marks audio clips recorded as voiceover. Drives audio ducking — any
    /// non-voiceover music tracks dim during a voiceover clip's range.
    var isVoiceover: Bool = false
    /// Optional speed-ramp curve. When set, overrides the scalar `speed`
    /// and varies playback rate piecewise across the clip's source range.
    /// Keyframe times are in source-clip-local seconds (0…sourceRange.duration);
    /// `multiplier` is the playback rate at that time (e.g. 2.0 = 2×).
    /// Between keyframes the rate interpolates linearly.
    var speedKeyframes: [SpeedKeyframe]? = nil
    /// Transition between this clip and the next on the same track.
    /// `nil` means the clips abut with a hard cut. When set, the
    /// composition pipeline overlaps the next clip's leading edge with
    /// this clip's trailing edge by `transitionToNext.duration` seconds
    /// and blends per `transitionToNext.kind`.
    var transitionToNext: Transition? = nil
    /// Optional gain envelope. When set, audio playback follows the
    /// piecewise-linear curve between keyframes instead of the scalar
    /// `volume`. Keyframe times are in source-clip-local seconds
    /// (0…sourceRange.duration); `gain` is 0…2 (1 = unity, 2 = +6 dB).
    /// Between keyframes the gain interpolates linearly — AVFoundation's
    /// `setVolumeRamp(fromStartVolume:toEndVolume:timeRange:)` ramps each
    /// segment natively.
    var volumeKeyframes: [VolumeKeyframe]? = nil
    /// Optional kinetic-typography animation. Runs across the first
    /// `textAnimation.duration` seconds of the clip's time range; the
    /// text then stays static for the rest of the clip.
    var textAnimation: TextAnimation? = nil
    /// PIP frame metadata. Populated when a media video clip lives on
    /// an `.overlay` track and should render as a picture-in-picture
    /// rectangle on top of the underlying base video. Coordinates are
    /// normalised against the project canvas (0…1) so the frame
    /// scales cleanly across canvas sizes.
    ///
    /// V1 stores the metadata; full preview + export rendering is the
    /// remaining scope on #15.
    var pipFrame: PipFrame? = nil

    init(
        id: UUID = UUID(),
        assetID: MediaAsset.ID,
        timeRange: TimeRange,
        sourceRange: TimeRange,
        transform: ClipTransform = .identity,
        volume: Float = 1.0,
        speed: Double = 1.0,
        label: String? = nil,
        text: String? = nil,
        stickerSymbol: String? = nil,
        stickerImagePath: String? = nil,
        foregroundColor: ColorRGBA? = nil,
        overlaySize: CGFloat? = nil,
        filterPreset: String? = nil,
        filterIntensity: Double? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.timeRange = timeRange
        self.sourceRange = sourceRange
        self.transform = transform
        self.volume = volume
        self.speed = speed
        self.label = label
        self.text = text
        self.stickerSymbol = stickerSymbol
        self.stickerImagePath = stickerImagePath
        self.foregroundColor = foregroundColor
        self.overlaySize = overlaySize
        self.filterPreset = filterPreset
        self.filterIntensity = filterIntensity
    }
}

extension Clip {
    /// What kind of clip this is — drives Inspector layout, timeline cell
    /// rendering, and composition behaviour. Determined from the payload
    /// fields rather than stored separately so older projects keep working.
    enum Kind: Sendable {
        case media
        case text
        case sticker
        case filter
    }

    var kind: Kind {
        if text != nil { return .text }
        if stickerSymbol != nil || stickerImagePath != nil { return .sticker }
        if filterPreset != nil { return .filter }
        return .media
    }
}

/// One control point in a clip's speed ramp curve.
/// `time` is measured in source-clip-local seconds (0 to sourceRange.duration);
/// `multiplier` is the desired playback rate at that point. The
/// CompositionBuilder samples this curve when slicing the source into
/// piecewise `scaleTimeRange` segments.
struct SpeedKeyframe: Hashable, Sendable, Codable {
    var time: TimeInterval
    var multiplier: Double

    init(time: TimeInterval, multiplier: Double) {
        self.time = max(0, time)
        // Clamp to a sane range. Below 0.1× plays back as still-frame +
        // duplicates frames; above 8× starts losing audio quality and
        // is rarely useful in a consumer editor.
        self.multiplier = max(0.1, min(8.0, multiplier))
    }
}

extension Clip {
    /// The display duration this clip *should* occupy on the timeline,
    /// given its speed ramp (if any). When no ramp is set, falls back to
    /// `sourceRange.duration / speed` (the scalar-speed behaviour).
    /// Use this when ripple-pushing follow-on clips after the user edits
    /// the speed curve.
    func effectiveDisplayDuration() -> TimeInterval {
        guard let keyframes = speedKeyframes, !keyframes.isEmpty else {
            return sourceRange.duration / max(0.01, speed)
        }
        // Display duration is ∫(1/multiplier) ds across the source range.
        // We approximate with trapezoidal integration over the sorted
        // keyframe points anchored at 0 and sourceRange.duration.
        let anchored = Self.anchoredKeyframes(keyframes, sourceDuration: sourceRange.duration)
        var total: TimeInterval = 0
        for i in 0..<(anchored.count - 1) {
            let a = anchored[i]
            let b = anchored[i + 1]
            let segment = b.time - a.time
            let avgInverseRate = (1.0 / a.multiplier + 1.0 / b.multiplier) / 2
            total += segment * avgInverseRate
        }
        return total
    }

    /// Returns the keyframe list with synthetic endpoints clamped to
    /// `[0, sourceDuration]` so the integration / segment-splitting math
    /// always sees a complete domain.
    static func anchoredKeyframes(_ keyframes: [SpeedKeyframe], sourceDuration: TimeInterval) -> [SpeedKeyframe] {
        let sorted = keyframes.sorted { $0.time < $1.time }
        var result: [SpeedKeyframe] = []
        if let first = sorted.first, first.time > 0.001 {
            result.append(SpeedKeyframe(time: 0, multiplier: first.multiplier))
        }
        result.append(contentsOf: sorted.filter { $0.time >= 0 && $0.time <= sourceDuration })
        if let last = result.last, last.time < sourceDuration - 0.001 {
            result.append(SpeedKeyframe(time: sourceDuration, multiplier: last.multiplier))
        }
        if result.isEmpty {
            result = [
                SpeedKeyframe(time: 0, multiplier: 1.0),
                SpeedKeyframe(time: sourceDuration, multiplier: 1.0)
            ]
        }
        return result
    }
}

/// One control point in a clip's gain envelope.
/// `time` is measured in source-clip-local seconds (0 to
/// sourceRange.duration); `gain` is 0…2 (1.0 = unity, 0 = mute,
/// 2.0 ≈ +6 dB). The composition pipeline emits a `setVolumeRamp`
/// between every adjacent pair of keyframes so audio fades smoothly
/// between control points.
struct VolumeKeyframe: Hashable, Sendable, Codable, Identifiable {
    let id: UUID
    var time: TimeInterval
    var gain: Double

    init(id: UUID = UUID(), time: TimeInterval, gain: Double) {
        self.id = id
        self.time = max(0, time)
        // Clamp so a misclick in the UI can't drive AVFoundation into
        // negative-gain territory or absurd boosts that clip.
        self.gain = max(0, min(2.0, gain))
    }
}

extension Clip {
    /// Returns the keyframe list with synthetic endpoints clamped to
    /// `[0, sourceDuration]` so callers (composition pipeline, UI)
    /// always see a complete domain. Each end-anchor inherits the
    /// nearest user-placed keyframe's gain so the envelope is flat
    /// (no surprise dip) outside the placed control points.
    static func anchoredVolumeKeyframes(
        _ keyframes: [VolumeKeyframe],
        sourceDuration: TimeInterval
    ) -> [VolumeKeyframe] {
        let sorted = keyframes.sorted { $0.time < $1.time }
        var result: [VolumeKeyframe] = []
        if let first = sorted.first, first.time > 0.001 {
            result.append(VolumeKeyframe(time: 0, gain: first.gain))
        }
        result.append(contentsOf: sorted.filter { $0.time >= 0 && $0.time <= sourceDuration })
        if let last = result.last, last.time < sourceDuration - 0.001 {
            result.append(VolumeKeyframe(time: sourceDuration, gain: last.gain))
        }
        if result.isEmpty {
            result = [
                VolumeKeyframe(time: 0, gain: 1.0),
                VolumeKeyframe(time: sourceDuration, gain: 1.0)
            ]
        }
        return result
    }
}

/// Picture-in-picture frame. All values are normalised in `0…1`
/// against the project canvas — `origin` is the PIP rectangle's
/// top-left in canvas-space, `size` is the rectangle's width/height
/// in canvas-space. The composition pipeline reads this to position +
/// scale the overlay video on top of the base video.
struct PipFrame: Hashable, Sendable, Codable {
    var origin: CGPoint
    var size: CGSize
    /// Corner radius in *canvas points* (not normalised — radii read
    /// more intuitively in absolute units).
    var cornerRadius: CGFloat
    /// Border thickness in canvas points. `0` = no border.
    var borderWidth: CGFloat
    /// Border colour (RGBA, 0…1). Optional so older projects without
    /// this field keep decoding.
    var borderColor: ColorRGBA?

    /// Default frame for a fresh camera PIP — 25%×25% pinned to the
    /// bottom-right of the canvas with a small margin and a subtle
    /// rounded edge.
    static let bottomRight = PipFrame(
        origin: CGPoint(x: 0.72, y: 0.72),
        size: CGSize(width: 0.25, height: 0.25),
        cornerRadius: 12,
        borderWidth: 0,
        borderColor: nil
    )
}

struct ClipTransform: Hashable, Sendable, Codable {
    var translation: CGSize
    var scale: CGFloat
    /// Rotation in radians.
    var rotation: Double
    var opacity: Double

    static let identity = ClipTransform(
        translation: .zero,
        scale: 1.0,
        rotation: 0,
        opacity: 1.0
    )
}
