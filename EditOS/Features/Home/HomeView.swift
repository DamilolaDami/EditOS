import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme

    @State private var selection: HomeSection = .home
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var isOnboardingPresented: Bool = false
    @State private var searchText: String = ""
    @AppStorage("homeProjectSort") private var sortOptionRaw: String = ProjectSortOption.modifiedDescending.rawValue

    private var sortOption: ProjectSortOption {
        ProjectSortOption(rawValue: sortOptionRaw) ?? .modifiedDescending
    }

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
                HomeHeader(syncMonitor: environment.cloudKitSyncMonitor)
                CreateProjectBanner {
                    let project = environment.projectStore.createProject(named: "Untitled")
                    openWindow(id: WindowID.editor.rawValue, value: project.id)
                }
                QuickActionsRow()
                ProjectGrid(
                    projects: filteredProjects,
                    searchText: $searchText,
                    sortOption: Binding(
                        get: { sortOption },
                        set: { sortOptionRaw = $0.rawValue }
                    )
                ) { project in
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

    /// Apply the search and sort settings to the project list. Search matches
    /// case-insensitively against name; sort is one of name/modified/created
    /// in either direction.
    private var filteredProjects: [Project] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = environment.projectStore.projects.filter { project in
            query.isEmpty || project.name.lowercased().contains(query)
        }
        switch sortOption {
        case .modifiedDescending:
            return filtered.sorted { $0.modifiedAt > $1.modifiedAt }
        case .modifiedAscending:
            return filtered.sorted { $0.modifiedAt < $1.modifiedAt }
        case .nameAscending:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }
}

/// Persisted Home → Projects ordering preference. Backing string is stored in
/// AppStorage so the user's last choice carries across launches.
enum ProjectSortOption: String, CaseIterable, Identifiable {
    case modifiedDescending = "modified-desc"
    case modifiedAscending = "modified-asc"
    case nameAscending = "name-asc"
    case nameDescending = "name-desc"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .modifiedDescending: "Recently Edited"
        case .modifiedAscending: "Least Recently Edited"
        case .nameAscending: "Name (A → Z)"
        case .nameDescending: "Name (Z → A)"
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
    let syncMonitor: CloudKitSyncMonitor

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                Text("EditOS")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Open-source video editor for macOS")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer()
            CloudKitSyncBadge(monitor: syncMonitor)
        }
    }
}

/// Compact status chip showing the user's CloudKit account health. Tapping
/// it opens an explainer sheet that describes the current state and lets the
/// user re-check the account.
private struct CloudKitSyncBadge: View {
    @Environment(\.theme) private var theme
    @Bindable var monitor: CloudKitSyncMonitor
    @State private var isShowingDetail = false

    private var tint: Color {
        switch monitor.state {
        case .available: return theme.colors.success
        case .unknown: return theme.colors.textTertiary
        case .noAccount, .restricted: return theme.colors.warning
        case .temporarilyUnavailable, .couldNotDetermine: return theme.colors.danger
        }
    }

    var body: some View {
        Button {
            isShowingDetail = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: monitor.state.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(monitor.state.label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule().stroke(tint.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Click to see iCloud sync details")
        .sheet(isPresented: $isShowingDetail) {
            CloudKitSyncDetailSheet(monitor: monitor) {
                isShowingDetail = false
            }
        }
    }
}

/// Explainer sheet that opens when the user taps the iCloud sync badge.
/// Hero-style header with gradient orb, animated pulse, status timeline,
/// and contextual next-steps.
private struct CloudKitSyncDetailSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Bindable var monitor: CloudKitSyncMonitor
    let onClose: () -> Void

    @State private var isRefreshing = false
    @State private var pulseOn = false

    private var tint: Color {
        switch monitor.state {
        case .available: return theme.colors.success
        case .unknown: return theme.colors.textTertiary
        case .noAccount, .restricted: return theme.colors.warning
        case .temporarilyUnavailable, .couldNotDetermine: return theme.colors.danger
        }
    }

    private var headline: String {
        switch monitor.state {
        case .unknown: return "Checking iCloud…"
        case .available: return "Everything's in sync"
        case .noAccount: return "Sign in to iCloud"
        case .restricted: return "iCloud is restricted"
        case .temporarilyUnavailable: return "iCloud is taking a breath"
        case .couldNotDetermine: return "Can't reach iCloud"
        }
    }

    private var summary: String {
        switch monitor.state {
        case .unknown:
            return "EditOS is asking your Mac about its iCloud account. This usually takes a beat right after launch."
        case .available:
            return "Your projects ride along through iCloud. Edits on this Mac show up on every other Mac signed into the same Apple Account — typically within seconds."
        case .noAccount:
            return "You're not signed into iCloud, so projects stay on this Mac only. Sign in from System Settings to back up your library and pick up where you left off on any of your Macs."
        case .restricted:
            return "iCloud is blocked on this Mac — usually by a Screen Time rule, parental control, or MDM profile. Editing keeps working locally, but nothing leaves this device until the restriction is lifted."
        case .temporarilyUnavailable:
            return "iCloud is briefly unavailable — usually a transient network blip or a service hiccup on Apple's side. Your changes are saved on disk and will sync the moment iCloud is reachable again."
        case .couldNotDetermine(let detail):
            return "EditOS couldn't reach iCloud (\(detail)). Don't worry — your work is safe on this Mac, and sync will pick back up automatically when you're back online."
        }
    }

    private struct Bullet: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    private var bullets: [Bullet] {
        switch monitor.state {
        case .available:
            return [
                Bullet(icon: "doc.on.doc", title: "Projects, timelines & trims", detail: "Each edit syncs automatically across your signed-in Macs."),
                Bullet(icon: "externaldrive.badge.icloud", title: "Media stays on its Mac", detail: "Source video, audio, and images stay where you imported them — only the project file travels."),
                Bullet(icon: "clock.arrow.2.circlepath", title: "Last-write-wins", detail: "When two Macs edit the same project, the most recent save wins.")
            ]
        case .noAccount:
            return [
                Bullet(icon: "person.crop.circle", title: "Open System Settings", detail: "Apple menu → System Settings → Apple Account, then sign in."),
                Bullet(icon: "checkmark.icloud", title: "Enable iCloud Drive", detail: "Inside iCloud, make sure iCloud Drive is on and EditOS is allowed."),
                Bullet(icon: "arrow.clockwise", title: "Recheck", detail: "Come back here and tap Recheck — the badge will flip to green.")
            ]
        case .restricted:
            return [
                Bullet(icon: "hand.raised.fill", title: "A policy is blocking iCloud", detail: "Screen Time, parental controls, or an MDM profile can disable iCloud Drive."),
                Bullet(icon: "gearshape", title: "Check Screen Time", detail: "System Settings → Screen Time → Content & Privacy → Apps."),
                Bullet(icon: "laptopcomputer", title: "Local edits keep working", detail: "You can still edit and export — projects just won't sync.")
            ]
        case .temporarilyUnavailable, .couldNotDetermine:
            return [
                Bullet(icon: "wifi.exclamationmark", title: "Check your network", detail: "A flaky connection or VPN can keep CloudKit from reaching Apple's servers."),
                Bullet(icon: "internaldrive", title: "Your work is safe", detail: "Saves go to disk first — sync resumes automatically when iCloud is back."),
                Bullet(icon: "arrow.clockwise", title: "Recheck", detail: "Tap Recheck once you're back online to confirm.")
            ]
        case .unknown:
            return [
                Bullet(icon: "hourglass", title: "Asking CloudKit", detail: "EditOS is querying your Mac's iCloud account status."),
                Bullet(icon: "arrow.clockwise", title: "Stuck?", detail: "If this hangs more than a few seconds, tap Recheck.")
            ]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            Divider().background(theme.colors.border.opacity(0.6))
            content
            Divider().background(theme.colors.border.opacity(0.6))
            footer
        }
        .frame(width: 520)
        .background(
            ZStack {
                theme.colors.background
                LinearGradient(
                    colors: [tint.opacity(0.12), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
        )
        .onAppear { pulseOn = true }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: theme.spacing.lg) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.35), lineWidth: 1)
                    .frame(width: 88, height: 88)
                    .scaleEffect(pulseOn ? 1.18 : 1.0)
                    .opacity(pulseOn ? 0 : 0.6)
                    .animation(
                        monitor.state.isHealthy
                            ? .easeOut(duration: 2.4).repeatForever(autoreverses: false)
                            : .default,
                        value: pulseOn
                    )
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.35), tint.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                Circle()
                    .stroke(tint.opacity(0.55), lineWidth: 1)
                    .frame(width: 72, height: 72)
                Image(systemName: monitor.state.systemImage)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(tint)
                    .shadow(color: tint.opacity(0.6), radius: 10, y: 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("ICLOUD SYNC")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(theme.colors.textTertiary)
                Text(headline)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                statusPill
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(theme.colors.surface)
                    )
                    .overlay(
                        Circle().stroke(theme.colors.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, theme.spacing.xl)
        .padding(.top, theme.spacing.xl)
        .padding(.bottom, theme.spacing.lg)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .shadow(color: tint, radius: 4)
            Text(monitor.state.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(theme.colors.textPrimary.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            VStack(spacing: 1) {
                ForEach(Array(bullets.enumerated()), id: \.element.id) { index, bullet in
                    BulletRow(icon: bullet.icon, title: bullet.title, detail: bullet.detail, tint: tint)
                    if index < bullets.count - 1 {
                        Divider()
                            .background(theme.colors.border.opacity(0.5))
                            .padding(.leading, 42)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .fill(theme.colors.surface.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .stroke(theme.colors.border.opacity(0.6), lineWidth: 1)
            )
        }
        .padding(theme.spacing.xl)
    }

    private var footer: some View {
        HStack(spacing: theme.spacing.sm) {
            if case .noAccount = monitor.state {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
                        openURL(url)
                    }
                } label: {
                    Label("Open iCloud Settings", systemImage: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(tint)
            }
            Button {
                Task {
                    isRefreshing = true
                    await monitor.refresh()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    isRefreshing = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(
                            isRefreshing
                                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                : .default,
                            value: isRefreshing
                        )
                    Text(isRefreshing ? "Rechecking…" : "Recheck")
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)

            Spacer()

            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
        }
        .padding(.horizontal, theme.spacing.xl)
        .padding(.vertical, theme.spacing.md)
        .background(theme.colors.surface.opacity(0.4))
    }
}

private struct BulletRow: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: theme.spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(tint.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.spacing.md)
        .padding(.vertical, theme.spacing.sm)
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
