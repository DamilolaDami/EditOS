import CoreGraphics
import Foundation

struct Project: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var canvas: CanvasFormat
    var assets: [MediaAsset]
    var timeline: Timeline
    /// Security-scoped bookmark to the project's cover image. Optional — when
    /// unset, the timeline shows an empty "+ Cover" slot.
    var coverBookmark: Data?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        canvas: CanvasFormat = .hd,
        assets: [MediaAsset] = [],
        timeline: Timeline = Timeline(),
        coverBookmark: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.canvas = canvas
        self.assets = assets
        self.timeline = timeline
        self.coverBookmark = coverBookmark
    }
}

struct CanvasFormat: Hashable, Sendable, Codable {
    var size: CGSize
    var frameRate: Double
    var backgroundColor: ColorRGBA

    static let hd = CanvasFormat(size: CGSize(width: 1920, height: 1080), frameRate: 30, backgroundColor: .black)
    static let uhd = CanvasFormat(size: CGSize(width: 3840, height: 2160), frameRate: 30, backgroundColor: .black)
    static let vertical = CanvasFormat(size: CGSize(width: 1080, height: 1920), frameRate: 30, backgroundColor: .black)
    static let square = CanvasFormat(size: CGSize(width: 1080, height: 1080), frameRate: 30, backgroundColor: .black)
}

struct ColorRGBA: Hashable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let black = ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1)
    static let white = ColorRGBA(red: 1, green: 1, blue: 1, alpha: 1)
    static let clear = ColorRGBA(red: 0, green: 0, blue: 0, alpha: 0)
}
