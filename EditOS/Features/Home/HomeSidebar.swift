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
                Text("Video editing")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .listStyle(.sidebar)
    }
}
