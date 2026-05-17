import Sparkle
import SwiftUI

/// macOS Settings window. Wired into the `Settings { ... }` scene in
/// `EditOSApp`, which makes "EditOS → Settings…" (⌘,) show this view
/// automatically.
///
/// Tab layout follows Apple's macOS Settings conventions: each tab is a
/// section of related toggles; the right pane is settings-only (no
/// editor content). Tabs in V1:
/// - **Updates** — Sparkle controls (Check Now, auto-check interval).
/// - **Integrations** — GIPHY / Freesound config status, with a setup
///   pointer when the bundled Secrets.plist is missing.
/// - **About** — version, copyright, links.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection: Tab = .updates

    enum Tab: String, Hashable, CaseIterable {
        case updates, integrations, about

        var label: String {
            switch self {
            case .updates:      return "Updates"
            case .integrations: return "Integrations"
            case .about:        return "About"
            }
        }

        var systemImage: String {
            switch self {
            case .updates:      return "arrow.down.circle"
            case .integrations: return "puzzlepiece.extension"
            case .about:        return "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            UpdatesTab(sparkle: environment.sparkle)
                .tabItem { Label(Tab.updates.label, systemImage: Tab.updates.systemImage) }
                .tag(Tab.updates)
            IntegrationsTab(
                giphy: environment.giphyService,
                freesound: environment.freesoundService
            )
                .tabItem { Label(Tab.integrations.label, systemImage: Tab.integrations.systemImage) }
                .tag(Tab.integrations)
            AboutTab()
                .tabItem { Label(Tab.about.label, systemImage: Tab.about.systemImage) }
                .tag(Tab.about)
        }
        .frame(width: 520, height: 360)
        .scenePadding()
    }
}

// MARK: - Updates

private struct UpdatesTab: View {
    @Environment(\.theme) private var theme
    @ObservedObject var sparkle: SparkleUpdater
    @AppStorage("SUEnableAutomaticChecks") private var autoCheck: Bool = true

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(theme.colors.accent.opacity(0.16))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.colors.accent)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Check for Updates")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Updates are EdDSA-signed and notarized — only Apple-signed builds install.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Check Now") {
                        sparkle.checkForUpdates()
                    }
                    .disabled(!sparkle.canCheckForUpdates)
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Automatically check for updates", isOn: $autoCheck)
                    .help("EditOS asks the update feed once every 24 hours when this is on.")
            } footer: {
                Text("EditOS uses [Sparkle](https://sparkle-project.org) to deliver updates from \(feedHost). The feed is publicly readable and signature-verified per release.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Update feed") {
                    Text(feedURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Installed version") {
                    Text(versionLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var feedURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "—"
    }
    private var feedHost: String {
        URL(string: feedURL)?.host ?? feedURL
    }
    private var versionLabel: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(v) (\(b))"
    }
}

// MARK: - Integrations

private struct IntegrationsTab: View {
    @Environment(\.theme) private var theme
    let giphy: GiphyService
    let freesound: FreesoundService

    var body: some View {
        Form {
            Section {
                IntegrationRow(
                    title: "GIPHY",
                    subtitle: "Animated stickers in the Library → Stickers tab.",
                    systemImage: "face.smiling",
                    isConfigured: giphy.isConfigured,
                    setupURL: URL(string: "https://developers.giphy.com/dashboard/")!
                )
                IntegrationRow(
                    title: "Freesound",
                    subtitle: "Sound-effect search in the Library → Audio tab.",
                    systemImage: "waveform",
                    isConfigured: freesound.isConfigured,
                    setupURL: URL(string: "https://freesound.org/apiv2/apply/")!
                )
            } footer: {
                Text("Keys live in `EditOS/Resources/Secrets.plist` (gitignored). Copy `Secrets.example.plist` next to it, fill in your keys, add the file to the Xcode target, rebuild.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct IntegrationRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    let title: String
    let subtitle: String
    let systemImage: String
    let isConfigured: Bool
    let setupURL: URL

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isConfigured
                          ? theme.colors.success.opacity(0.18)
                          : theme.colors.textTertiary.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isConfigured
                                     ? theme.colors.success
                                     : theme.colors.textTertiary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isConfigured {
                Label("Configured", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.success)
            } else {
                Button("Get Key") {
                    openURL(setupURL)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - About

private struct AboutTab: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EditOS")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(versionLabel)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(copyrightLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Button("Open Repository") {
                    if let url = URL(string: "https://github.com/DamilolaDami/EditOS") { openURL(url) }
                }
                Button("View Changelog") {
                    if let url = URL(string: "https://github.com/DamilolaDami/EditOS/blob/main/CHANGELOG.md") { openURL(url) }
                }
                Button("Report an Issue") {
                    if let url = URL(string: "https://github.com/DamilolaDami/EditOS/issues/new") { openURL(url) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var versionLabel: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(v) (build \(b))"
    }

    private var copyrightLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 Damilola. MIT License."
    }
}
