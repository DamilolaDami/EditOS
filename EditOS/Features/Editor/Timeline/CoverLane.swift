import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Slim row at the very start of the timeline that lets the user attach a
/// cover image for the project — CapCut's "Cover" slot. Sits aligned with
/// time 0 of the ruler so it visually reads as "before the first clip".
struct CoverLane: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel

    @State private var thumbnail: CGImage?
    @State private var isImporterPresented = false

    private let height: CGFloat = 34
    private let slotWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isImporterPresented = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.sm)
                        .fill(theme.colors.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.radius.sm)
                                .stroke(theme.colors.borderEmphasis, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
                    } else {
                        VStack(spacing: 2) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("Cover")
                                .font(theme.typography.caption)
                        }
                        .foregroundStyle(theme.colors.textSecondary)
                    }
                }
                .frame(width: slotWidth, height: height - 4)
            }
            .buttonStyle(.plain)
            .help(thumbnail == nil ? "Add a cover image for this project" : "Replace the cover image")
            Spacer(minLength: 0)
        }
        .frame(height: height)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await applyCover(url) }
        }
        .task(id: coverFingerprint) {
            await loadThumbnail()
        }
    }

    private var coverFingerprint: Int {
        model.project.coverBookmark?.hashValue ?? 0
    }

    private func applyCover(_ url: URL) async {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        model.setCover(from: url)
        environment.projectStore.update(model.project)
        await loadThumbnail()
    }

    private func loadThumbnail() async {
        guard let bookmark = model.project.coverBookmark else {
            thumbnail = nil
            return
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            thumbnail = nil
            return
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        guard let nsImage = NSImage(contentsOf: url) else {
            thumbnail = nil
            return
        }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            thumbnail = nil
            return
        }
        thumbnail = cg
    }
}
