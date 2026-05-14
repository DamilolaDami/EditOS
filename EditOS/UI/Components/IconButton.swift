import SwiftUI

struct IconButton: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    let label: String
    var isOn: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: theme.spacing.xxs) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                Text(label)
                    .font(theme.typography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .frame(width: 60, height: 56)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.sm)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.sm)
                    .stroke(isOn ? theme.colors.accent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .help(label)
    }

    private var foreground: Color {
        if isOn { return theme.colors.accent }
        if isHovering { return theme.colors.textPrimary }
        return theme.colors.textSecondary
    }

    private var background: Color {
        if isOn { return theme.colors.accentMuted }
        if isHovering { return theme.colors.surfaceElevated }
        return .clear
    }
}
