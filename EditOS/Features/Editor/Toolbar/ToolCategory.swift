import Foundation

enum ToolCategory: String, Hashable, CaseIterable, Identifiable {
    case media
    case audio
    case text
    case stickers
    case effects
    case transitions
    case captions
    case filters
    case adjustment
    case templates
    case aiAvatar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .media: "Media"
        case .audio: "Audio"
        case .text: "Text"
        case .stickers: "Stickers"
        case .effects: "Effects"
        case .transitions: "Transitions"
        case .captions: "Captions"
        case .filters: "Filters"
        case .adjustment: "Adjustment"
        case .templates: "Templates"
        case .aiAvatar: "AI Avatar"
        }
    }

    var systemImage: String {
        switch self {
        case .media: "film"
        case .audio: "waveform"
        case .text: "textformat"
        case .stickers: "face.smiling"
        case .effects: "sparkles"
        case .transitions: "rectangle.righthalf.inset.filled.arrow.right"
        case .captions: "captions.bubble"
        case .filters: "camera.filters"
        case .adjustment: "slider.horizontal.3"
        case .templates: "rectangle.stack"
        case .aiAvatar: "person.fill.viewfinder"
        }
    }
}
