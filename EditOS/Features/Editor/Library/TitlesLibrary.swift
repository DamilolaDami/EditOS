import SwiftUI

/// Picker grid for the curated title-card templates. Each cell shows a
/// gradient-tinted thumbnail with the template name + a one-line tease;
/// tapping the card materialises the template into the timeline at the
/// playhead via `EditorViewModel.placeTitleTemplate(_:atTime:)`.
struct TitlesLibrary: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                header
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(TitleTemplateCatalog.all) { template in
                        TitleCard(template: template) {
                            model.placeTitleTemplate(template, atTime: model.playback.currentTime)
                        }
                    }
                }
            }
            .padding(theme.spacing.md)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Titles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)
            Text("Tap a card to drop it on the timeline at the playhead.")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textSecondary)
        }
    }
}

/// One template tile. Hover lift + slight scale so the grid feels
/// tactile. The accent tint is hashed off the template id so each card
/// gets a distinct hue without us having to author per-template colour.
private struct TitleCard: View {
    @Environment(\.theme) private var theme
    let template: TitleTemplate
    let onTap: () -> Void

    @State private var isHovering = false

    private var tint: Color {
        // Map the id's hash to a hue 0…1 so every template gets a
        // stable but distinct accent tint.
        let hash = template.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let hue = Double(hash % 100) / 100.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.95)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.sm)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.7), tint.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: template.systemImage)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                }
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.sm)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(template.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Text(template.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(theme.spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.sm)
                    .fill(isHovering ? theme.colors.surfaceElevated : theme.colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.sm)
                    .stroke(
                        isHovering ? theme.colors.accent.opacity(0.5) : theme.colors.border,
                        lineWidth: 1
                    )
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        .help("\(template.name) — \(Int(template.duration))s")
    }
}
