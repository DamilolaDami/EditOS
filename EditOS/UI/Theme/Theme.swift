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
        var background: Color
        var surface: Color
        var surfaceElevated: Color
        var border: Color
        var accent: Color
        var textPrimary: Color
        var textSecondary: Color
        var trackVideo: Color
        var trackAudio: Color
        var trackOverlay: Color
        var trackCaption: Color
        var trackSticker: Color

        static let dark = Colors(
            background: Color(red: 0.07, green: 0.08, blue: 0.09),
            surface: Color(red: 0.10, green: 0.11, blue: 0.13),
            surfaceElevated: Color(red: 0.14, green: 0.15, blue: 0.17),
            border: Color.white.opacity(0.08),
            accent: Color(red: 0.20, green: 0.78, blue: 0.85),
            textPrimary: Color.white.opacity(0.95),
            textSecondary: Color.white.opacity(0.55),
            trackVideo: Color(red: 0.30, green: 0.65, blue: 0.95),
            trackAudio: Color(red: 0.40, green: 0.85, blue: 0.55),
            trackOverlay: Color(red: 0.85, green: 0.55, blue: 0.95),
            trackCaption: Color(red: 0.95, green: 0.80, blue: 0.30),
            trackSticker: Color(red: 0.95, green: 0.45, blue: 0.55)
        )
    }

    struct Spacing: Sendable {
        var xxs: CGFloat
        var xs: CGFloat
        var sm: CGFloat
        var md: CGFloat
        var lg: CGFloat
        var xl: CGFloat

        static let `default` = Spacing(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24)
    }

    struct Radius: Sendable {
        var sm: CGFloat
        var md: CGFloat
        var lg: CGFloat

        static let `default` = Radius(sm: 4, md: 8, lg: 12)
    }

    struct Typography: Sendable {
        var caption: Font
        var body: Font
        var title: Font
        var displayMono: Font

        static let `default` = Typography(
            caption: .system(size: 11, weight: .regular, design: .default),
            body: .system(size: 13, weight: .regular, design: .default),
            title: .system(size: 15, weight: .semibold, design: .default),
            displayMono: .system(size: 13, weight: .medium, design: .monospaced)
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
}
