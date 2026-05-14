import CoreGraphics
import Foundation

/// A source file imported into a project. The on-disk URL is resolved through
/// a security-scoped bookmark so projects survive app relaunches under the sandbox.
struct MediaAsset: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var displayName: String
    var kind: Kind
    var duration: TimeInterval
    var nativeSize: CGSize?
    var frameRate: Double?
    var bookmark: Data?
    var importedAt: Date

    enum Kind: String, Hashable, Sendable, Codable {
        case video
        case audio
        case image
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        kind: Kind,
        duration: TimeInterval,
        nativeSize: CGSize? = nil,
        frameRate: Double? = nil,
        bookmark: Data? = nil,
        importedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.duration = duration
        self.nativeSize = nativeSize
        self.frameRate = frameRate
        self.bookmark = bookmark
        self.importedAt = importedAt
    }
}
