import AppKit
import SwiftUI

/// Dedicated home for saved screen + camera captures. Pulled out of
/// the main Home page so raw recordings don't compete for attention
/// with project tiles — Home is "what you're working on", Recordings
/// is "what you've captured but haven't pulled into a project yet."
///
/// Layout: hero header (title + at-a-glance stats + folder reveal +
/// new-recording CTA), then a responsive adaptive grid of recording
/// tiles. Empty state has its own bigger illustration since this view
/// is meaningful even when empty (first-launch users see it as the
/// entry point for "record something").
struct HomeRecordingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment

    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .newest

    /// Adaptive grid — at 320pt min per tile, we fit 3 columns on a
    /// 1280-wide editor sidebar and degrade gracefully on narrower
    /// windows.
    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 18)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.xl) {
                header
                if filtered.isEmpty {
                    if environment.recordingsLibrary.entries.isEmpty {
                        emptyState
                    } else {
                        noMatchesState
                    }
                } else {
                    grid
                }
            }
            .padding(.horizontal, theme.spacing.xxl)
            .padding(.vertical, theme.spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.colors.background)
        .onAppear {
            environment.recordingsLibrary.refresh()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recordings")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Screen and camera captures. Open one to drop it on a fresh timeline.")
                        .font(theme.typography.body)
                        .foregroundStyle(theme.colors.textSecondary)
                }
                Spacer()
                headerActions
            }

            // Stats + filter row
            HStack(spacing: theme.spacing.md) {
                StatChip(systemImage: "rectangle.stack.fill", label: "\(entries.count)", sublabel: entries.count == 1 ? "Session" : "Sessions")
                StatChip(systemImage: "internaldrive", label: humanTotalSize, sublabel: "On disk")
                if pipCount > 0 {
                    StatChip(
                        systemImage: "video.fill",
                        label: "\(pipCount)",
                        sublabel: pipCount == 1 ? "With camera" : "With camera",
                        tint: theme.colors.accent
                    )
                }
                Spacer(minLength: 0)
                searchField
                sortMenu
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if let dir = RecordingsLibrary.recordingsDirectory(), !entries.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Show in Finder")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(theme.colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.colors.surface))
                    .overlay(Capsule().stroke(theme.colors.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button {
                environment.recorder.present()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New recording")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color(red: 0.95, green: 0.32, blue: 0.32)))
            }
            .buttonStyle(.plain)
            .help("Capture your screen")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.colors.textTertiary)
            TextField("Search recordings", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.colors.textPrimary)
                .frame(width: 180)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(theme.colors.surface))
        .overlay(Capsule().stroke(theme.colors.border, lineWidth: 1))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortOption.allCases, id: \.self) { option in
                Button {
                    sortOption = option
                } label: {
                    Label(option.label, systemImage: option.systemImage)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sortOption.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(sortOption.label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.colors.surface))
            .overlay(Capsule().stroke(theme.colors.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Grid + states

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(filtered) { entry in
                RecordingTile(entry: entry)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: theme.spacing.lg) {
            ZStack {
                Circle()
                    .fill(theme.colors.accent.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "record.circle")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
            }
            VStack(spacing: 4) {
                Text("No recordings yet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Capture your screen — optionally with your camera as a PIP — and we'll keep them here.")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            Button {
                environment.recorder.present()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Start your first recording")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color(red: 0.95, green: 0.32, blue: 0.32)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(theme.colors.textTertiary)
            Text("No recordings match \"\(searchText)\"")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)
            Button("Clear search") {
                searchText = ""
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    // MARK: - Data

    private var entries: [RecordingsLibrary.Entry] {
        environment.recordingsLibrary.entries
    }

    private var filtered: [RecordingsLibrary.Entry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = query.isEmpty
            ? entries
            : entries.filter { $0.displayName.lowercased().contains(query) }
        switch sortOption {
        case .newest:  return matched.sorted { $0.creationDate > $1.creationDate }
        case .oldest:  return matched.sorted { $0.creationDate < $1.creationDate }
        case .largest: return matched.sorted { $0.fileSize > $1.fileSize }
        case .name:    return matched.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    private var pipCount: Int {
        entries.filter { $0.hasCamera && !$0.isCameraOnly }.count
    }

    private var humanTotalSize: String {
        let total = entries.reduce(Int64(0)) { $0 + $1.fileSize }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: total)
    }

    enum SortOption: CaseIterable, Hashable {
        case newest, oldest, largest, name

        var label: String {
            switch self {
            case .newest:  "Newest first"
            case .oldest:  "Oldest first"
            case .largest: "Largest first"
            case .name:    "Name (A → Z)"
            }
        }

        var systemImage: String {
            switch self {
            case .newest:  "arrow.down"
            case .oldest:  "arrow.up"
            case .largest: "internaldrive"
            case .name:    "textformat"
            }
        }
    }
}

// MARK: - Stat chip

private struct StatChip: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    let label: String
    let sublabel: String
    var tint: Color?

    var body: some View {
        let resolvedTint = tint ?? theme.colors.accent
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(resolvedTint)
                .frame(width: 24, height: 24)
                .background(resolvedTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: -1) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(theme.colors.textPrimary)
                Text(sublabel.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.colors.textTertiary)
                    .tracking(0.4)
            }
        }
    }
}

// MARK: - Recording tile

/// Polished, grid-sized tile for one capture session. Larger 16:9
/// thumbnail than the old strip card; metadata stacked underneath
/// with proper hierarchy (title → date pill + size pill on the same
/// row → kind/PIP badges anchored on the thumbnail itself).
private struct RecordingTile: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment

    let entry: RecordingsLibrary.Entry

    @State private var isHovering = false
    @State private var thumbnail: CGImage?

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useKB, .useGB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnailBlock
                metadataBlock
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .fill(isHovering ? theme.colors.surfaceElevated : theme.colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .stroke(isHovering ? theme.colors.accent.opacity(0.4) : theme.colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu { contextMenu }
        .task(id: entry.id) {
            await loadThumbnail()
        }
    }

    private var thumbnailBlock: some View {
        ZStack {
            thumbnailContent
        }
        .aspectRatio(16.0/9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .stroke(theme.colors.border.opacity(0.6), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) { kindBadge }
        .overlay(alignment: .topTrailing) { pipBadge }
        .overlay(alignment: .center) {
            if isHovering {
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.55))
                        .frame(width: 46, height: 46)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(
                colors: [theme.colors.accent.opacity(0.30), theme.colors.accent.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                Image(systemName: entry.isCameraOnly ? "video.fill" : "rectangle.inset.filled")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            )
        }
    }

    private var kindBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: entry.isCameraOnly ? "video.fill" : "rectangle.inset.filled")
                .font(.system(size: 9, weight: .semibold))
            Text(entry.isCameraOnly ? "CAMERA" : "SCREEN")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.6)))
        .padding(8)
    }

    @ViewBuilder
    private var pipBadge: some View {
        if entry.hasCamera && !entry.isCameraOnly {
            HStack(spacing: 3) {
                Image(systemName: "video.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("PIP")
                    .font(.system(size: 9, weight: .heavy))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.colors.accent.opacity(0.85)))
            .padding(8)
        }
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                MetadataPill(systemImage: "clock", text: Self.dateFormatter.localizedString(for: entry.creationDate, relativeTo: .now))
                MetadataPill(systemImage: "internaldrive", text: Self.sizeFormatter.string(fromByteCount: entry.fileSize))
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            open()
        } label: {
            Label("Open in EditOS", systemImage: "wand.and.stars")
        }
        Divider()
        Button {
            if let url = entry.primaryURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Button {
            if let url = entry.primaryURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label("Preview in QuickTime", systemImage: "play.fill")
        }
        Divider()
        Button(role: .destructive) {
            environment.recordingsLibrary.delete(entry)
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }

    private func open() {
        guard let url = entry.primaryURL else { return }
        environment.recorder.openInEditor(url: url, pairedCamera: entry.cameraURL)
    }

    private func loadThumbnail() async {
        guard let url = entry.primaryURL else { return }
        let image = await environment.thumbnailGenerator.poster(
            for: url,
            at: 0,
            size: CGSize(width: 600, height: 338)
        )
        await MainActor.run { thumbnail = image }
    }
}

// MARK: - Metadata pill

private struct MetadataPill: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(theme.colors.textSecondary)
    }
}
