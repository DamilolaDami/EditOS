import SwiftUI

struct ProjectGrid: View {
    @Environment(\.theme) private var theme
    let projects: [Project]
    let onOpen: (Project) -> Void

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects".uppercased())
                    .font(theme.typography.sectionLabel)
                    .foregroundStyle(theme.colors.textTertiary)
                    .tracking(0.8)
                Spacer()
                Text("\(projects.count) total")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }
            if projects.isEmpty {
                EmptyProjectsCard()
            } else {
                LazyVGrid(columns: columns, spacing: theme.spacing.lg) {
                    ForEach(projects) { project in
                        ProjectCard(project: project) { onOpen(project) }
                    }
                }
            }
        }
    }
}

struct ProjectCard: View {
    @Environment(\.theme) private var theme
    let project: Project
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                ZStack {
                    LinearGradient(
                        colors: [
                            theme.colors.surfaceElevated,
                            theme.colors.surface
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "film")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(theme.colors.textTertiary)
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    Text(String(format: "%.1fs", max(0.1, project.timeline.duration)))
                        .font(theme.typography.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(theme.spacing.sm)
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.md)
                        .stroke(isHovering ? theme.colors.accent.opacity(0.6) : theme.colors.border, lineWidth: 1)
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(theme.typography.bodyEmphasized)
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(project.modifiedAt, format: .relative(presentation: .named))
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
            }
            .padding(theme.spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .fill(isHovering ? theme.colors.surface : Color.clear)
            )
            .scaleEffect(isHovering ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

private struct EmptyProjectsCard: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: theme.spacing.md) {
            Image(systemName: "film")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.colors.textTertiary)
            Text("No projects yet")
                .font(theme.typography.title)
                .foregroundStyle(theme.colors.textPrimary)
            Text("Create one above to get started.")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .fill(theme.colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .stroke(theme.colors.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }
}
