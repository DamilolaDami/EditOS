import SwiftUI

struct HomeSidebar: View {
    @Environment(\.theme) private var theme
    @Binding var selection: HomeSection

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(HomeSection.allCases, id: \.self) { section in
                    Label(section.label, systemImage: section.systemImage)
                        .tag(section)
                }
            } header: {
                Text("Library")
                    .font(theme.typography.sectionLabel)
                    .foregroundStyle(theme.colors.textTertiary)
                    .tracking(0.8)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarAccountChip()
                .padding(theme.spacing.sm)
        }
    }
}

private struct SidebarAccountChip: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.spacing.sm) {
            Circle()
                .fill(theme.colors.accent.opacity(0.85))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text("Local workspace")
                    .font(theme.typography.bodyEmphasized)
                    .foregroundStyle(theme.colors.textPrimary)
                Text("All projects stored locally")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(theme.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .fill(theme.colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }
}
