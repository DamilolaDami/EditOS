import AppKit
import SwiftUI

/// Inspiration / reference panel. Color palettes, type pairings, and aspect
/// presets you can copy into a project. Visual + reference-only for now —
/// the apply paths can wire up to brand kits later.
struct HomeDesignStudioView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.xl) {
                header
                paletteSection
                typeSection
                aspectsSection
                comingSoonBanner
            }
            .padding(.horizontal, theme.spacing.xxl)
            .padding(.vertical, theme.spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.colors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            Text("Design Studio")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(theme.colors.textPrimary)
            Text("Curated palettes, type pairings, and canvas presets. Click a swatch to copy the hex.")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textSecondary)
        }
    }

    // MARK: - Palettes

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            sectionLabel("Brand palettes")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 16)],
                spacing: 16
            ) {
                ForEach(DesignKit.palettes) { palette in
                    PaletteCard(palette: palette)
                }
            }
        }
    }

    // MARK: - Typography

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            sectionLabel("Typography pairings")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 16)],
                spacing: 16
            ) {
                ForEach(DesignKit.typeKits) { kit in
                    TypeCard(kit: kit)
                }
            }
        }
    }

    // MARK: - Aspect ratios

    private var aspectsSection: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            sectionLabel("Aspect references")
            HStack(spacing: theme.spacing.md) {
                ForEach(DesignKit.aspects) { aspect in
                    AspectChip(aspect: aspect)
                }
            }
        }
    }

    private var comingSoonBanner: some View {
        HStack(spacing: theme.spacing.md) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 22))
                .foregroundStyle(theme.colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("More tools coming soon")
                    .font(theme.typography.bodyEmphasized)
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Brand kits with logo + color + font, animation presets, motion templates.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer()
        }
        .padding(theme.spacing.md)
        .background(theme.colors.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: theme.radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .stroke(theme.colors.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(theme.typography.sectionLabel)
            .foregroundStyle(theme.colors.textTertiary)
            .tracking(0.8)
    }
}

// MARK: - Design Kit data

private struct DesignPalette: Identifiable {
    let id: String
    let name: String
    let mood: String
    let colors: [Color]  // 4–5 swatches, primary first
    let hex: [String]
}

private struct TypeKit: Identifiable {
    let id: String
    let displayName: String
    let pairing: String
    let displayFont: Font
    let bodyFont: Font
}

private struct AspectRef: Identifiable {
    let id: String
    let label: String
    let subtitle: String
    let ratio: CGSize
    let tint: Color
}

private enum DesignKit {
    static let palettes: [DesignPalette] = [
        DesignPalette(
            id: "sunset",
            name: "Sunset Drive",
            mood: "Warm · cinematic",
            colors: [
                Color(red: 0.99, green: 0.42, blue: 0.30),
                Color(red: 0.97, green: 0.62, blue: 0.20),
                Color(red: 0.86, green: 0.34, blue: 0.60),
                Color(red: 0.32, green: 0.20, blue: 0.45),
                Color(red: 0.95, green: 0.91, blue: 0.83)
            ],
            hex: ["#FE6C4D", "#F89F33", "#DB5798", "#523372", "#F2E8D4"]
        ),
        DesignPalette(
            id: "midnight",
            name: "Midnight Studio",
            mood: "Cold · editorial",
            colors: [
                Color(red: 0.04, green: 0.06, blue: 0.18),
                Color(red: 0.11, green: 0.18, blue: 0.36),
                Color(red: 0.45, green: 0.55, blue: 0.92),
                Color(red: 0.83, green: 0.88, blue: 1.00),
                Color(red: 1.00, green: 1.00, blue: 1.00)
            ],
            hex: ["#0A0F2E", "#1C2D5B", "#738CEB", "#D3E1FF", "#FFFFFF"]
        ),
        DesignPalette(
            id: "forest",
            name: "Forest Floor",
            mood: "Organic · vintage",
            colors: [
                Color(red: 0.21, green: 0.32, blue: 0.22),
                Color(red: 0.47, green: 0.56, blue: 0.32),
                Color(red: 0.84, green: 0.74, blue: 0.46),
                Color(red: 0.96, green: 0.88, blue: 0.71),
                Color(red: 0.12, green: 0.10, blue: 0.07)
            ],
            hex: ["#365139", "#788F52", "#D6BD75", "#F5E0B5", "#1E1A12"]
        ),
        DesignPalette(
            id: "neon",
            name: "Neon Reel",
            mood: "Punchy · social",
            colors: [
                Color(red: 1.00, green: 0.18, blue: 0.58),
                Color(red: 0.20, green: 1.00, blue: 0.84),
                Color(red: 1.00, green: 0.92, blue: 0.20),
                Color(red: 0.07, green: 0.10, blue: 0.14),
                Color(red: 0.94, green: 0.94, blue: 0.95)
            ],
            hex: ["#FF2D94", "#33FFD7", "#FFEB33", "#121A24", "#F0F0F2"]
        )
    ]

    static let typeKits: [TypeKit] = [
        TypeKit(
            id: "modern",
            displayName: "Modern Anchor",
            pairing: "Display: SF Pro Rounded · Body: SF Pro Text",
            displayFont: .system(size: 32, weight: .heavy, design: .rounded),
            bodyFont: .system(size: 13, weight: .regular, design: .default)
        ),
        TypeKit(
            id: "editorial",
            displayName: "Editorial Serif",
            pairing: "Display: New York · Body: SF Pro Text",
            displayFont: .system(size: 32, weight: .semibold, design: .serif),
            bodyFont: .system(size: 13, weight: .regular, design: .default)
        ),
        TypeKit(
            id: "mono",
            displayName: "Mono Brutalist",
            pairing: "Display: SF Mono · Body: SF Mono",
            displayFont: .system(size: 28, weight: .heavy, design: .monospaced),
            bodyFont: .system(size: 12, weight: .regular, design: .monospaced)
        )
    ]

    static let aspects: [AspectRef] = [
        AspectRef(id: "16-9", label: "16:9", subtitle: "Widescreen", ratio: CGSize(width: 16, height: 9), tint: Color(red: 0.30, green: 0.65, blue: 0.95)),
        AspectRef(id: "9-16", label: "9:16", subtitle: "Vertical", ratio: CGSize(width: 9, height: 16), tint: Color(red: 0.95, green: 0.30, blue: 0.55)),
        AspectRef(id: "1-1", label: "1:1", subtitle: "Square", ratio: CGSize(width: 1, height: 1), tint: Color(red: 0.40, green: 0.85, blue: 0.60)),
        AspectRef(id: "4-5", label: "4:5", subtitle: "Portrait", ratio: CGSize(width: 4, height: 5), tint: Color(red: 0.65, green: 0.40, blue: 0.95)),
        AspectRef(id: "21-9", label: "21:9", subtitle: "Cinema", ratio: CGSize(width: 21, height: 9), tint: Color(red: 1.0, green: 0.65, blue: 0.10))
    ]
}

// MARK: - Cards

private struct PaletteCard: View {
    @Environment(\.theme) private var theme
    let palette: DesignPalette

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            HStack(spacing: 0) {
                ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, color in
                    color
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(palette.name)
                    .font(theme.typography.bodyEmphasized)
                    .foregroundStyle(theme.colors.textPrimary)
                Text(palette.mood)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            HStack(spacing: 6) {
                ForEach(palette.hex, id: \.self) { hex in
                    Button {
                        copyHex(hex)
                    } label: {
                        Text(hex)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.colors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(theme.colors.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Copy \(hex)")
                }
            }
        }
        .padding(theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .fill(theme.colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }

    private func copyHex(_ hex: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
    }
}

private struct TypeCard: View {
    @Environment(\.theme) private var theme
    let kit: TypeKit

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Make something")
                    .font(kit.displayFont)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                Text("A line of body text shows how the pairing reads inside a real layout. Subtle, balanced.")
                    .font(kit.bodyFont)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(kit.displayName)
                    .font(theme.typography.bodyEmphasized)
                    .foregroundStyle(theme.colors.textPrimary)
                Text(kit.pairing)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .fill(theme.colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }
}

private struct AspectChip: View {
    @Environment(\.theme) private var theme
    let aspect: AspectRef

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.sm)
                    .fill(theme.colors.surfaceElevated)
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [aspect.tint.opacity(0.9), aspect.tint.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: shapeWidth, height: shapeHeight)
            }
            .frame(width: 88, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
            VStack(alignment: .leading, spacing: 0) {
                Text(aspect.label)
                    .font(theme.typography.bodyEmphasized.monospacedDigit())
                    .foregroundStyle(theme.colors.textPrimary)
                Text(aspect.subtitle)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
    }

    private var shapeWidth: CGFloat {
        let r = aspect.ratio.width / aspect.ratio.height
        let maxW: CGFloat = 64
        let maxH: CGFloat = 44
        if r >= 1 {
            return min(maxW, maxH * r)
        } else {
            return maxH * r
        }
    }

    private var shapeHeight: CGFloat {
        let r = aspect.ratio.width / aspect.ratio.height
        let maxW: CGFloat = 64
        let maxH: CGFloat = 44
        if r >= 1 {
            return min(maxH, maxW / r)
        } else {
            return min(maxH, maxW / r)
        }
    }
}
