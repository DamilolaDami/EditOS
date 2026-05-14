import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme

    @State private var selection: HomeSection = .home

    var body: some View {
        NavigationSplitView {
            HomeSidebar(selection: $selection)
                .frame(minWidth: 200)
        } detail: {
            VStack(alignment: .leading, spacing: theme.spacing.lg) {
                CreateProjectBanner {
                    let project = environment.projectStore.createProject(named: "Untitled")
                    openWindow(id: WindowID.editor.rawValue, value: project.id)
                }
                ProjectGrid(projects: environment.projectStore.projects) { project in
                    openWindow(id: WindowID.editor.rawValue, value: project.id)
                }
            }
            .padding(theme.spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.colors.background)
        }
        .toolbar(removing: .sidebarToggle)
    }
}

enum HomeSection: String, Hashable, CaseIterable {
    case home
    case templates
    case designStudio

    var label: String {
        switch self {
        case .home: "Home"
        case .templates: "Templates"
        case .designStudio: "Design Studio"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .templates: "rectangle.stack"
        case .designStudio: "paintpalette"
        }
    }
}

private struct CreateProjectBanner: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.spacing.sm) {
                Image(systemName: "plus.square.fill")
                    .font(.system(size: 22, weight: .medium))
                Text("Create project")
                    .font(theme.typography.title)
            }
            .foregroundStyle(theme.colors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 140)
            .background {
                LinearGradient(
                    colors: [
                        theme.colors.accent.opacity(0.55),
                        theme.colors.accent.opacity(0.25)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.lg))
        }
        .buttonStyle(.plain)
    }
}
