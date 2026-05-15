import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme

    @State private var selection: HomeSection = .home
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var isOnboardingPresented: Bool = false

    var body: some View {
        NavigationSplitView {
            HomeSidebar(selection: $selection)
                .frame(minWidth: 220)
        } detail: {
            detail
        }
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home:         homeDetail
        case .templates:    HomeTemplatesView()
        case .media:        HomeMediaView()
        case .designStudio: HomeDesignStudioView()
        }
    }

    private var homeDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.xl) {
                HomeHeader()
                CreateProjectBanner {
                    let project = environment.projectStore.createProject(named: "Untitled")
                    openWindow(id: WindowID.editor.rawValue, value: project.id)
                }
                QuickActionsRow()
                ProjectGrid(projects: environment.projectStore.projects) { project in
                    openWindow(id: WindowID.editor.rawValue, value: project.id)
                }
            }
            .padding(.horizontal, theme.spacing.xxl)
            .padding(.vertical, theme.spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.colors.background)
        .onAppear {
            if !hasCompletedOnboarding {
                isOnboardingPresented = true
            }
        }
        // Re-show when the flag flips back to false (e.g. Help → Replay Onboarding).
        .onChange(of: hasCompletedOnboarding) { _, completed in
            isOnboardingPresented = !completed
        }
        .sheet(isPresented: $isOnboardingPresented) {
            OnboardingView { shouldCreate in
                hasCompletedOnboarding = true
                isOnboardingPresented = false
                if shouldCreate {
                    let project = environment.projectStore.createProject(named: "Untitled")
                    openWindow(id: WindowID.editor.rawValue, value: project.id)
                }
            }
            .interactiveDismissDisabled(true)
        }
    }
}

enum HomeSection: String, Hashable, CaseIterable {
    case home
    case templates
    case media
    case designStudio

    var label: String {
        switch self {
        case .home: "Home"
        case .templates: "Templates"
        case .media: "Media"
        case .designStudio: "Design Studio"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .templates: "rectangle.stack"
        case .media: "photo.stack"
        case .designStudio: "paintpalette"
        }
    }
}

private struct HomeHeader: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            Text("EditOS")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(theme.colors.textPrimary)
            Text("Open-source video editor for macOS")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textSecondary)
        }
    }
}

private struct CreateProjectBanner: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.spacing.lg) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 64, height: 64)
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    Text("Create a new project")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Start from scratch with a fresh timeline")
                        .font(theme.typography.body)
                        .foregroundStyle(.white.opacity(0.78))
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.trailing, theme.spacing.lg)
                    .offset(x: isHovering ? 4 : 0)
                    .animation(.easeInOut(duration: 0.18), value: isHovering)
            }
            .padding(theme.spacing.xl)
            .frame(maxWidth: .infinity, minHeight: 156)
            .background {
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.55, blue: 0.95),
                        Color(red: 0.35, green: 0.72, blue: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "film.stack")
                    .font(.system(size: 140, weight: .regular))
                    .foregroundStyle(.white.opacity(0.08))
                    .offset(x: 30, y: 30)
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.lg)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: Color(red: 0.18, green: 0.55, blue: 0.95).opacity(isHovering ? 0.35 : 0.18), radius: 18, y: 6)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovering = hovering
            }
        }
    }
}

private struct QuickActionsRow: View {
    @Environment(\.theme) private var theme

    private let actions: [(String, String, String)] = [
        ("Import media", "tray.and.arrow.down", "Bring in video, audio, and images"),
        ("Record screen", "record.circle", "Capture your screen as a clip"),
        ("Open template", "rectangle.stack", "Start from a preset")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Text("Quick actions".uppercased())
                .font(theme.typography.sectionLabel)
                .foregroundStyle(theme.colors.textTertiary)
                .tracking(0.8)
            HStack(spacing: theme.spacing.md) {
                ForEach(actions, id: \.0) { item in
                    QuickActionCard(title: item.0, systemImage: item.1, subtitle: item.2)
                }
            }
        }
    }
}

private struct QuickActionCard: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    let subtitle: String

    @State private var isHovering = false

    var body: some View {
        Button {
            // Stubbed — wired up later.
        } label: {
            HStack(spacing: theme.spacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(theme.colors.accent)
                    .frame(width: 36, height: 36)
                    .background(theme.colors.accentMuted, in: RoundedRectangle(cornerRadius: theme.radius.sm))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(theme.typography.bodyEmphasized)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text(subtitle)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(theme.spacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .fill(isHovering ? theme.colors.surfaceElevated : theme.colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .stroke(isHovering ? theme.colors.borderEmphasis : theme.colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}
