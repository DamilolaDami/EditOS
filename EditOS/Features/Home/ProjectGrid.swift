import SwiftUI

struct ProjectGrid: View {
    @Environment(\.theme) private var theme
    let projects: [Project]
    let onOpen: (Project) -> Void

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text("Projects")
                .font(theme.typography.title)
                .foregroundStyle(theme.colors.textPrimary)
            if projects.isEmpty {
                ContentUnavailableView(
                    "No projects yet",
                    systemImage: "film",
                    description: Text("Create a project to start editing.")
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: theme.spacing.lg) {
                        ForEach(projects) { project in
                            ProjectCard(project: project) { onOpen(project) }
                        }
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

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .fill(theme.colors.surfaceElevated)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: 28))
                            .foregroundStyle(theme.colors.textSecondary)
                    }
                VStack(alignment: .leading, spacing: theme.spacing.xxs) {
                    Text(project.name)
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(project.modifiedAt, format: .relative(presentation: .named))
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
