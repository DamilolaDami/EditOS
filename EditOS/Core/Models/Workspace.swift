import Foundation

/// Named editor panel layouts. Each phase of editing wants a different
/// arrangement of panels — Color needs a wide preview, Audio wants the
/// library out of the way, Effects wants the Effects library tab
/// open, Full Preview hides every sidebar. Premiere and Resolve both
/// ship picker-driven workspaces; this is EditOS's take.
///
/// Each workspace is a *snapshot* of panel visibility flags + an
/// optional library-tab hint. Selecting one applies the snapshot; the
/// user can still toggle individual panels mid-session — those tweaks
/// stay until the user picks another workspace, at which point that
/// workspace's defaults take over again.
enum Workspace: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Default — library + inspector + standard timeline. Where every
    /// session starts.
    case editing
    /// Wide preview for colour-grading. Library hidden so the canvas
    /// gets the screen real estate; inspector still visible so the
    /// user can drive Filter / Transform.
    case color
    /// Library hidden, inspector visible. Library auto-jumps to the
    /// Audio tab on switch in case the user wants to pull in SFX from
    /// the Freesound integration.
    case audio
    /// Library + inspector visible, library auto-switches to the
    /// Effects tab so the user is one click from a filter.
    case effects
    /// Library + inspector hidden — the preview takes the whole
    /// window. Useful for review screenings.
    case fullPreview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .editing:     return "Editing"
        case .color:       return "Color"
        case .audio:       return "Audio"
        case .effects:     return "Effects"
        case .fullPreview: return "Preview"
        }
    }

    /// SF Symbol for the picker chip and menu rows. Picked to read at
    /// 11pt without competing visually with the other top-bar icons.
    var systemImage: String {
        switch self {
        case .editing:     return "rectangle.split.3x1"
        case .color:       return "paintpalette"
        case .audio:       return "waveform"
        case .effects:     return "wand.and.stars"
        case .fullPreview: return "rectangle.fill"
        }
    }

    /// One-line subtitle shown beside the chip in the menu, so the
    /// purpose of each layout is discoverable without trial-and-error.
    var subtitle: String {
        switch self {
        case .editing:     return "Library + Inspector + Timeline"
        case .color:       return "Wide preview, hide library"
        case .audio:       return "Inspector only, audio tab"
        case .effects:     return "Effects browser open"
        case .fullPreview: return "Preview fills the window"
        }
    }

    /// Concrete settings applied when this workspace becomes active.
    /// Kept as a value type so it's easy to test in isolation and to
    /// extend later (timeline-height ratio, scope overlay, etc.).
    struct Layout: Sendable {
        let libraryVisible: Bool
        let inspectorVisible: Bool
        /// When set, switching to this workspace also flips the
        /// library to this tab. Skipped when nil so the user's last
        /// library tab is preserved (e.g. Editing → don't override).
        let preferredLibraryTab: ToolCategory?
    }

    var layout: Layout {
        switch self {
        case .editing:
            return Layout(libraryVisible: true, inspectorVisible: true, preferredLibraryTab: nil)
        case .color:
            return Layout(libraryVisible: false, inspectorVisible: true, preferredLibraryTab: nil)
        case .audio:
            return Layout(libraryVisible: false, inspectorVisible: true, preferredLibraryTab: .audio)
        case .effects:
            return Layout(libraryVisible: true, inspectorVisible: true, preferredLibraryTab: .effects)
        case .fullPreview:
            return Layout(libraryVisible: false, inspectorVisible: false, preferredLibraryTab: nil)
        }
    }
}
