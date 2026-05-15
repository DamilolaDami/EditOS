import SwiftUI

/// CapCut-style title bar that replaces the window's standard title bar.
/// Layout: [traffic-light spacer] [auto-saved timestamp] … [project name] …
/// [layout icons] [Pro] [Share] [Export].
struct EditorTopBar: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel
    @State private var isExportSheetPresented: Bool = false
    /// Distance reserved on the leading edge so the macOS traffic lights
    /// (close / minimize / zoom) sit cleanly without overlapping content.
    private let trafficLightInset: CGFloat = 78
    private let height: CGFloat = 40

    var body: some View {
        baseLayout
            .sheet(isPresented: $isExportSheetPresented) {
                ExportSheet(model: model)
            }
    }

    private var baseLayout: some View {
        ZStack {
            // Centered project name — placed in its own ZStack layer so the
            // flexible HStack on top doesn't pull it off centre.
            Text(model.project.name)
                .font(theme.typography.bodyEmphasized)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .help(model.project.name)

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

    private var autoSavedLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(theme.colors.success)
            Text("Auto saved: \(formattedSaveTime)")
                .font(theme.typography.caption.monospacedDigit())
                .foregroundStyle(theme.colors.textSecondary)
        }
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
            // Stub — share via system sheet later.
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                Text("Share")
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

    private var exportButton: some View {
        Button {
            isExportSheetPresented = true
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

    private var formattedSaveTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: model.project.modifiedAt)
    }
}
