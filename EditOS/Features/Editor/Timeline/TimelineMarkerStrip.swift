import SwiftUI

/// Marker pin strip rendered above (and overlapping with) the time ruler.
/// Each marker draws a small flag pinned to its `time` — click to seek,
/// drag to retime, double-click to rename inline, right-click for
/// rename / delete / color. The whole strip also catches right-clicks on
/// empty space to drop a new marker at that point.
struct TimelineMarkerStrip: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel
    let pixelsPerSecond: CGFloat
    let duration: TimeInterval

    @State private var renamingID: Marker.ID?
    @State private var draftName: String = ""
    @FocusState private var renameFocused: Bool

    private let height: CGFloat = 22

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Empty area for right-click → "Add marker here". Sits behind
            // the markers so pin gestures take priority.
            Color.clear
                .frame(width: max(1, CGFloat(duration) * pixelsPerSecond), height: height)
                .contentShape(Rectangle())
                .contextMenu {
                    Button {
                        model.addMarkerAtPlayhead()
                    } label: { Label("Add Marker at Playhead", systemImage: "flag.fill") }

                    if !model.project.timeline.markers.isEmpty {
                        Divider()
                        Button(role: .destructive) {
                            model.clearAllMarkers()
                        } label: { Label("Clear All Markers", systemImage: "trash") }
                    }
                }

            ForEach(model.project.timeline.markers) { marker in
                MarkerPin(
                    marker: marker,
                    isRenaming: renamingID == marker.id,
                    draftName: $draftName,
                    renameFocused: $renameFocused,
                    onSeek: { model.playback.seek(to: marker.time) },
                    onDrag: { newTime in
                        model.moveMarker(marker.id, to: max(0, min(newTime, duration)))
                    },
                    onBeginRename: {
                        renamingID = marker.id
                        draftName = marker.label
                        DispatchQueue.main.async { renameFocused = true }
                    },
                    onCommitRename: {
                        commitRename()
                    },
                    onCancelRename: {
                        renamingID = nil
                    },
                    onChooseColor: { color in
                        model.setMarkerColor(marker.id, color: color)
                    },
                    onDelete: {
                        model.deleteMarker(marker.id)
                    },
                    pixelsPerSecond: pixelsPerSecond
                )
            }
        }
        .frame(height: height, alignment: .topLeading)
        .onChange(of: renameFocused) { _, focused in
            if !focused, renamingID != nil { commitRename() }
        }
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            model.renameMarker(id, to: trimmed)
        }
        renamingID = nil
    }
}

/// One marker flag. Compact pill with a colored notch dropping toward the
/// time it pins. Handles drag-to-retime + the rename text field.
private struct MarkerPin: View {
    @Environment(\.theme) private var theme
    let marker: Marker
    let isRenaming: Bool
    @Binding var draftName: String
    var renameFocused: FocusState<Bool>.Binding
    let onSeek: () -> Void
    let onDrag: (TimeInterval) -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onChooseColor: (Marker.Color) -> Void
    let onDelete: () -> Void
    let pixelsPerSecond: CGFloat

    @State private var dragStartX: CGFloat?
    @State private var draggedTime: TimeInterval?

    private var tint: Color { marker.color.swiftUIColor(theme: theme) }
    private var displayLabel: String {
        marker.label.isEmpty ? "Marker" : marker.label
    }

    var body: some View {
        let liveTime = draggedTime ?? marker.time
        let xPosition = CGFloat(liveTime) * pixelsPerSecond

        HStack(spacing: 4) {
            Image(systemName: "flag.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)

            Group {
                if isRenaming {
                    TextField("Marker", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 60, maxWidth: 140)
                        .focused(renameFocused)
                        .onSubmit(onCommitRename)
                        .onExitCommand(perform: onCancelRename)
                } else {
                    Text(displayLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 4,
                topTrailingRadius: 4
            )
            .fill(tint)
        )
        .shadow(color: tint.opacity(0.4), radius: 3, y: 1)
        .overlay(alignment: .bottomLeading) {
            // Small triangular notch dropping toward the pinned time.
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 6, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 5))
                path.closeSubpath()
            }
            .fill(tint)
            .frame(width: 6, height: 5)
            .offset(y: 5)
        }
        .offset(x: xPosition, y: 0)
        .contentShape(Rectangle())
        .onTapGesture { onSeek() }
        .onTapGesture(count: 2) { onBeginRename() }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(TimelineCoordinateSpace.name))
                .onChanged { value in
                    if dragStartX == nil { dragStartX = xPosition }
                    let newX = (dragStartX ?? xPosition) + value.translation.width
                    let newTime = max(0, Double(newX / pixelsPerSecond))
                    draggedTime = newTime
                }
                .onEnded { _ in
                    if let t = draggedTime { onDrag(t) }
                    dragStartX = nil
                    draggedTime = nil
                }
        )
        .contextMenu {
            Button {
                onBeginRename()
            } label: { Label("Rename", systemImage: "pencil") }

            Menu {
                ForEach(Marker.Color.allCases) { color in
                    Button {
                        onChooseColor(color)
                    } label: {
                        Label(color.displayName, systemImage: color == marker.color
                              ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: { Label("Color", systemImage: "paintpalette") }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Delete Marker", systemImage: "trash")
            }
        }
        .help(marker.label.isEmpty ? "Unnamed marker" : marker.label)
    }
}

extension Marker.Color {
    /// Map a stored marker color to a SwiftUI `Color`, leaning on the
    /// app theme's accent for `.accent` so the badge picks up the user's
    /// preferred tint.
    func swiftUIColor(theme: Theme) -> Color {
        switch self {
        case .accent: return theme.colors.accent
        case .red:    return Color(red: 0.96, green: 0.42, blue: 0.42)
        case .orange: return Color(red: 0.96, green: 0.62, blue: 0.32)
        case .yellow: return Color(red: 0.96, green: 0.80, blue: 0.32)
        case .green:  return Color(red: 0.40, green: 0.85, blue: 0.60)
        case .blue:   return Color(red: 0.36, green: 0.72, blue: 1.0)
        case .purple: return Color(red: 0.62, green: 0.55, blue: 0.96)
        case .pink:   return Color(red: 0.95, green: 0.55, blue: 0.78)
        }
    }
}
