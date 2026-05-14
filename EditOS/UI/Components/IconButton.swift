import SwiftUI

struct IconButton: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    let label: String
    var isOn: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: theme.spacing.xxs) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                Text(label)
                    .font(theme.typography.caption)
            }
            .foregroundStyle(isOn ? theme.colors.accent : theme.colors.textSecondary)
            .frame(minWidth: 56, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
