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
                    VStack(alignment: .leading, spacing: theme.spacing.lg) {
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
        HStack {
            Text("Details")
                .font(theme.typography.title)
                .foregroundStyle(theme.colors.textPrimary)
            Spacer()
        }
        .padding(theme.spacing.sm)
    }
}

// MARK: - Project inspector (shown when no clip is selected)

private struct ProjectInspector: View {
    @Environment(\.theme) private var theme
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
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
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
            }
            InspectorSection(title: "Transform") {
                SliderRow(
                    label: "Opacity",
                    value: clipBinding(\.transform.opacity),
                    range: 0...1,
                    format: { String(format: "%.0f%%", $0 * 100) },
                    onCommit: nil  // visual-only for now until video composition lands
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

    private func reload() {
        Task { await model.reloadComposition() }
    }

    // MARK: - Bindings

    /// Speed must also shrink/expand the clip on the timeline so the change is
    /// visible. We keep `sourceRange` fixed and let `timeRange.duration` reflect
    /// the new playback duration.
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
        let inner = clipBinding(keyPath)
        return Binding(
            get: { Double(inner.wrappedValue) },
            set: { inner.wrappedValue = Float($0) }
        )
    }

    private func cgFloatBinding(_ keyPath: WritableKeyPath<Clip, CGFloat>) -> Binding<Double> {
        let inner = clipBinding(keyPath)
        return Binding(
            get: { Double(inner.wrappedValue) },
            set: { inner.wrappedValue = CGFloat($0) }
        )
    }

    private func degreesBinding(_ keyPath: WritableKeyPath<Clip, Double>) -> Binding<Double> {
        let inner = clipBinding(keyPath)
        return Binding(
            get: { inner.wrappedValue * 180 / .pi },
            set: { inner.wrappedValue = $0 * .pi / 180 }
        )
    }

    private func currentClip(_ id: Clip.ID) -> Clip? {
        model.project.timeline.tracks.flatMap(\.clips).first { $0.id == id }
    }
}

// MARK: - Shared rows

private struct InspectorSection<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Text(title.uppercased())
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textSecondary)
            content
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
            }
            Slider(
                value: $value,
                in: range,
                onEditingChanged: { editing in
                    if !editing { onCommit?() }
                }
            )
        }
    }
}
