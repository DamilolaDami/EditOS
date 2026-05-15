import SwiftUI

/// Quick-start templates panel. Each card creates a project pre-configured
/// with a specific canvas aspect ratio + resolution so the user can jump
/// straight into the editor sized for the platform they're targeting.
struct HomeTemplatesView: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.xl) {
                header
                section(title: "Social", items: TemplateCatalog.social)
                section(title: "Long-form", items: TemplateCatalog.longForm)
            }
            .padding(.horizontal, theme.spacing.xxl)
            .padding(.vertical, theme.spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.colors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            Text("Templates")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(theme.colors.textPrimary)
            Text("Start with the right canvas. We'll set the resolution and frame rate.")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textSecondary)
        }
    }

    private func section(title: String, items: [ProjectTemplate]) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text(title.uppercased())
                .font(theme.typography.sectionLabel)
                .foregroundStyle(theme.colors.textTertiary)
                .tracking(0.8)
            LazyVGrid(columns: columns, spacing: theme.spacing.lg) {
                ForEach(items) { template in
                    TemplateCard(template: template) {
                        createProject(from: template)
                    }
                }
            }
        }
    }

    private func createProject(from template: ProjectTemplate) {
        let project = environment.projectStore.createProject(
            named: template.displayName,
            canvas: template.canvas
        )
        openWindow(id: WindowID.editor.rawValue, value: project.id)
    }
}

// MARK: - Catalog

struct ProjectTemplate: Identifiable {
    let id: String
    let displayName: String
    let subtitle: String
    let canvas: CanvasFormat
    let symbol: String
    let tint: Color
    let aspect: CGSize  // visual ratio for the preview box
}

enum TemplateCatalog {
    static let social: [ProjectTemplate] = [
        ProjectTemplate(
            id: "youtube-short",
            displayName: "YouTube Short",
            subtitle: "9:16 · 1080×1920 · 30 fps",
            canvas: .vertical,
            symbol: "play.rectangle.fill",
            tint: Color(red: 0.95, green: 0.20, blue: 0.20),
            aspect: CGSize(width: 9, height: 16)
        ),
        ProjectTemplate(
            id: "instagram-reel",
            displayName: "Instagram Reel",
            subtitle: "9:16 · 1080×1920 · 30 fps",
            canvas: .vertical,
            symbol: "camera.fill",
            tint: Color(red: 0.90, green: 0.30, blue: 0.55),
            aspect: CGSize(width: 9, height: 16)
        ),
        ProjectTemplate(
            id: "tiktok",
            displayName: "TikTok",
            subtitle: "9:16 · 1080×1920 · 30 fps",
            canvas: .vertical,
            symbol: "music.note",
            tint: Color(red: 0.25, green: 0.94, blue: 0.94),
            aspect: CGSize(width: 9, height: 16)
        ),
        ProjectTemplate(
            id: "square",
            displayName: "Square Post",
            subtitle: "1:1 · 1080×1080 · 30 fps",
            canvas: .square,
            symbol: "square.fill",
            tint: Color(red: 0.30, green: 0.65, blue: 0.95),
            aspect: CGSize(width: 1, height: 1)
        ),
        ProjectTemplate(
            id: "portrait",
            displayName: "Portrait Post",
            subtitle: "4:5 · 1080×1350 · 30 fps",
            canvas: CanvasFormat(size: CGSize(width: 1080, height: 1350), frameRate: 30, backgroundColor: .black),
            symbol: "rectangle.portrait.fill",
            tint: Color(red: 0.65, green: 0.40, blue: 0.95),
            aspect: CGSize(width: 4, height: 5)
        )
    ]

    static let longForm: [ProjectTemplate] = [
        ProjectTemplate(
            id: "youtube-hd",
            displayName: "YouTube HD",
            subtitle: "16:9 · 1920×1080 · 30 fps",
            canvas: .hd,
            symbol: "rectangle.fill",
            tint: Color(red: 0.95, green: 0.20, blue: 0.20),
            aspect: CGSize(width: 16, height: 9)
        ),
        ProjectTemplate(
            id: "youtube-4k",
            displayName: "YouTube 4K",
            subtitle: "16:9 · 3840×2160 · 30 fps",
            canvas: .uhd,
            symbol: "4k.tv.fill",
            tint: Color(red: 1.0, green: 0.65, blue: 0.10),
            aspect: CGSize(width: 16, height: 9)
        ),
        ProjectTemplate(
            id: "cinematic",
            displayName: "Cinematic",
            subtitle: "21:9 · 2560×1080 · 24 fps",
            canvas: CanvasFormat(size: CGSize(width: 2560, height: 1080), frameRate: 24, backgroundColor: .black),
            symbol: "movieclapper.fill",
            tint: Color(red: 0.25, green: 0.45, blue: 0.85),
            aspect: CGSize(width: 21, height: 9)
        )
    ]
}

// MARK: - Card

private struct TemplateCard: View {
    @Environment(\.theme) private var theme
    let template: ProjectTemplate
    let onCreate: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onCreate) {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                // Preview surface — uses the template's aspect ratio inside a
                // 16:9 frame so the visual size telegraphs the canvas shape.
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.md)
                        .fill(theme.colors.surfaceElevated)
                    aspectPreview
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: template.symbol)
                            .font(.system(size: 9, weight: .heavy))
                        Text(aspectLabel)
                            .font(theme.typography.caption.monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(template.tint.opacity(0.9), in: Capsule())
                    .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.md)
                        .stroke(isHovering ? template.tint.opacity(0.7) : theme.colors.border, lineWidth: 1)
                )
                .shadow(color: isHovering ? template.tint.opacity(0.3) : .clear, radius: 14, y: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.displayName)
                        .font(theme.typography.bodyEmphasized)
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(template.subtitle)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(theme.spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .fill(isHovering ? theme.colors.surface : Color.clear)
            )
            .scaleEffect(isHovering ? 1.012 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    /// Visual placeholder shaped to the template's aspect ratio.
    private var aspectPreview: some View {
        GeometryReader { proxy in
            let outer = proxy.size
            let ratio = template.aspect.width / template.aspect.height
            let fitWidth = min(outer.width * 0.8, outer.height * 0.8 * ratio)
            let fitHeight = fitWidth / ratio
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [template.tint.opacity(0.85), template.tint.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: fitWidth, height: fitHeight)
                    .overlay(
                        Image(systemName: template.symbol)
                            .font(.system(size: min(fitWidth, fitHeight) * 0.3, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    )
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            }
            .frame(width: outer.width, height: outer.height)
        }
    }

    private var aspectLabel: String {
        let w = Int(template.aspect.width)
        let h = Int(template.aspect.height)
        return "\(w):\(h)"
    }
}
