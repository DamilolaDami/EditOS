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

    init(
        id: UUID = UUID(),
        assetID: MediaAsset.ID,
        timeRange: TimeRange,
        sourceRange: TimeRange,
        transform: ClipTransform = .identity,
        volume: Float = 1.0,
        speed: Double = 1.0,
        label: String? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.timeRange = timeRange
        self.sourceRange = sourceRange
        self.transform = transform
        self.volume = volume
        self.speed = speed
        self.label = label
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
