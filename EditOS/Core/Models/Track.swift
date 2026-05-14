import Foundation

struct Track: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var kind: Kind
    var clips: [Clip]
    var isLocked: Bool
    var isMuted: Bool
    var isHidden: Bool

    enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case video
        case audio
        case overlay
        case caption
        case sticker

        var displayName: String {
            switch self {
            case .video: "Video"
            case .audio: "Audio"
            case .overlay: "Overlay"
            case .caption: "Captions"
            case .sticker: "Stickers"
            }
        }
    }

    init(
        id: UUID = UUID(),
        kind: Kind,
        clips: [Clip] = [],
        isLocked: Bool = false,
        isMuted: Bool = false,
        isHidden: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.clips = clips
        self.isLocked = isLocked
        self.isMuted = isMuted
        self.isHidden = isHidden
    }
}
