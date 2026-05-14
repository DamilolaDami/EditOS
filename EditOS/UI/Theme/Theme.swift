import CoreGraphics
import SwiftUI

/// Design tokens. Consumed via `EnvironmentValues.theme` so we can swap themes
/// at runtime without touching call sites.
struct Theme: Sendable {
    var colors: Colors
    var spacing: Spacing
    var radius: Radius
    var typography: Typography

    static let dark = Theme(
        colors: .dark,
        spacing: .default,
        radius: .default,
        typography: .default
    )

    struct Colors: Sendable {
        /// Outermost background — the window's canvas.
        var background: Color
        /// Cards and panels sitting on the background.
        var surface: Color
        /// Controls and cells sitting on a panel.
        var surfaceElevated: Color
        /// Hover/selected fill for elevated controls.
        var surfaceHighest: Color
        var border: Color
        var borderEmphasis: Color
        var accent: Color
        var accentMuted: Color
        var textPrimary: Color
        var textSecondary: Color
        var textTertiary: Color
        var trackVideo: Color
        var trackAudio: Color
        var trackOverlay: Color
        var trackCaption: Color
        var trackSticker: Color
        var success: Color
        var warning: Color
        var danger: Color

        static let dark = Colors(
            background: Color(red: 0.07, green: 0.07, blue: 0.08),
            surface: Color(red: 0.11, green: 0.11, blue: 0.13),
            surfaceElevated: Color(red: 0.15, green: 0.15, blue: 0.17),
            surfaceHighest: Color(red: 0.20, green: 0.20, blue: 0.22),
            border: Color.white.opacity(0.06),
            borderEmphasis: Color.white.opacity(0.14),
            accent: Color(red: 0.36, green: 0.72, blue: 1.0),
            accentMuted: Color(red: 0.36, green: 0.72, blue: 1.0).opacity(0.18),
            textPrimary: Color.white.opacity(0.95),
            textSecondary: Color.white.opacity(0.55),
            textTertiary: Color.white.opacity(0.35),
            trackVideo: Color(red: 0.36, green: 0.72, blue: 1.0),
            trackAudio: Color(red: 0.40, green: 0.85, blue: 0.60),
            trackOverlay: Color(red: 0.78, green: 0.50, blue: 0.95),
            trackCaption: Color(red: 0.96, green: 0.80, blue: 0.32),
            trackSticker: Color(red: 0.96, green: 0.45, blue: 0.55),
            success: Color(red: 0.40, green: 0.85, blue: 0.60),
            warning: Color(red: 0.96, green: 0.80, blue: 0.32),
            danger: Color(red: 0.96, green: 0.42, blue: 0.42)
        )
    }

    struct Spacing: Sendable {
        var xxs: CGFloat
        var xs: CGFloat
        var sm: CGFloat
        var md: CGFloat
        var lg: CGFloat
        var xl: CGFloat
        var xxl: CGFloat

        static let `default` = Spacing(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32)
    }

    struct Radius: Sendable {
        var xs: CGFloat
        var sm: CGFloat
        var md: CGFloat
        var lg: CGFloat
        var pill: CGFloat

        static let `default` = Radius(xs: 3, sm: 5, md: 8, lg: 12, pill: 999)
    }

    struct Typography: Sendable {
        var caption: Font
        var body: Font
        var bodyEmphasized: Font
        var title: Font
        var sectionLabel: Font
        var displayMono: Font

        static let `default` = Typography(
            caption: .system(size: 11, weight: .regular, design: .default),
            body: .system(size: 12, weight: .regular, design: .default),
            bodyEmphasized: .system(size: 12, weight: .semibold, design: .default),
            title: .system(size: 14, weight: .semibold, design: .default),
            sectionLabel: .system(size: 10, weight: .semibold, design: .default),
            displayMono: .system(size: 12, weight: .medium, design: .monospaced)
        )
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = .dark
}

extension Track.Kind {
    func color(in theme: Theme) -> Color {
        switch self {
        case .video: theme.colors.trackVideo
        case .audio: theme.colors.trackAudio
        case .overlay: theme.colors.trackOverlay
        case .caption: theme.colors.trackCaption
        case .sticker: theme.colors.trackSticker
        }
    }

    var systemImage: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .overlay: "rectangle.on.rectangle"
        case .caption: "captions.bubble"
        case .sticker: "face.smiling"
        }
    }

    /// Vertical room each track gets on the timeline. Video and audio carry
    /// thumbnails / waveforms so they stay tall; overlay-style tracks just
    /// hold small pill clips, so they shrink to give the player more room —
    /// matches CapCut's hierarchy.
    var timelineHeight: CGFloat {
        switch self {
        case .video, .audio: 56
        case .overlay, .caption, .sticker: 26
        }
    }
}
