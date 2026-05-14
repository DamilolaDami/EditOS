import SwiftUI

/// A bordered container used for the editor's media/preview/inspector regions.
struct EditorPanel<Content: View>: View {
    @Environment(\.theme) private var theme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(theme.colors.surface)
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .stroke(theme.colors.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.md))
    }
}
