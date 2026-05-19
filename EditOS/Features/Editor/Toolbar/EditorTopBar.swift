import AppKit
import SwiftUI

/// CapCut-style title bar that replaces the window's standard title bar.
/// Layout: [traffic-light spacer] [auto-saved timestamp] … [project name] …
/// [layout icons] [Pro] [Share] [Export].
struct EditorTopBar: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel
    /// A fresh token per Export click. Using `.sheet(item:)` keyed off this
    /// token forces SwiftUI to build a brand-new `ExportSheet` each time
    /// the user hits Export — otherwise leftover `@State` from a previous
    /// run (e.g. a `.finished` phase) can keep the configure form hidden
    /// or show stale content until the user nudges the timeline.
    @State private var exportToken: ExportToken?
    @State private var isRenamingProject: Bool = false
    @State private var draftProjectName: String = ""
    @FocusState private var renameFocused: Bool

    struct ExportToken: Identifiable {
        let id = UUID()
    }
    /// Distance reserved on the leading edge so the macOS traffic lights
    /// (close / minimize / zoom) sit cleanly without overlapping content.
    private let trafficLightInset: CGFloat = 78
    private let height: CGFloat = 40

    var body: some View {
        baseLayout
            .sheet(item: $exportToken) { _ in
                ExportSheet(model: model)
            }
    }

    private var baseLayout: some View {
        ZStack {
            // Centered project name — placed in its own ZStack layer so the
            // flexible HStack on top doesn't pull it off centre. Double-click
            // turns the label into an inline rename field.
            projectNameField

            HStack(spacing: theme.spacing.sm) {
                Color.clear.frame(width: trafficLightInset, height: 1)
                autoSavedLabel
                Spacer(minLength: 0)
                rightSideActions
            }
        }
        .frame(height: height)
        .background(theme.colors.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: 1)
        }
    }

    /// Live save indicator. Drives copy + colour off `model.saveStatus`,
    /// and wraps the "Saved 3m ago" branch in a `TimelineView` so the
    /// relative timestamp ticks forward without anything else having to
    /// re-render. The chip itself never lays out — its width is steady so
    /// surrounding controls don't dance every time the status flips.
    private var autoSavedLabel: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            let snapshot = saveSnapshot(at: ctx.date)
            HStack(spacing: 4) {
                Image(systemName: snapshot.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(snapshot.tint)
                Text(snapshot.label)
                    .font(theme.typography.caption.monospacedDigit())
                    .foregroundStyle(theme.colors.textSecondary)
                    .animation(.none, value: snapshot.label)
            }
            .help(snapshot.tooltip)
        }
    }

    private struct SaveSnapshot {
        let symbol: String
        let tint: Color
        let label: String
        let tooltip: String
    }

    private func saveSnapshot(at now: Date) -> SaveSnapshot {
        switch model.saveStatus {
        case .idle:
            return SaveSnapshot(
                symbol: "checkmark.circle.fill",
                tint: theme.colors.success,
                label: "Saved",
                tooltip: "All changes saved"
            )
        case .pendingChanges:
            return SaveSnapshot(
                symbol: "circle.dotted",
                tint: theme.colors.warning,
                label: "Unsaved changes",
                tooltip: "Saving in a moment…"
            )
        case .saving:
            return SaveSnapshot(
                symbol: "arrow.triangle.2.circlepath",
                tint: theme.colors.accent,
                label: "Saving…",
                tooltip: "Writing to disk"
            )
        case .saved(let when):
            return SaveSnapshot(
                symbol: "checkmark.circle.fill",
                tint: theme.colors.success,
                label: "Saved \(Self.relativePhrase(for: when, now: now))",
                tooltip: "Last saved \(Self.absoluteTime(for: when))"
            )
        case .error(let message):
            return SaveSnapshot(
                symbol: "exclamationmark.triangle.fill",
                tint: theme.colors.danger,
                label: "Save failed",
                tooltip: message
            )
        }
    }

    private static func relativePhrase(for when: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(when))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        return "\(hours)h ago"
    }

    private static func absoluteTime(for when: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: when)
    }

    private var rightSideActions: some View {
        HStack(spacing: theme.spacing.xs) {
            iconButton(systemImage: "rectangle.split.2x1", help: "Layout") {}
            iconButton(systemImage: "doc.text", help: "Notes") {}

            Divider().frame(height: 16)

            proButton
            shareButton
            exportButton
                .padding(.trailing, theme.spacing.sm)
        }
    }

    private var proButton: some View {
        Button {
            // Stub — opens the upgrade dialog later.
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "diamond.fill")
                Text("Pro")
            }
            .font(theme.typography.body)
            .padding(.horizontal, theme.spacing.sm)
            .padding(.vertical, 5)
            .foregroundStyle(theme.colors.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.colors.surfaceElevated)
            )
        }
        .buttonStyle(.plain)
    }

    private var shareButton: some View {
        Button {
            presentShareSheet()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                Text("Share")
            }
            .font(theme.typography.body)
            .padding(.horizontal, theme.spacing.sm)
            .padding(.vertical, 5)
            .foregroundStyle(model.lastExportedURL == nil
                             ? theme.colors.textSecondary
                             : theme.colors.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.colors.surfaceElevated)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.lastExportedURL == nil)
        .help(model.lastExportedURL == nil
              ? "Export the project first to share it"
              : "Share \(model.lastExportedURL?.lastPathComponent ?? "")")
    }

    /// Inline rename: shows a focused text field while editing, otherwise the
    /// static project title. Double-click or use the Rename context menu to
    /// enter edit mode; Enter or focus-loss commits, Esc cancels.
    @ViewBuilder
    private var projectNameField: some View {
        if isRenamingProject {
            TextField("Project name", text: $draftProjectName)
                .font(theme.typography.bodyEmphasized)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .focused($renameFocused)
                .frame(minWidth: 140, maxWidth: 320)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.colors.surfaceElevated, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.colors.accent.opacity(0.55), lineWidth: 1)
                )
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
                .onChange(of: renameFocused) { _, focused in
                    if !focused { commitRename() }
                }
        } else {
            Text(model.project.name)
                .font(theme.typography.bodyEmphasized)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .help("Double-click to rename")
                .onTapGesture(count: 2) { beginRename() }
                .contextMenu {
                    Button("Rename Project…") { beginRename() }
                }
        }
    }

    private func beginRename() {
        draftProjectName = model.project.name
        isRenamingProject = true
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        let trimmed = draftProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            model.renameProject(to: trimmed)
        }
        isRenamingProject = false
    }

    private func cancelRename() {
        isRenamingProject = false
    }

    /// Show the system share sheet for the most recent export. Anchored to
    /// the top bar's window so the popover appears next to the button.
    private func presentShareSheet() {
        guard let url = model.lastExportedURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let picker = NSSharingServicePicker(items: [url])
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           let contentView = window.contentView {
            // Position the picker under the top-trailing area where Share
            // sits. A small rect at the top-right of the content view is a
            // good-enough anchor.
            let rect = NSRect(x: contentView.bounds.width - 260, y: contentView.bounds.height - 8, width: 1, height: 1)
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }

    private var exportButton: some View {
        Button {
            exportToken = ExportToken()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up.fill")
                Text("Export")
                    .fontWeight(.semibold)
            }
            .font(theme.typography.body)
            .padding(.horizontal, theme.spacing.md)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.colors.accent)
            )
        }
        .buttonStyle(.plain)
    }

    private func iconButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }

}
