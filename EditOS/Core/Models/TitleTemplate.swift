import CoreGraphics
import Foundation

/// Curated title-card / intro template. A template is a recipe — when
/// the user picks one, the editor materialises it as a set of clips on
/// the timeline at the playhead (background overlay + one or more
/// animated text clips). After insertion the template fades into
/// regular clips that the user can keep editing.
struct TitleTemplate: Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var subtitle: String
    /// SF Symbol name for the picker tile thumbnail.
    var systemImage: String
    /// Total title duration on the timeline (seconds).
    var duration: TimeInterval
    /// Background style. The composition pipeline doesn't have a "solid
    /// colour" track type so we encode it as a transparent text overlay
    /// behind the main text — `nil` means no background fill.
    var background: Background?
    /// Stacked text layers in render order (back-to-front).
    var layers: [Layer]

    enum Background: Hashable, Sendable {
        case solid(ColorRGBA)
        /// Lets the underlying video peek through — useful for lower-
        /// thirds and on-clip titles.
        case transparent
    }

    /// One text layer in the template. Position is given as a canvas-
    /// space offset from centre (matching the rest of the overlay
    /// system); size is in canvas points.
    struct Layer: Hashable, Sendable {
        var text: String
        var size: CGFloat
        var color: ColorRGBA
        var offset: CGSize
        var animation: TextAnimation
        /// Delay before this layer's animation begins, relative to the
        /// title card's start. Lets the heading appear before the
        /// subtitle.
        var startDelay: TimeInterval
    }
}

/// Hand-tuned title presets, indexed by id. Editing this list updates
/// the in-app title library on the next launch.
enum TitleTemplateCatalog {
    static let all: [TitleTemplate] = [
        TitleTemplate(
            id: "minimal",
            name: "Minimal",
            subtitle: "Centred title, clean fade",
            systemImage: "circle",
            duration: 3.5,
            background: .solid(ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1)),
            layers: [
                .init(
                    text: "Your Title",
                    size: 96,
                    color: .white,
                    offset: .zero,
                    animation: TextAnimation(kind: .fadeInWord, duration: 0.8),
                    startDelay: 0.2
                )
            ]
        ),
        TitleTemplate(
            id: "bold",
            name: "Bold",
            subtitle: "Heavy headline, pops in",
            systemImage: "bolt.fill",
            duration: 3.0,
            background: .solid(ColorRGBA(red: 0.96, green: 0.85, blue: 0.18, alpha: 1)),
            layers: [
                .init(
                    text: "EditOS",
                    size: 140,
                    color: ColorRGBA(red: 0.05, green: 0.05, blue: 0.05, alpha: 1),
                    offset: .zero,
                    animation: TextAnimation(kind: .popBounce, duration: 0.6),
                    startDelay: 0.1
                )
            ]
        ),
        TitleTemplate(
            id: "cinematic",
            name: "Cinematic",
            subtitle: "Slow fade, heading + sub",
            systemImage: "film.fill",
            duration: 5.0,
            background: .solid(ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1)),
            layers: [
                .init(
                    text: "Chapter One",
                    size: 64,
                    color: ColorRGBA(red: 0.9, green: 0.85, blue: 0.65, alpha: 1),
                    offset: CGSize(width: 0, height: -60),
                    animation: TextAnimation(kind: .fadeInWord, duration: 1.0),
                    startDelay: 0.3
                ),
                .init(
                    text: "The Beginning",
                    size: 32,
                    color: .white,
                    offset: CGSize(width: 0, height: 30),
                    animation: TextAnimation(kind: .fadeInWord, duration: 1.0),
                    startDelay: 1.0
                )
            ]
        ),
        TitleTemplate(
            id: "subtitle",
            name: "Subtitle",
            subtitle: "Lower-third, slides up",
            systemImage: "text.below.photo",
            duration: 3.0,
            background: .transparent,
            layers: [
                .init(
                    text: "Lower Third",
                    size: 56,
                    color: .white,
                    offset: CGSize(width: -120, height: 200),
                    animation: TextAnimation(kind: .slideFromLeft, duration: 0.55),
                    startDelay: 0.1
                ),
                .init(
                    text: "Subtitle goes here",
                    size: 28,
                    color: ColorRGBA(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
                    offset: CGSize(width: -120, height: 245),
                    animation: TextAnimation(kind: .slideFromLeft, duration: 0.55),
                    startDelay: 0.35
                )
            ]
        ),
        TitleTemplate(
            id: "outro",
            name: "Outro",
            subtitle: "Thanks-for-watching card",
            systemImage: "hand.wave.fill",
            duration: 4.0,
            background: .solid(ColorRGBA(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)),
            layers: [
                .init(
                    text: "Thanks for watching!",
                    size: 80,
                    color: .white,
                    offset: CGSize(width: 0, height: -30),
                    animation: TextAnimation(kind: .scaleUp, duration: 0.8),
                    startDelay: 0.3
                ),
                .init(
                    text: "Subscribe for more",
                    size: 36,
                    color: ColorRGBA(red: 0.36, green: 0.72, blue: 1.0, alpha: 1),
                    offset: CGSize(width: 0, height: 60),
                    animation: TextAnimation(kind: .typewriter, duration: 1.2),
                    startDelay: 1.1
                )
            ]
        ),
        TitleTemplate(
            id: "retro",
            name: "Retro",
            subtitle: "80s-style typewriter",
            systemImage: "tv",
            duration: 4.0,
            background: .solid(ColorRGBA(red: 0.10, green: 0.05, blue: 0.20, alpha: 1)),
            layers: [
                .init(
                    text: "NOW PLAYING",
                    size: 72,
                    color: ColorRGBA(red: 1.0, green: 0.40, blue: 0.80, alpha: 1),
                    offset: .zero,
                    animation: TextAnimation(kind: .typewriter, duration: 1.5),
                    startDelay: 0.2
                )
            ]
        )
    ]
}
