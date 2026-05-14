import SwiftUI

struct EditorToolbar: View {
    @Environment(\.theme) private var theme
    @Binding var selected: ToolCategory

    var body: some View {
        EditorPanel {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: theme.spacing.xs) {
                    ForEach(ToolCategory.allCases) { category in
                        IconButton(
                            systemImage: category.systemImage,
                            label: category.label,
                            isOn: selected == category
                        ) {
                            selected = category
                        }
                    }
                }
                .padding(.vertical, theme.spacing.sm)
                .padding(.horizontal, theme.spacing.xs)
            }
        }
        .frame(width: 78)
    }
}
