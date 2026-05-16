import AppKit
import SwiftUI

struct ProjectGrid: View {
    @Environment(\.theme) private var theme
    let projects: [Project]
    @Binding var searchText: String
    @Binding var sortOption: ProjectSortOption
    let onOpen: (Project) -> Void

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.md) {
                Text("Projects".uppercased())
                    .font(theme.typography.sectionLabel)
                    .foregroundStyle(theme.colors.textTertiary)
                    .tracking(0.8)
                Spacer()
                ProjectSearchField(text: $searchText)
                    .frame(maxWidth: 220)
                ProjectSortMenu(selection: $sortOption)
                Text("\(projects.count) total")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .monospacedDigit()
            }
            if projects.isEmpty {
                EmptyProjectsCard(isSearching: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                LazyVGrid(columns: columns, spacing: theme.spacing.lg) {
                    ForEach(projects) { project in
                        ProjectCard(project: project) { onOpen(project) }
                    }
                }
            }
        }
    }
}

/// Slim inline text field for filtering the project grid. Renders a magnifying
/// glass on the left and a clear-button when the user has typed something.
private struct ProjectSearchField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.colors.textTertiary)
            TextField("Search projects", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? theme.colors.accent.opacity(0.6) : theme.colors.border, lineWidth: 1)
        )
    }
}

private struct ProjectSortMenu: View {
    @Environment(\.theme) private var theme
    @Binding var selection: ProjectSortOption

    var body: some View {
        Menu {
            ForEach(ProjectSortOption.allCases) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        Text(option.label)
                        if option == selection {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(selection.label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.colors.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct ProjectCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    let project: Project
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: CGImage?
    @State private var isRenaming = false
    @State private var draftName: String = ""
    @State private var isConfirmingDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                // Color.clear sets a strict 16:9 box for the cell; the
                // background gradient and the thumbnail overlay both render
                // inside that box and the outer .clipped() crops any
                // overflow. Without this, a tall/portrait image's intrinsic
                // ratio overrides .aspectRatio and the card grows.
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(
                        LinearGradient(
                            colors: [
                                theme.colors.surfaceElevated,
                                theme.colors.surface
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "film")
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(theme.colors.textTertiary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: theme.radius.md))
                    .overlay(alignment: .bottomLeading) {
                        Text(String(format: "%.1fs", max(0.1, project.timeline.duration)))
                            .font(theme.typography.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(theme.spacing.sm)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radius.md)
                            .stroke(isHovering ? theme.colors.accent.opacity(0.6) : theme.colors.border, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    if isRenaming {
                        TextField("Project name", text: $draftName)
                            .textFieldStyle(.plain)
                            .font(theme.typography.bodyEmphasized)
                            .focused($nameFocused)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(theme.colors.accent.opacity(0.6), lineWidth: 1)
                            )
                            .onSubmit { commitRename() }
                            .onExitCommand { isRenaming = false }
                            .onChange(of: nameFocused) { _, focused in
                                if !focused { commitRename() }
                            }
                    } else {
                        Text(project.name)
                            .font(theme.typography.bodyEmphasized)
                            .foregroundStyle(theme.colors.textPrimary)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { beginRename() }
                    }
                    Text(project.modifiedAt, format: .relative(presentation: .named))
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
            }
            .padding(theme.spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .fill(isHovering ? theme.colors.surface : Color.clear)
            )
            .scaleEffect(isHovering ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                beginRename()
            } label: { Label("Rename", systemImage: "pencil") }

            Button {
                onOpen()
            } label: { Label("Open", systemImage: "rectangle.stack") }

            Button {
                duplicateProject()
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }

            Divider()

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: { Label("Delete Project…", systemImage: "trash") }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .task(id: thumbnailKey) {
            await loadThumbnail()
        }
        .alert("Delete project?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                environment.recentProjects.forget(project.id)
                environment.projectStore.delete(project)
            }
        } message: {
            Text("\"\(project.name)\" will be removed permanently. This can't be undone, and any media files on disk stay where they are.")
        }
    }

    /// Duplicate the project as a brand new entry — same canvas + tracks +
    /// asset references, but a fresh id so the original stays intact.
    private func duplicateProject() {
        var copy = project
        copy = Project(
            id: UUID(),
            name: "\(project.name) Copy",
            canvas: project.canvas,
            assets: project.assets,
            timeline: project.timeline,
            coverBookmark: project.coverBookmark
        )
        environment.projectStore.update(copy)
        _ = copy  // silence unused warning when refactored
    }

    /// Distinguishes "cover changed" from "first video changed" so .task fires
    /// when either source updates.
    private var thumbnailKey: String {
        let cover = project.coverBookmark?.hashValue ?? 0
        let firstVideoID = project.assets.first(where: { $0.kind == .video })?.id.uuidString ?? ""
        return "\(project.id)|\(cover)|\(firstVideoID)"
    }

    /// Cover image preferred; if there isn't one, fall back to a poster frame
    /// from the first video asset.
    private func loadThumbnail() async {
        if let image = await loadCoverImage() {
            await MainActor.run { thumbnail = image }
            return
        }
        if let image = await loadFirstVideoPoster() {
            await MainActor.run { thumbnail = image }
            return
        }
        await MainActor.run { thumbnail = nil }
    }

    private func loadCoverImage() async -> CGImage? {
        guard let bookmark = project.coverBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func beginRename() {
        draftName = project.name
        isRenaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        defer { isRenaming = false }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        var updated = project
        updated.name = trimmed
        environment.projectStore.update(updated)
    }

    private func loadFirstVideoPoster() async -> CGImage? {
        guard let video = project.assets.first(where: { $0.kind == .video }) else { return nil }
        guard let url = try? await environment.assetResolver.resolve(video) else { return nil }
        return await environment.thumbnailGenerator.poster(
            for: url,
            at: 0,
            size: CGSize(width: 640, height: 360)
        )
    }
}

private struct EmptyProjectsCard: View {
    @Environment(\.theme) private var theme
    let isSearching: Bool

    var body: some View {
        VStack(spacing: theme.spacing.md) {
            Image(systemName: isSearching ? "magnifyingglass" : "film")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.colors.textTertiary)
            Text(isSearching ? "No matches" : "No projects yet")
                .font(theme.typography.title)
                .foregroundStyle(theme.colors.textPrimary)
            Text(isSearching ? "Try a different search term." : "Create one above to get started.")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .fill(theme.colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .stroke(theme.colors.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }
}
