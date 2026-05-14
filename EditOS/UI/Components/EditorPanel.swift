import SwiftUI

/// A bordered panel used for the editor's media, preview, inspector and timeline regions.
struct EditorPanel<Content: View>: View {
    @Environment(\.theme) private var theme
    let content: Content
    var padding: CGFloat? = nil

    init(padding: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding ?? 0)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .fill(theme.colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.md))
    }
}

/// A subtle inset card used for groups inside a panel (inspector sections, etc.)
struct InsetCard<Content: View>: View {
    @Environment(\.theme) private var theme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, theme.spacing.md)
            .padding(.vertical, theme.spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.sm)
                    .fill(theme.colors.surfaceElevated)
            )
    }
}
