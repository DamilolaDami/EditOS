import SwiftUI

/// Marker pin strip rendered just above the time ruler.
///
/// Two layout constraints have to coexist: pins must be precisely
/// positioned along the timeline, and their hit-targets must align with
/// their visible bounds (so the ruler's `DragGesture(minimumDistance: 0)`
/// underneath doesn't steal taps).
///
/// We satisfy both by laying out each pin in its own full-width HStack
/// with a leading `Spacer().frame(width: timeOffset)` pushing it into
/// place. Using real layout (rather than `.position` or `.offset`) keeps
/// the hit region exactly under the visible pin in every SwiftUI version.
struct TimelineMarkerStrip: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel
    let pixelsPerSecond: CGFloat
    let duration: TimeInterval

    @State private var renamingID: Marker.ID?
    @State private var draftName: String = ""
    @State private var dragTimes: [Marker.ID: TimeInterval] = [:]
    @FocusState private var renameFocused: Bool

    static let height: CGFloat = 28

    private var stripWidth: CGFloat { max(1, CGFloat(duration) * pixelsPerSecond) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Visual placeholder so the ZStack sizes correctly. Explicit
            // .allowsHitTesting(false) means clicks on empty strip space
            // pass straight through — they don't get eaten before the
            // marker pin's gestures see them.
            Rectangle()
                .fill(Color.clear)
                .frame(width: stripWidth, height: Self.height)
                .allowsHitTesting(false)

            ForEach(model.project.timeline.markers) { marker in
                let liveTime = dragTimes[marker.id] ?? marker.time
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: max(0, CGFloat(liveTime) * pixelsPerSecond))
                        .allowsHitTesting(false)
                    MarkerPin(
                        marker: marker,
                        isRenaming: renamingID == marker.id,
                        draftName: $draftName,
                        renameFocused: $renameFocused,
                        pixelsPerSecond: pixelsPerSecond,
                        onSeek: { model.playback.seek(to: marker.time) },
                        onDragChanged: { delta in
                            let proposed = max(0, min(duration, marker.time + delta))
                            dragTimes[marker.id] = proposed
                        },
                        onDragEnded: {
                            if let proposed = dragTimes[marker.id] {
                                model.moveMarker(marker.id, to: proposed)
                            }
                            dragTimes.removeValue(forKey: marker.id)
                        },
                        onBeginRename: {
                            renamingID = marker.id
                            draftName = marker.label
                            DispatchQueue.main.async { renameFocused = true }
                        },
                        onCommitRename: { commitRename() },
                        onCancelRename: { renamingID = nil },
                        onChooseColor: { color in
                            model.setMarkerColor(marker.id, color: color)
                        },
                        onDelete: { model.deleteMarker(marker.id) }
                    )
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                }
                .frame(width: stripWidth, height: Self.height, alignment: .topLeading)
            }
        }
        .frame(width: stripWidth, height: Self.height, alignment: .topLeading)
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

/// Compact marker flag. Click to seek, double-click to rename, drag to
/// retime. A generous `.contentShape` plus `.highPriorityGesture` on the
/// drag keeps the touch on this view even if a parent has its own
/// drag-from-zero gesture.
private struct MarkerPin: View {
    @Environment(\.theme) private var theme
    let marker: Marker
    let isRenaming: Bool
    @Binding var draftName: String
    var renameFocused: FocusState<Bool>.Binding
    let pixelsPerSecond: CGFloat
    let onSeek: () -> Void
    let onDragChanged: (Double) -> Void
    let onDragEnded: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onChooseColor: (Marker.Color) -> Void
    let onDelete: () -> Void

    private var tint: Color { marker.color.swiftUIColor(theme: theme) }
    private var displayLabel: String {
        marker.label.isEmpty ? "Marker" : marker.label
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)

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
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(tint)
            )
            .shadow(color: tint.opacity(0.45), radius: 3, y: 1)

            Triangle()
                .fill(tint)
                .frame(width: 8, height: 5)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onBeginRename() }
        .onTapGesture(count: 1) { onSeek() }
        .highPriorityGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let pps = max(1, pixelsPerSecond)
                    onDragChanged(Double(value.translation.width / pps))
                }
                .onEnded { _ in onDragEnded() }
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

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension Marker.Color {
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
