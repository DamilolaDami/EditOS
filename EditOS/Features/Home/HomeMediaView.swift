import AppKit
import SwiftUI

/// Read-only global media browser. Aggregates every asset across every
/// project, groups them by project, and renders thumbnails. Tapping a tile
/// opens the owning project so the user can act on the asset there.
struct HomeMediaView: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow

    private let columns = [
        GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.xl) {
                header
                if environment.projectStore.projects.isEmpty {
                    emptyState
                } else {
                    ForEach(groupedProjects, id: \.project.id) { group in
                        projectGroup(group: group)
                    }
                }
            }
            .padding(.horizontal, theme.spacing.xxl)
            .padding(.vertical, theme.spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.colors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Media")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(summaryLabel)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.textTertiary)
            }
            Text("Everything you've imported across every project.")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textSecondary)
        }
    }

    private var summaryLabel: String {
        let projects = environment.projectStore.projects
        let assetCount = projects.reduce(0) { $0 + $1.assets.count }
        let projectCount = projects.filter { !$0.assets.isEmpty }.count
        return "\(assetCount) asset\(assetCount == 1 ? "" : "s") in \(projectCount) project\(projectCount == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        VStack(spacing: theme.spacing.md) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.colors.textTertiary)
            Text("Nothing imported yet")
                .font(theme.typography.title)
                .foregroundStyle(theme.colors.textPrimary)
            Text("Create a project and drop your media into it — it'll show up here.")
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textSecondary)
                .multilineTextAlignment(.center)
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

    private func projectGroup(group: ProjectGroup) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.project.name)
                    .font(theme.typography.bodyEmphasized)
                    .foregroundStyle(theme.colors.textPrimary)
                Text("\(group.project.assets.count)")
                    .font(theme.typography.caption.monospacedDigit())
                    .foregroundStyle(theme.colors.textTertiary)
                Spacer()
                Button("Open") {
                    openWindow(id: WindowID.editor.rawValue, value: group.project.id)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.colors.accent)
            }
            LazyVGrid(columns: columns, spacing: theme.spacing.sm) {
                ForEach(group.project.assets) { asset in
                    AssetTile(asset: asset, owningProjectID: group.project.id)
                }
            }
        }
        .padding(theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .fill(theme.colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.md)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }

    private struct ProjectGroup {
        let project: Project
    }

    private var groupedProjects: [ProjectGroup] {
        environment.projectStore.projects
            .filter { !$0.assets.isEmpty }
            .map { ProjectGroup(project: $0) }
    }
}

// MARK: - Tile

private struct AssetTile: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    let asset: MediaAsset
    let owningProjectID: Project.ID

    @State private var thumbnail: CGImage?
    @State private var isHovering = false

    var body: some View {
        Button {
            openWindow(id: WindowID.editor.rawValue, value: owningProjectID)
        } label: {
            VStack(alignment: .leading, spacing: theme.spacing.xxs) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.sm)
                        .fill(theme.colors.surfaceElevated)
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: icon(for: asset.kind))
                            .font(.system(size: 18))
                            .foregroundStyle(theme.colors.textSecondary)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 3) {
                        Image(systemName: icon(for: asset.kind))
                            .font(.system(size: 8, weight: .bold))
                        Text(durationLabel)
                            .font(theme.typography.caption.monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(6)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.sm)
                        .stroke(isHovering ? theme.colors.accent.opacity(0.6) : .clear, lineWidth: 1)
                )
                Text(asset.displayName)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        .task(id: asset.id) {
            await loadThumbnail()
        }
        .help("Open in \(asset.displayName)")
    }

    private var durationLabel: String {
        let total = max(0, asset.duration)
        if total >= 60 {
            return String(format: "%d:%02d", Int(total) / 60, Int(total) % 60)
        }
        return String(format: "%.1fs", total)
    }

    private func icon(for kind: MediaAsset.Kind) -> String {
        switch kind {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }

    private func loadThumbnail() async {
        guard asset.kind == .video || asset.kind == .image else { return }
        do {
            let url = try await environment.assetResolver.resolve(asset)
            let image = await environment.thumbnailGenerator.poster(
                for: url,
                at: 0,
                size: CGSize(width: 280, height: 280)
            )
            guard !Task.isCancelled else { return }
            thumbnail = image
        } catch {
            // Leave the icon fallback in place.
        }
    }
}
