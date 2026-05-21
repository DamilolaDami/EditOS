import AppKit
import Sparkle
import SwiftUI

/// macOS Settings window. Wired into the `Settings { ... }` scene in
/// `EditOSApp`, which makes "EditOS → Settings…" (⌘,) show this view
/// automatically.
///
/// Tab layout follows Apple's macOS Settings conventions: each tab is a
/// section of related toggles; the right pane is settings-only (no
/// editor content). Tabs in V1.5:
/// - **General** — project defaults, snap default, autosave debounce.
/// - **Shortcuts** — per-action keyboard rebinding (issue #46).
/// - **Updates** — Sparkle controls (Check Now, auto-check interval).
/// - **Integrations** — GIPHY / Freesound config status.
/// - **About** — version, copyright, links.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection: Tab = .general

    enum Tab: String, Hashable, CaseIterable {
        case general, shortcuts, updates, integrations, about

        var label: String {
            switch self {
            case .general:      return "General"
            case .shortcuts:    return "Shortcuts"
            case .updates:      return "Updates"
            case .integrations: return "Integrations"
            case .about:        return "About"
            }
        }

        var systemImage: String {
            switch self {
            case .general:      return "gearshape"
            case .shortcuts:    return "keyboard"
            case .updates:      return "arrow.down.circle"
            case .integrations: return "puzzlepiece.extension"
            case .about:        return "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            GeneralTab(preferences: environment.preferences)
                .tabItem { Label(Tab.general.label, systemImage: Tab.general.systemImage) }
                .tag(Tab.general)
            ShortcutsTab(store: environment.shortcuts)
                .tabItem { Label(Tab.shortcuts.label, systemImage: Tab.shortcuts.systemImage) }
                .tag(Tab.shortcuts)
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
        .frame(width: 560, height: 460)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Environment(\.theme) private var theme
    @Bindable var preferences: PreferencesStore

    private static let supportedFrameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    var body: some View {
        Form {
            Section("New project defaults") {
                Picker("Canvas", selection: $preferences.defaultCanvasPreset) {
                    ForEach(CanvasPreset.allCases) { preset in
                        Label(preset.displayName, systemImage: preset.aspectGlyph).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(PreferencesStore.subtitle(for: preferences.defaultCanvasPreset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Frame rate", selection: $preferences.defaultFrameRate) {
                    ForEach(Self.supportedFrameRates, id: \.self) { fps in
                        Text(Self.formatFps(fps)).tag(fps)
                    }
                }
            }

            Section("Editing") {
                Toggle("Snap clip edges by default", isOn: $preferences.snapEnabledByDefault)
                    .help("Magnet icon in the timeline toolbar toggles this per-project mid-session.")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Debounce window")
                        Spacer()
                        Text(String(format: "%.1f s", preferences.autoSaveDebounce))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $preferences.autoSaveDebounce, in: 0.3...3.0, step: 0.1)
                }
            } header: {
                Text("Autosave")
            } footer: {
                Text("Bursts of edits inside this window collapse into one disk write. Smaller = saves more often (more I/O); larger = saves less often (more work at risk if you force-quit).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private static func formatFps(_ fps: Double) -> String {
        if abs(fps - fps.rounded()) < 0.01 {
            return "\(Int(fps.rounded())) fps"
        }
        return String(format: "%.2f fps", fps)
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @Environment(\.theme) private var theme
    @Bindable var store: ShortcutStore
    @State private var recordingAction: ShortcutAction?
    @State private var filter: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search + reset-all live above the scrollable list so they
            // don't compete with the per-row Reset buttons.
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Filter shortcuts", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Spacer()
                Button("Reset all") {
                    store.resetAll()
                }
                .controlSize(.small)
                .disabled(store.overrides.isEmpty)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(ShortcutAction.Category.allCases, id: \.self) { category in
                        let actions = filteredActions(in: category)
                        if !actions.isEmpty {
                            categorySection(category: category, actions: actions)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .sheet(item: $recordingAction) { action in
            ShortcutCaptureSheet(
                action: action,
                store: store,
                onCommit: { recordingAction = nil }
            )
        }
    }

    private func filteredActions(in category: ShortcutAction.Category) -> [ShortcutAction] {
        let actions = ShortcutAction.allCases.filter { $0.category == category }
        guard !filter.trimmingCharacters(in: .whitespaces).isEmpty else { return actions }
        let needle = filter.lowercased()
        return actions.filter {
            $0.displayName.lowercased().contains(needle)
                || store.binding(for: $0).displayLabel.lowercased().contains(needle)
        }
    }

    @ViewBuilder
    private func categorySection(category: ShortcutAction.Category, actions: [ShortcutAction]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.rawValue.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element) { idx, action in
                    ShortcutRow(
                        action: action,
                        binding: store.binding(for: action),
                        isCustomised: store.isCustomised(action),
                        conflicts: store.actionsBound(to: store.binding(for: action), excluding: action),
                        onRecord: { recordingAction = action },
                        onReset: { store.resetToDefault(action) }
                    )
                    if idx < actions.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 1))
        }
    }
}

/// Single row in the shortcuts list. Renders the action name, current
/// binding as a monospaced chip, conflict warning if any, and the
/// Record/Reset buttons. Tap the chip to start recording — same as
/// hitting Record.
private struct ShortcutRow: View {
    let action: ShortcutAction
    let binding: ShortcutBinding
    let isCustomised: Bool
    let conflicts: [ShortcutAction]
    let onRecord: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.displayName)
                    .font(.system(size: 12))
                if !conflicts.isEmpty {
                    Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(action: onRecord) {
                Text(binding.displayLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(NSColor.controlColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(isCustomised ? .accentColor.opacity(0.6) : Color(NSColor.separatorColor),
                                    lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Click to record a new shortcut")

            if isCustomised {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var conflictMessage: String {
        let names = conflicts.map(\.displayName).joined(separator: ", ")
        return "Also bound to: \(names)"
    }
}

/// Modal capture sheet. Installs an `NSEvent` local monitor on the
/// app's keyDown stream, intercepts the first usable key combo, and
/// hands a `ShortcutBinding` back to the store. Escape cancels.
private struct ShortcutCaptureSheet: View {
    let action: ShortcutAction
    @Bindable var store: ShortcutStore
    let onCommit: () -> Void

    @State private var monitor: Any?
    @State private var capturedBinding: ShortcutBinding?
    @State private var conflictNote: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.tint)

            Text("Press a shortcut")
                .font(.system(size: 14, weight: .semibold))

            Text("for \(action.displayName)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Group {
                if let capturedBinding {
                    Text(capturedBinding.displayLabel)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color(NSColor.controlColor)))
                } else {
                    Text("…")
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color(NSColor.controlColor)))
                }
            }

            if let conflictNote {
                Label(conflictNote, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if let capturedBinding {
                        store.rebind(action, to: capturedBinding)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(capturedBinding == nil)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
    }

    private func installMonitor() {
        // Local-monitor steals the keyDown event from the app's
        // normal responder chain so the captured combo doesn't also
        // fire its existing menu binding. Returning nil consumes it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape always cancels — don't try to bind it.
            if event.keyCode == 53 {
                DispatchQueue.main.async { dismiss() }
                return nil
            }
            if let binding = ShortcutBinding(from: event) {
                capturedBinding = binding
                let conflicts = store.actionsBound(to: binding, excluding: action)
                conflictNote = conflicts.isEmpty
                    ? nil
                    : "Will override: \(conflicts.map(\.displayName).joined(separator: ", "))"
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func dismiss() {
        removeMonitor()
        onCommit()
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
