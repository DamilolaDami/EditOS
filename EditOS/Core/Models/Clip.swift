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
