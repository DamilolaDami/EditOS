import AppKit
import SwiftUI
import UserNotifications

/// First-run onboarding. Walks the user through the value prop, asks for the
/// two permissions we actually use (Movies-folder writes for exports and
/// notifications for export-finished pings), and ends with a CTA that opens
/// a new project. Persistence is via @AppStorage so the sheet only fires
/// once per Mac.
struct OnboardingView: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow

    /// Caller hides the sheet after this fires. Optional CTA: pass true to
    /// also create + open a new project.
    let onFinish: (_ createNewProject: Bool) -> Void

    @State private var page: Page = .welcome
    @State private var moviesGranted: Bool = false
    @State private var notificationsGranted: Bool = false
    @State private var heroSeed: Int = 0  // bumps to re-trigger hero animation
    @Namespace private var pageNamespace

    enum Page: Int, CaseIterable, Identifiable {
        case welcome, features, permissions, ready
        var id: Int { rawValue }
    }

    var body: some View {
        ZStack {
            backgroundGradient
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                content
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
                    .id(page)
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 36)
        }
        .frame(width: 720, height: 560)
        .onAppear {
            refreshPermissionState()
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                theme.colors.background,
                theme.colors.surface,
                theme.colors.background
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .top) {
            RadialGradient(
                colors: [theme.colors.accent.opacity(0.25), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 360
            )
            .blendMode(.plusLighter)
            .opacity(0.6)
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar (skip + page dots)

    private var topBar: some View {
        HStack {
            Image(systemName: "film.stack.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.colors.accent)
            Text("EditOS")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)
            Spacer()
            if page != .welcome {
                Button("Skip") {
                    onFinish(false)
                }
                .buttonStyle(.plain)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textSecondary)
            }
        }
    }

    // MARK: - Footer (page dots + nav)

    private var footer: some View {
        VStack(spacing: 18) {
            pageIndicator
            actionRow
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Page.allCases) { p in
                Capsule()
                    .fill(p == page ? theme.colors.accent : theme.colors.textTertiary.opacity(0.6))
                    .frame(width: p == page ? 22 : 6, height: 6)
                    .animation(.spring(response: 0.32, dampingFraction: 0.85), value: page)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            if page != .welcome && page != .ready {
                secondaryButton("Back") { goToPage(at: page.rawValue - 1) }
            }
            Spacer()
            primaryActionButton
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch page {
        case .welcome:
            primaryButton("Get Started", systemImage: "arrow.right") {
                goToPage(at: page.rawValue + 1)
            }
        case .features:
            primaryButton("Continue", systemImage: "arrow.right") {
                goToPage(at: page.rawValue + 1)
            }
        case .permissions:
            primaryButton("Continue", systemImage: "arrow.right") {
                goToPage(at: page.rawValue + 1)
            }
        case .ready:
            primaryButton("Create your first project", systemImage: "sparkles") {
                onFinish(true)
            }
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome:      WelcomePage(theme: theme, seed: heroSeed)
        case .features:     FeaturesPage(theme: theme, seed: heroSeed)
        case .permissions:
            PermissionsPage(
                theme: theme,
                moviesGranted: moviesGranted,
                notificationsGranted: notificationsGranted,
                onRequestMovies: { Task { await requestMoviesAccess() } },
                onRequestNotifications: { Task { await requestNotifications() } },
                seed: heroSeed
            )
        case .ready:        ReadyPage(theme: theme, seed: heroSeed)
        }
    }

    // MARK: - Navigation

    private func goToPage(at index: Int) {
        guard let target = Page(rawValue: index) else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            page = target
            heroSeed += 1
        }
    }

    // MARK: - Permissions

    /// Triggers macOS's TCC prompt for the user's real ~/Movies folder by
    /// attempting to create the EditOS subfolder. With the
    /// ENABLE_FILE_ACCESS_MOVIES_FOLDER entitlement in place, the prompt
    /// appears the first time; subsequent runs are silent.
    @MainActor
    private func requestMoviesAccess() async {
        guard let movies = try? FileManager.default.url(
            for: .moviesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        let folder = movies.appending(path: "EditOS", directoryHint: .isDirectory)
        let granted = (try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )) != nil && FileManager.default.isWritableFile(atPath: folder.path)
        withAnimation { moviesGranted = granted }
    }

    @MainActor
    private func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        withAnimation { notificationsGranted = granted }
    }

    @MainActor
    private func refreshPermissionState() {
        // Movies — probe non-destructively.
        if let movies = try? FileManager.default.url(
            for: .moviesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            let folder = movies.appending(path: "EditOS", directoryHint: .isDirectory)
            moviesGranted = FileManager.default.isWritableFile(atPath: folder.path)
                || FileManager.default.isWritableFile(atPath: movies.path)
        }
        // Notifications — async check.
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                notificationsGranted = status.authorizationStatus == .authorized
                    || status.authorizationStatus == .provisional
            }
        }
    }

    // MARK: - Button styles

    @ViewBuilder
    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                LinearGradient(
                    colors: [theme.colors.accent, theme.colors.accent.opacity(0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .shadow(color: theme.colors.accent.opacity(0.45), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.colors.surfaceElevated, in: Capsule())
                .overlay(
                    Capsule().stroke(theme.colors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    let theme: Theme
    let seed: Int

    @State private var heroScale: CGFloat = 0.7
    @State private var heroOpacity: Double = 0.0

    var body: some View {
        VStack(spacing: 24) {
            heroIcon
            VStack(spacing: 10) {
                Text("Welcome to EditOS")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("The open-source video editor for macOS.\nCut, layer, score, and export — all in one window.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 460)
            }
        }
        .task(id: seed) {
            heroScale = 0.7
            heroOpacity = 0
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                heroScale = 1.0
                heroOpacity = 1.0
            }
        }
    }

    private var heroIcon: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [theme.colors.accent.opacity(0.45), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: 95
                    )
                )
                .frame(width: 180, height: 180)
            Image(systemName: "film.stack.fill")
                .font(.system(size: 76, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [theme.colors.accent, theme.colors.accent.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: theme.colors.accent.opacity(0.5), radius: 16, y: 6)
        }
        .scaleEffect(heroScale)
        .opacity(heroOpacity)
    }
}

// MARK: - Features

private struct FeaturesPage: View {
    let theme: Theme
    let seed: Int

    private struct Feature: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbol: String
        let tint: Color
    }

    private var features: [Feature] {
        [
            Feature(
                title: "A pro-style timeline",
                subtitle: "Multi-track editing with magnetic snapping and live waveforms.",
                symbol: "rectangle.stack.fill.badge.plus",
                tint: theme.colors.accent
            ),
            Feature(
                title: "Free music & SFX",
                subtitle: "Search Freesound right in the sidebar — drop a track at the playhead.",
                symbol: "waveform.path.ecg.rectangle.fill",
                tint: theme.colors.success
            ),
            Feature(
                title: "Real stickers",
                subtitle: "GIPHY's library powers the Stickers tab — animated, transparent, ready.",
                symbol: "sparkles",
                tint: theme.colors.warning
            ),
            Feature(
                title: "Export anywhere",
                subtitle: "MP4 in 720p, 1080p, or 4K — straight into your Movies folder.",
                symbol: "square.and.arrow.up.fill",
                tint: Color(red: 0.78, green: 0.50, blue: 0.95)
            )
        ]
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Built to create")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Everything you need in one place.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.colors.textSecondary)
            }
            VStack(spacing: 10) {
                ForEach(features) { feature in
                    FeatureRow(feature: feature, theme: theme, seed: seed)
                }
            }
            .frame(maxWidth: 520)
        }
    }

    private struct FeatureRow: View {
        let feature: Feature
        let theme: Theme
        let seed: Int

        @State private var rowOpacity: Double = 0.0
        @State private var rowOffset: CGFloat = 12

        var body: some View {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(feature.tint.opacity(0.18))
                    Image(systemName: feature.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(feature.tint)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Text(feature.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.colors.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.colors.surfaceElevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(theme.colors.border.opacity(0.6), lineWidth: 1)
            )
            .opacity(rowOpacity)
            .offset(y: rowOffset)
            .task(id: seed) {
                rowOpacity = 0
                rowOffset = 12
                try? await Task.sleep(nanoseconds: 80_000_000)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    rowOpacity = 1
                    rowOffset = 0
                }
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    let theme: Theme
    let moviesGranted: Bool
    let notificationsGranted: Bool
    let onRequestMovies: () -> Void
    let onRequestNotifications: () -> Void
    let seed: Int

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("A couple of permissions")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Both are optional, but they make EditOS feel native.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.colors.textSecondary)
            }
            VStack(spacing: 10) {
                PermissionRow(
                    theme: theme,
                    title: "Movies folder",
                    subtitle: "Save exports to ~/Movies/EditOS so they're easy to find in Finder.",
                    symbol: "folder.fill.badge.plus",
                    tint: theme.colors.accent,
                    granted: moviesGranted,
                    action: onRequestMovies
                )
                PermissionRow(
                    theme: theme,
                    title: "Notifications",
                    subtitle: "Get a ping when long exports finish — go grab a coffee.",
                    symbol: "bell.badge.fill",
                    tint: theme.colors.warning,
                    granted: notificationsGranted,
                    action: onRequestNotifications
                )
            }
            .frame(maxWidth: 520)

            Text("Both can be changed later in System Settings → Privacy & Security.")
                .font(.system(size: 11))
                .foregroundStyle(theme.colors.textTertiary)
        }
    }

    private struct PermissionRow: View {
        let theme: Theme
        let title: String
        let subtitle: String
        let symbol: String
        let tint: Color
        let granted: Bool
        let action: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(tint.opacity(granted ? 0.22 : 0.16))
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.colors.textSecondary)
                }
                Spacer()
                if granted {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.colors.success)
                        Text("Allowed")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.colors.success)
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button("Allow", action: action)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(tint, in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.colors.surfaceElevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(theme.colors.border.opacity(0.6), lineWidth: 1)
            )
        }
    }
}

// MARK: - Ready

private struct ReadyPage: View {
    let theme: Theme
    let seed: Int

    @State private var checkScale: CGFloat = 0.6
    @State private var checkOpacity: Double = 0.0

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.colors.success.opacity(0.5), .clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 95
                        )
                    )
                    .frame(width: 180, height: 180)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 80, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.colors.success, theme.colors.success.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: theme.colors.success.opacity(0.5), radius: 14, y: 6)
            }
            .scaleEffect(checkScale)
            .opacity(checkOpacity)
            VStack(spacing: 10) {
                Text("You're all set")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Drop a video, drag in a soundtrack, sprinkle stickers.\nWe'll handle the rest.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
        .task(id: seed) {
            checkScale = 0.6
            checkOpacity = 0
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                checkScale = 1.0
                checkOpacity = 1.0
            }
        }
    }
}
