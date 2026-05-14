import SwiftUI

/// Left-side header for a single timeline track — track type icon and the
/// hide/mute/lock toggles. Sits in the fixed header column at the leading
/// edge of the timeline panel and does not scroll horizontally with the
/// timeline content.
struct TimelineTrackHeader: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel
    let track: Track

    private var isCompact: Bool { track.kind.timelineHeight < 40 }

    var body: some View {
        HStack(spacing: theme.spacing.xs) {
            Image(systemName: track.kind.systemImage)
                .font(.system(size: isCompact ? 10 : 12, weight: .semibold))
                .foregroundStyle(track.kind.color(in: theme))
                .frame(width: isCompact ? 14 : 16)
            if !isCompact {
                Text(track.kind.displayName)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 2) {
                HeaderToggle(
                    systemImage: track.isHidden ? "eye.slash.fill" : "eye",
                    isActive: track.isHidden,
                    activeTint: theme.colors.warning,
                    isCompact: isCompact,
                    help: track.isHidden ? "Show track" : "Hide track"
                ) {
                    model.toggleTrackHidden(track.id)
                }
                HeaderToggle(
                    systemImage: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2",
                    isActive: track.isMuted,
                    activeTint: theme.colors.danger,
                    isCompact: isCompact,
                    help: track.isMuted ? "Unmute track" : "Mute track"
                ) {
                    model.toggleTrackMuted(track.id)
                }
                HeaderToggle(
                    systemImage: track.isLocked ? "lock.fill" : "lock.open",
                    isActive: track.isLocked,
                    activeTint: theme.colors.accent,
                    isCompact: isCompact,
                    help: track.isLocked ? "Unlock track" : "Lock track"
                ) {
                    model.toggleTrackLocked(track.id)
                }
            }
        }
        .padding(.horizontal, isCompact ? 6 : theme.spacing.sm)
        .frame(maxHeight: .infinity)
        .background(theme.colors.surfaceElevated.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.sm)
                .stroke(theme.colors.border, lineWidth: 1)
                .opacity(0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.sm))
        .opacity(track.isHidden ? 0.55 : 1.0)
        .contextMenu {
            Button {
                model.toggleTrackHidden(track.id)
            } label: {
                Label(track.isHidden ? "Show Track" : "Hide Track",
                      systemImage: track.isHidden ? "eye" : "eye.slash")
            }
            Button {
                model.toggleTrackMuted(track.id)
            } label: {
                Label(track.isMuted ? "Unmute Track" : "Mute Track",
                      systemImage: track.isMuted ? "speaker.wave.2" : "speaker.slash")
            }
            Divider()
            Button(role: .destructive) {
                model.deleteTrack(track.id)
            } label: { Label("Delete Track", systemImage: "trash") }
        }
    }
}

private struct HeaderToggle: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    let isActive: Bool
    let activeTint: Color
    var isCompact: Bool = false
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isCompact ? 9 : 11, weight: .medium))
                .frame(width: isCompact ? 18 : 22, height: isCompact ? 18 : 22)
                .foregroundStyle(
                    isActive
                        ? activeTint
                        : theme.colors.textSecondary
                )
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovering ? theme.colors.surfaceHighest : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}
