import SwiftUI

struct InspectorPanel: View {
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel

    var body: some View {
        EditorPanel {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(theme.colors.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.spacing.md) {
                        if let clip = model.selectedClip {
                            ClipInspector(model: model, clip: clip)
                        } else {
                            ProjectInspector(project: model.project)
                        }
                    }
                    .padding(theme.spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: theme.spacing.xs) {
            Text(model.selectedClip == nil ? "Project" : "Clip")
                .font(theme.typography.title)
                .foregroundStyle(theme.colors.textPrimary)
            if let clip = model.selectedClip {
                Text(clip.label ?? "Untitled")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.colors.surfaceElevated, in: Capsule())
            }
            Spacer()
        }
        .padding(theme.spacing.md)
    }
}

// MARK: - Project inspector

private struct ProjectInspector: View {
    let project: Project

    var body: some View {
        InspectorSection(title: "Project") {
            InspectorRow(label: "Name", value: project.name)
            InspectorRow(label: "Resolution", value: "\(Int(project.canvas.size.width)) × \(Int(project.canvas.size.height))")
            InspectorRow(label: "Frame rate", value: String(format: "%.2f fps", project.canvas.frameRate))
            InspectorRow(label: "Duration", value: String(format: "%.2fs", project.timeline.duration))
            InspectorRow(label: "Assets", value: "\(project.assets.count)")
        }
    }
}

// MARK: - Clip inspector

private struct ClipInspector: View {
    @Bindable var model: EditorViewModel
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if clip.text != nil || clip.stickerSymbol != nil {
                overlaySection
            }
            InspectorSection(title: "Timing") {
                InspectorRow(label: "Start", value: String(format: "%.2fs", clip.timeRange.start))
                InspectorRow(label: "Duration", value: String(format: "%.2fs", clip.timeRange.duration))
                SliderRow(
                    label: "Speed",
                    value: speedBinding,
                    range: 0.25...4.0,
                    format: { String(format: "%.2f×", $0) },
                    onCommit: reload
                )
            }
            InspectorSection(title: "Audio") {
                SliderRow(
                    label: "Volume",
                    value: floatBinding(\.volume),
                    range: 0...1,
                    format: { String(format: "%.0f%%", $0 * 100) },
                    onCommit: reload
                )
                MuteToggleRow(
                    isMuted: (currentClip(clip.id)?.volume ?? clip.volume) == 0,
                    onToggle: {
                        model.toggleClipMuted(clip.id)
                    }
                )
            }
            InspectorSection(title: "Transform") {
                SliderRow(
                    label: "Opacity",
                    value: clipBinding(\.transform.opacity),
                    range: 0...1,
                    format: { String(format: "%.0f%%", $0 * 100) },
                    onCommit: nil
                )
                SliderRow(
                    label: "Scale",
                    value: cgFloatBinding(\.transform.scale),
                    range: 0.1...4.0,
                    format: { String(format: "%.2f×", $0) },
                    onCommit: nil
                )
                SliderRow(
                    label: "Rotation",
                    value: degreesBinding(\.transform.rotation),
                    range: -180...180,
                    format: { String(format: "%.0f°", $0) },
                    onCommit: nil
                )
            }
        }
    }

    @ViewBuilder
    private var overlaySection: some View {
        InspectorSection(title: clip.stickerSymbol != nil ? "Sticker" : "Text") {
            if clip.text != nil {
                HStack(alignment: .firstTextBaseline) {
                    Text("Content")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    TextField("Text", text: textBinding)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if clip.stickerSymbol != nil {
                HStack(alignment: .firstTextBaseline) {
                    Text("Symbol")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    TextField("SF Symbol name", text: stickerBinding)
                        .textFieldStyle(.roundedBorder)
                }
            }
            SliderRow(
                label: "Size",
                value: overlaySizeBinding,
                range: 16...240,
                format: { String(format: "%.0f pt", $0) },
                onCommit: nil
            )
        }
    }

    private var textBinding: Binding<String> {
        let id = clip.id
        return Binding(
            get: { currentClip(id)?.text ?? "" },
            set: { newValue in
                model.updateClip(id) { c in
                    c.text = newValue
                    c.label = newValue
                }
            }
        )
    }

    private var stickerBinding: Binding<String> {
        let id = clip.id
        return Binding(
            get: { currentClip(id)?.stickerSymbol ?? "" },
            set: { newValue in
                model.updateClip(id) { c in
                    c.stickerSymbol = newValue
                    c.label = newValue
                }
            }
        )
    }

    private var overlaySizeBinding: Binding<Double> {
        let id = clip.id
        return Binding(
            get: { Double(currentClip(id)?.overlaySize ?? 64) },
            set: { newValue in
                model.updateClip(id) { c in
                    c.overlaySize = CGFloat(newValue)
                }
            }
        )
    }

    private func reload() {
        Task { await model.reloadComposition() }
    }

    private var speedBinding: Binding<Double> {
        let id = clip.id
        return Binding(
            get: { currentClip(id)?.speed ?? clip.speed },
            set: { newSpeed in
                model.updateClip(id) { c in
                    let safeSpeed = max(0.01, newSpeed)
                    c.speed = safeSpeed
                    c.timeRange = TimeRange(
                        start: c.timeRange.start,
                        duration: c.sourceRange.duration / safeSpeed
                    )
                }
            }
        )
    }

    private func clipBinding<Value>(_ keyPath: WritableKeyPath<Clip, Value>) -> Binding<Value> {
        let id = clip.id
        return Binding(
            get: { currentClip(id)?[keyPath: keyPath] ?? clip[keyPath: keyPath] },
            set: { newValue in
                model.updateClip(id) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func floatBinding(_ keyPath: WritableKeyPath<Clip, Float>) -> Binding<Double> {
        let inner: Binding<Float> = clipBinding(keyPath)
        return Binding(
            get: { Double(inner.wrappedValue) },
            set: { inner.wrappedValue = Float($0) }
        )
    }

    private func cgFloatBinding(_ keyPath: WritableKeyPath<Clip, CGFloat>) -> Binding<Double> {
        let inner: Binding<CGFloat> = clipBinding(keyPath)
        return Binding(
            get: { Double(inner.wrappedValue) },
            set: { inner.wrappedValue = CGFloat($0) }
        )
    }

    private func degreesBinding(_ keyPath: WritableKeyPath<Clip, Double>) -> Binding<Double> {
        let inner: Binding<Double> = clipBinding(keyPath)
        return Binding(
            get: { inner.wrappedValue * 180 / .pi },
            set: { inner.wrappedValue = $0 * .pi / 180 }
        )
    }

    private func currentClip(_ id: Clip.ID) -> Clip? {
        model.project.timeline.tracks.flatMap(\.clips).first { $0.id == id }
    }
}

// MARK: - Shared

private struct InspectorSection<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Text(title.uppercased())
                .font(theme.typography.sectionLabel)
                .foregroundStyle(theme.colors.textTertiary)
                .tracking(0.8)
            VStack(alignment: .leading, spacing: theme.spacing.md) {
                content
            }
            .padding(theme.spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .fill(theme.colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.md)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
        }
    }
}

private struct InspectorRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MuteToggleRow: View {
    @Environment(\.theme) private var theme
    let isMuted: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: theme.spacing.xs) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                Text(isMuted ? "Unmute clip" : "Mute clip")
                    .font(theme.typography.body)
                Spacer()
            }
            .padding(.horizontal, theme.spacing.sm)
            .padding(.vertical, theme.spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.sm)
                    .fill(isMuted ? theme.colors.danger.opacity(0.18) : theme.colors.surface)
            )
            .foregroundStyle(isMuted ? theme.colors.danger : theme.colors.textPrimary)
        }
        .buttonStyle(.plain)
    }
}

private struct SliderRow: View {
    @Environment(\.theme) private var theme
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onCommit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xxs) {
            HStack {
                Text(label)
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.textSecondary)
                Spacer()
                Text(format(value))
                    .font(theme.typography.displayMono)
                    .foregroundStyle(theme.colors.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: 4))
            }
            Slider(
                value: $value,
                in: range,
                onEditingChanged: { editing in
                    if !editing { onCommit?() }
                }
            )
            .tint(theme.colors.accent)
        }
    }
}
