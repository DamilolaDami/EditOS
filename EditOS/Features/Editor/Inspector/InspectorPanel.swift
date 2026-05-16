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
            if let clip = model.selectedClip {
                Image(systemName: clip.kind.headerSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
                    .frame(width: 22, height: 22)
                    .background(theme.colors.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                Text(clip.kind.headerTitle)
                    .font(theme.typography.title)
                    .foregroundStyle(theme.colors.textPrimary)
                Text(clip.label ?? "Untitled")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.colors.surfaceElevated, in: Capsule())
            } else {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
                    .frame(width: 22, height: 22)
                    .background(theme.colors.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                Text("Project")
                    .font(theme.typography.title)
                    .foregroundStyle(theme.colors.textPrimary)
            }
            Spacer()
        }
        .padding(theme.spacing.md)
    }
}

private extension Clip.Kind {
    var headerTitle: String {
        switch self {
        case .media: "Clip"
        case .text: "Text"
        case .sticker: "Sticker"
        case .filter: "Filter"
        }
    }

    var headerSymbol: String {
        switch self {
        case .media: "film"
        case .text: "textformat"
        case .sticker: "face.smiling"
        case .filter: "wand.and.stars"
        }
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
    @Environment(\.theme) private var theme
    @Bindable var model: EditorViewModel
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch clip.kind {
            case .text:
                textSection
                timingSection(showSpeed: false)
                transformSection
            case .sticker:
                stickerSection
                timingSection(showSpeed: false)
                transformSection
            case .filter:
                filterSection
                timingSection(showSpeed: false)
            case .media:
                timingSection(showSpeed: true)
                speedRampSection
                transitionSection
                audioSection
                captionsSection
                transformSection
            }
        }
    }

    // MARK: - Sections per kind

    private func timingSection(showSpeed: Bool) -> some View {
        InspectorSection(title: "Timing", systemImage: "clock") {
            InspectorRow(label: "Start", value: String(format: "%.2fs", clip.timeRange.start))
            InspectorRow(label: "Duration", value: String(format: "%.2fs", clip.timeRange.duration))
            if showSpeed {
                SliderRow(
                    label: "Speed",
                    value: speedBinding,
                    range: 0.25...4.0,
                    format: { String(format: "%.2f×", $0) },
                    onCommit: reload
                )
            }
        }
    }

    private var audioSection: some View {
        InspectorSection(title: "Audio", systemImage: "speaker.wave.2.fill") {
            SliderRow(
                label: "Volume",
                value: floatBinding(\.volume),
                range: 0...1,
                format: { String(format: "%.0f%%", $0 * 100) },
                onCommit: reload
            )
            MuteToggleRow(
                isMuted: (currentClip(clip.id)?.volume ?? clip.volume) == 0,
                onToggle: { model.toggleClipMuted(clip.id) }
            )
        }
    }

    /// Cross-clip transition (crossfade / dip-to-black). Shown only when
    /// this clip has a following clip on the same video track — that's
    /// the adjacency a transition can blend across.
    private var transitionSection: some View {
        let following = model.clipFollowing(clip.id)
        let liveClip = currentClip(clip.id) ?? clip
        let maxDuration: TimeInterval = {
            guard let following else { return 2.0 }
            return min(
                liveClip.timeRange.duration / 2,
                following.timeRange.duration / 2,
                4.0
            )
        }()

        return Group {
            if let following, following.kind == .media {
                InspectorSection(title: "Transition Out", systemImage: "rectangle.2.swap") {
                    HStack(spacing: 6) {
                        TransitionChip(
                            label: "None",
                            systemImage: "scissors",
                            isSelected: liveClip.transitionToNext == nil
                        ) {
                            model.setTransition(nil, on: clip.id)
                        }
                        ForEach(Transition.Kind.allCases) { kind in
                            TransitionChip(
                                label: kind.displayName,
                                systemImage: kind.systemImage,
                                isSelected: liveClip.transitionToNext?.kind == kind
                            ) {
                                let duration = liveClip.transitionToNext?.duration ?? 0.5
                                model.setTransition(
                                    Transition(kind: kind, duration: min(duration, maxDuration)),
                                    on: clip.id
                                )
                            }
                        }
                    }

                    if liveClip.transitionToNext != nil {
                        SliderRow(
                            label: "Duration",
                            value: Binding(
                                get: { liveClip.transitionToNext?.duration ?? 0.5 },
                                set: { newValue in
                                    let clamped = max(0.05, min(newValue, maxDuration))
                                    let kind = liveClip.transitionToNext?.kind ?? .crossfade
                                    model.setTransition(
                                        Transition(kind: kind, duration: clamped),
                                        on: clip.id
                                    )
                                }
                            ),
                            range: 0.1...max(0.2, maxDuration),
                            format: { String(format: "%.2fs", $0) },
                            onCommit: reload
                        )
                    }

                    Text("Blends with “\(following.label ?? "next clip")”.")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Compact curve editor + preset menu for speed ramping. Available
    /// only for media clips with a non-trivial source duration.
    private var speedRampSection: some View {
        let assetKind = model.project.assets.first(where: { $0.id == clip.assetID })?.kind
        let canRamp = (assetKind == .video || assetKind == .audio)
            && clip.sourceRange.duration > 0.2
        return Group {
            if canRamp {
                InspectorSection(title: "Speed Ramp", systemImage: "speedometer") {
                    let liveClip = currentClip(clip.id) ?? clip
                    let keyframes = liveClip.speedKeyframes ?? []

                    SpeedRampCurveView(
                        keyframes: keyframes,
                        sourceDuration: liveClip.sourceRange.duration,
                        height: 56
                    )

                    HStack(spacing: 8) {
                        Menu {
                            ForEach(SpeedRampPreset.allCases) { preset in
                                Button {
                                    model.applySpeedPreset(preset, on: clip.id)
                                } label: {
                                    Label(preset.displayName, systemImage: preset.systemImage)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Presets")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .menuStyle(.borderlessButton)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.colors.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.colors.border, lineWidth: 1)
                        )

                        Button {
                            model.setSpeedKeyframes(nil, on: clip.id)
                            reload()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Clear")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.colors.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.colors.border, lineWidth: 1)
                        )
                        .disabled(keyframes.isEmpty)
                        .opacity(keyframes.isEmpty ? 0.5 : 1.0)
                    }

                    if !keyframes.isEmpty {
                        let effective = liveClip.effectiveDisplayDuration()
                        Text(String(format: "Plays in %.2fs (source %.2fs)", effective, liveClip.sourceRange.duration))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.colors.textTertiary)
                    } else {
                        Text("Pick a preset to vary playback rate across the clip.")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var captionsSection: some View {
        let assetKind = model.project.assets.first(where: { $0.id == clip.assetID })?.kind
        let supportsCaptions = assetKind == .audio || assetKind == .video
        return Group {
            if supportsCaptions {
                InspectorSection(title: "Captions", systemImage: "captions.bubble") {
                    let isTranscribing = model.transcribingClipID == clip.id
                    Button {
                        Task { await model.generateCaptions(for: clip.id) }
                    } label: {
                        HStack(spacing: 6) {
                            if isTranscribing {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "wand.and.sparkles")
                            }
                            Text(isTranscribing ? "Transcribing…" : "Auto-Caption")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isTranscribing)

                    if let message = model.lastCaptionError {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.colors.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Drops a text overlay per phrase on the captions track.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var transformSection: some View {
        InspectorSection(title: "Transform", systemImage: "arrow.up.left.and.arrow.down.right") {
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

    private var textSection: some View {
        InspectorSection(title: "Text", systemImage: "textformat") {
            HStack(alignment: .firstTextBaseline) {
                Text("Content")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                TextField("Text", text: textBinding)
                    .textFieldStyle(.roundedBorder)
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

    private var stickerSection: some View {
        InspectorSection(title: "Sticker", systemImage: "face.smiling") {
            if clip.stickerImagePath != nil {
                InspectorRow(label: "Source", value: "GIPHY")
            } else if clip.stickerSymbol != nil {
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
                range: 32...400,
                format: { String(format: "%.0f pt", $0) },
                onCommit: nil
            )
        }
    }

    private var filterSection: some View {
        InspectorSection(title: "Filter", systemImage: "wand.and.stars") {
            HStack(spacing: 8) {
                Image(systemName: filterSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
                    .frame(width: 28, height: 28)
                    .background(theme.colors.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(filterName)
                        .font(theme.typography.bodyEmphasized)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Affects video beneath this clip")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
                Spacer(minLength: 0)
            }
            SliderRow(
                label: "Intensity",
                value: filterIntensityBinding,
                range: 0...1,
                format: { String(format: "%.0f%%", $0 * 100) },
                onCommit: reload
            )
        }
    }

    private var filterName: String {
        guard let id = clip.filterPreset else { return "Filter" }
        return FilterCatalog.find(id: id)?.displayName ?? "Filter"
    }

    private var filterSymbol: String {
        guard let id = clip.filterPreset else { return "wand.and.stars" }
        return FilterCatalog.find(id: id)?.symbol ?? "wand.and.stars"
    }

    private var filterIntensityBinding: Binding<Double> {
        let id = clip.id
        return Binding(
            get: { currentClip(id)?.filterIntensity ?? 1.0 },
            set: { newValue in
                model.updateClip(id) { c in
                    c.filterIntensity = max(0, min(1, newValue))
                }
            }
        )
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

private struct TransitionChip: View {
    @Environment(\.theme) private var theme
    let label: String
    let systemImage: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [theme.colors.accent, theme.colors.accent.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(theme.colors.surface)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        isSelected ? Color.white.opacity(0.15) : theme.colors.border,
                        lineWidth: 1
                    )
            )
            .foregroundStyle(isSelected ? .white : theme.colors.textPrimary)
        }
        .buttonStyle(.plain)
    }
}

private struct InspectorSection<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    /// Optional SF Symbol shown beside the section label.
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(theme.colors.textTertiary)
                }
                Text(title.uppercased())
                    .font(theme.typography.sectionLabel)
                    .foregroundStyle(theme.colors.textTertiary)
                    .tracking(0.8)
            }
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
