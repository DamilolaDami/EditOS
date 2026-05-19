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

    static let projectInfo = InspectorInfo(
        title: "Project info",
        summary: "Top-level metadata for this project — canvas size, frame rate, total timeline duration, and asset count.",
        steps: [
            .init(symbol: "rectangle.ratio.16.to.9", title: "Resolution",
                  body: "Output canvas size. Set from the first imported video's native size, locked thereafter."),
            .init(symbol: "timer", title: "Frame rate",
                  body: "Frames per second used by the export pipeline."),
            .init(symbol: "clock", title: "Duration",
                  body: "End of the longest track. Updates as you trim or extend clips."),
            .init(symbol: "tray.full", title: "Assets",
                  body: "Imported media in this project's library."),
        ]
    )

    var body: some View {
        InspectorSection(title: "Project", info: Self.projectInfo) {
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
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel
    let clip: Clip

    /// Drives the rough-cut sheet shown for the currently-selected
    /// media clip. Carries the resolved file URL so the sheet doesn't
    /// have to re-resolve the security-scoped bookmark itself.
    @State private var roughCutSource: RoughCutSource?

    struct RoughCutSource: Identifiable {
        let id = UUID()
        let url: URL
        let asset: MediaAsset
        let duration: TimeInterval
    }

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
                roughCutSection
                timingSection(showSpeed: true)
                speedRampSection
                transitionSection
                audioSection
                beatSection
                captionsSection
                transformSection
            }
        }
    }

    // MARK: - Sections per kind

    /// Rough-cut entry point for media clips. Resolves the underlying
    /// asset URL on tap and opens the analysis sheet — the sheet
    /// drives `RoughCutEngine` and reports a curated set of segments
    /// back, which we drop on a new video track via
    /// `model.applyRoughCut(segments:sourceAsset:)`.
    private var roughCutSection: some View {
        InspectorSection(title: "Rough cut", systemImage: "wand.and.stars", info: Self.roughCutInfo) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Find highlight moments automatically — audio energy + face detection + motion analysis, all on-device.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                Button {
                    Task { await openRoughCutSheet() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Generate rough cut…")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.colors.accent))
                }
                .buttonStyle(.plain)
                .disabled(asset == nil)
            }
        }
        .sheet(item: $roughCutSource) { source in
            RoughCutSheet(
                sourceURL: source.url,
                sourceDisplayName: source.asset.displayName,
                sourceDuration: source.duration,
                onApply: { segments in
                    model.applyRoughCut(segments: segments, sourceAsset: source.asset)
                }
            )
        }
    }

    private var asset: MediaAsset? {
        model.project.assets.first { $0.id == clip.assetID }
    }

    private func openRoughCutSheet() async {
        guard let asset = self.asset else { return }
        // Resolve the security-scoped URL once here so the sheet can
        // run AVAssetReader on it without re-doing the bookmark dance.
        guard let url = try? await environment.assetResolver.resolve(asset) else { return }
        let duration = asset.duration
        await MainActor.run {
            roughCutSource = RoughCutSource(url: url, asset: asset, duration: duration)
        }
    }

    private func timingSection(showSpeed: Bool) -> some View {
        InspectorSection(title: "Timing", systemImage: "clock", info: Self.timingInfo) {
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
        InspectorSection(title: "Audio", systemImage: "speaker.wave.2.fill", info: Self.audioInfo) {
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

            // Gain envelope editor. Click to drop a keyframe, drag the
            // diamond to retime/regain, right-click to remove.
            let liveClip = currentClip(clip.id) ?? clip
            let hasEnvelope = (liveClip.volumeKeyframes?.isEmpty == false)

            HStack(spacing: 6) {
                Text(hasEnvelope ? "Gain Envelope" : "Add Gain Envelope")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.colors.textTertiary)
                Spacer()
                if hasEnvelope {
                    Button("Clear") {
                        model.setVolumeKeyframes(nil, on: clip.id)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.danger)
                }
            }

            VolumeEnvelopeView(model: model, clip: liveClip)

            Text(hasEnvelope
                 ? "Tap to add a keyframe · drag diamonds to adjust · right-click to delete."
                 : "Tap anywhere on the strip to drop your first keyframe.")
                .font(.system(size: 10))
                .foregroundStyle(theme.colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Rhythm / beat-detection entry point. Runs `BeatDetector` over
    /// the clip's audio and stores the resulting beat positions on the
    /// timeline so the ruler can draw tick marks and clip-edge drags
    /// can snap to them. Skipped if the underlying asset has no audio
    /// track (pure image clip).
    private var beatSection: some View {
        let asset = model.project.assets.first { $0.id == clip.assetID }
        let hasAudio = asset?.kind == .audio || asset?.kind == .video
        let isDetecting = model.detectingBeatsClipID == clip.id
        let timeline = model.project.timeline
        let beatCount = timeline.detectedBeats.count
        let tempo = timeline.detectedTempo

        return Group {
            if hasAudio {
                InspectorSection(title: "Rhythm", systemImage: "metronome", info: Self.rhythmInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detect beats from this clip's audio so clip edges snap to the rhythm grid and the ruler shows beat ticks.")
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button {
                                Task { await model.detectBeats(for: clip.id) }
                            } label: {
                                HStack(spacing: 6) {
                                    if isDetecting {
                                        ProgressView()
                                            .controlSize(.small)
                                            .scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "metronome")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    Text(isDetecting ? "Analysing…" : "Detect beats")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(theme.colors.accent.opacity(isDetecting ? 0.6 : 1.0)))
                            }
                            .buttonStyle(.plain)
                            .disabled(isDetecting)

                            if beatCount > 0 {
                                Button("Clear") {
                                    model.clearDetectedBeats()
                                }
                                .font(.system(size: 12, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.colors.danger)
                                .disabled(isDetecting)
                            }
                        }

                        if beatCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.colors.success)
                                Text(beatSummary(count: beatCount, tempo: tempo))
                                    .font(theme.typography.caption.monospacedDigit())
                                    .foregroundStyle(theme.colors.textSecondary)
                            }
                        }

                        if let error = model.lastBeatDetectionError {
                            Text(error)
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.colors.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func beatSummary(count: Int, tempo: Double?) -> String {
        guard let tempo, tempo > 0 else {
            return "\(count) beat\(count == 1 ? "" : "s") on the timeline"
        }
        return String(format: "%d beats · %.1f BPM", count, tempo)
    }

    // MARK: - Section info payloads
    //
    // Each section's explainer lives here as a static `InspectorInfo`
    // so the popover content stays close to the section that uses it
    // without growing per-instance state. The InspectorSection header
    // renders a shared "ⓘ" button next to the title when one of these
    // is supplied.

    static let roughCutInfo = InspectorInfo(
        title: "AI rough cut",
        summary: "Picks the most interesting seconds of a long clip and stacks them on a new video track.",
        steps: [
            .init(symbol: "waveform", title: "Audio energy",
                  body: "Loud passages (speech, action, impact) score higher."),
            .init(symbol: "face.smiling", title: "Face presence",
                  body: "Visible faces boost the surrounding seconds."),
            .init(symbol: "speedometer", title: "Camera motion",
                  body: "Settled framing is preferred over whip-pans and shaky hand-held."),
        ],
        tip: "Best for clips ≥ 3 minutes. Target output length is configurable in the sheet."
    )

    static let timingInfo = InspectorInfo(
        title: "Clip timing",
        summary: "Where this clip sits on the timeline and how fast it plays.",
        steps: [
            .init(symbol: "play.fill", title: "Start",
                  body: "Position on the timeline. Drag the clip body to move it."),
            .init(symbol: "ruler", title: "Duration",
                  body: "How long this clip occupies. Drag its leading or trailing edge to trim."),
            .init(symbol: "speedometer", title: "Speed",
                  body: "1× is real-time. Affects both audio and video; neighbours ripple-push on changes."),
        ]
    )

    static let audioInfo = InspectorInfo(
        title: "Audio",
        summary: "Master gain plus an optional keyframed gain envelope.",
        steps: [
            .init(symbol: "speaker.wave.2.fill", title: "Volume",
                  body: "Scalar gain in 0–100%. 100% is unity."),
            .init(symbol: "waveform.path", title: "Gain envelope",
                  body: "Tap the strip to drop keyframes for fades and ducks. Drag diamonds to retime."),
            .init(symbol: "mic.fill", title: "Voiceover ducking",
                  body: "Voiceover clips automatically dim music on overlapping ranges."),
        ],
        tip: "Right-click a keyframe to delete it."
    )

    static let rhythmInfo = InspectorInfo(
        title: "Beat detection",
        summary: "Find every beat in this clip's audio so clip edges snap to the rhythm grid.",
        steps: [
            .init(symbol: "waveform", title: "Analyses the audio",
                  body: "Runs an on-device FFT pass, finds every beat, and estimates the tempo."),
            .init(symbol: "circle.fill", title: "Marks the ruler",
                  body: "Each beat shows up as an accent dot on top of the timeline ruler. Zoom in if crowded."),
            .init(symbol: "magnet", title: "Snaps your edits",
                  body: "While Snap is on, dragging or trimming any clip pulls its edge to the nearest beat."),
        ],
        tip: "Run Detect Beats on the *music* clip, then drag your B-roll cuts. Edges will magnetise to the downbeat."
    )

    static let transitionInfo = InspectorInfo(
        title: "Transition out",
        summary: "Cross-clip blend between this clip's trailing edge and the next one on the same track.",
        steps: [
            .init(symbol: "rectangle.2.swap", title: "Overlap",
                  body: "The next clip's leading edge overlaps this one by `duration`."),
            .init(symbol: "scissors", title: "None",
                  body: "Hard cut. Pick a transition kind to enable the blend."),
            .init(symbol: "timer", title: "Duration",
                  body: "Capped to half the shorter clip's length so neither side gets eaten."),
        ]
    )

    static let speedRampInfo = InspectorInfo(
        title: "Speed ramp",
        summary: "Vary playback speed across the clip with keyframes — slow-mo highlights, time-lapse pans.",
        steps: [
            .init(symbol: "plus.circle", title: "Add keyframe",
                  body: "Tap the curve to drop a new control point."),
            .init(symbol: "speedometer", title: "Multiplier",
                  body: "0.1× to 8×. Affects both video and audio."),
            .init(symbol: "arrow.left.and.right", title: "Drag",
                  body: "Move keyframes horizontally to retime the curve."),
        ],
        tip: "Display duration recomputes from the curve — neighbours ripple-push automatically."
    )

    static let captionsInfo = InspectorInfo(
        title: "Auto captions",
        summary: "Transcribe this clip's audio into caption-track text overlays, on-device.",
        steps: [
            .init(symbol: "mic", title: "Speech recognition",
                  body: "Uses SFSpeechRecognizer — runs locally, no upload."),
            .init(symbol: "text.bubble", title: "One overlay per phrase",
                  body: "Each recognised segment becomes its own caption clip on a captions track."),
            .init(symbol: "scissors", title: "Respects trims",
                  body: "Segments outside the clip's `sourceRange` are skipped."),
        ],
        tip: "Re-running replaces the previous captions for this clip."
    )

    static let transformInfo = InspectorInfo(
        title: "Transform",
        summary: "Position, scale, rotation, and opacity on the project canvas.",
        steps: [
            .init(symbol: "arrow.up.left.and.arrow.down.right", title: "Translation",
                  body: "Slide the clip in canvas space."),
            .init(symbol: "magnifyingglass", title: "Scale",
                  body: "1.0 is native size. Above 1 zooms in (may crop)."),
            .init(symbol: "rotate.left", title: "Rotation",
                  body: "In degrees, clockwise positive."),
            .init(symbol: "circle.lefthalf.filled", title: "Opacity",
                  body: "0 is invisible, 1 is solid. Use for fade-style overlays."),
        ]
    )

    static let textInfo = InspectorInfo(
        title: "Text overlay",
        summary: "Body content and style for a caption / title clip.",
        steps: [
            .init(symbol: "textformat", title: "Body",
                  body: "What the overlay says."),
            .init(symbol: "paintpalette", title: "Colour",
                  body: "Foreground fill colour."),
            .init(symbol: "textformat.size", title: "Size",
                  body: "Font size in canvas points."),
        ],
        tip: "Pair with an animation preset (typewriter, fade-in, slide-in) for kinetic typography."
    )

    static let stickerInfo = InspectorInfo(
        title: "Sticker",
        summary: "SF Symbol or downloaded image (e.g. a GIPHY GIF) overlaid on the canvas.",
        steps: [
            .init(symbol: "face.smiling", title: "Source",
                  body: "Either an SF Symbol name or a path to a downloaded image."),
            .init(symbol: "paintpalette", title: "Tint",
                  body: "Applied to symbol-based stickers only."),
            .init(symbol: "textformat.size", title: "Size",
                  body: "Canvas-relative scale in points."),
        ]
    )

    static let filterInfo = InspectorInfo(
        title: "Filter",
        summary: "Colour-grading preset blended over this clip's pixels.",
        steps: [
            .init(symbol: "wand.and.stars", title: "Preset",
                  body: "Pick from the catalog. Each preset is a Core Image LUT."),
            .init(symbol: "slider.horizontal.3", title: "Intensity",
                  body: "0 disables the filter, 1 is full strength. Drag to dial in subtlety."),
            .init(symbol: "eye", title: "Live preview",
                  body: "The player updates immediately. Exports use the same pipeline."),
        ]
    )

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
                InspectorSection(title: "Transition Out", systemImage: "rectangle.2.swap", info: Self.transitionInfo) {
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
                InspectorSection(title: "Speed Ramp", systemImage: "speedometer", info: Self.speedRampInfo) {
                    let liveClip = currentClip(clip.id) ?? clip
                    let keyframes = liveClip.speedKeyframes ?? []

                    SpeedRampCurveView(
                        keyframes: keyframes,
                        sourceDuration: liveClip.sourceRange.duration,
                        height: 56
                    )

                    HStack(spacing: 8) {
                        Menu {
                            // Use Toggle so macOS renders a leading
                            // checkmark on the active item. The `set:`
                            // side just routes through applySpeedPreset
                            // — toggling "off" picks .none, which
                            // clears the curve.
                            ForEach(SpeedRampPreset.allCases) { preset in
                                Toggle(isOn: Binding(
                                    get: { liveClip.lastSpeedPreset == preset },
                                    set: { isOn in
                                        if isOn {
                                            model.applySpeedPreset(preset, on: clip.id)
                                        } else {
                                            model.applySpeedPreset(.none, on: clip.id)
                                        }
                                    }
                                )) {
                                    Label(preset.displayName, systemImage: preset.systemImage)
                                }
                            }
                        } label: {
                            // Button label echoes the active preset so
                            // the user can tell at a glance which curve
                            // is on — falls back to "Presets" when no
                            // ramp is applied yet.
                            HStack(spacing: 4) {
                                Image(systemName: liveClip.lastSpeedPreset?.systemImage ?? "wand.and.stars")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(liveClip.lastSpeedPreset?.displayName ?? "Presets")
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
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
                InspectorSection(title: "Captions", systemImage: "captions.bubble", info: Self.captionsInfo) {
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
        InspectorSection(title: "Transform", systemImage: "arrow.up.left.and.arrow.down.right", info: Self.transformInfo) {
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
        InspectorSection(title: "Text", systemImage: "textformat", info: Self.textInfo) {
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

            // Animation picker. Picks one of the kinetic-typography
            // presets to apply across the first N seconds of the clip;
            // None falls back to plain static text.
            let live = currentClip(clip.id) ?? clip
            Text("ANIMATION")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.colors.textTertiary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 64, maximum: 100), spacing: 6)],
                spacing: 6
            ) {
                AnimationChip(
                    label: "None",
                    systemImage: "minus.circle",
                    isSelected: live.textAnimation == nil
                ) {
                    updateClipDirect(clip.id) { $0.textAnimation = nil }
                    reload()
                }
                ForEach(TextAnimation.Kind.allCases) { kind in
                    AnimationChip(
                        label: kind.displayName,
                        systemImage: kind.systemImage,
                        isSelected: live.textAnimation?.kind == kind
                    ) {
                        let duration = live.textAnimation?.duration ?? 0.6
                        updateClipDirect(clip.id) {
                            $0.textAnimation = TextAnimation(kind: kind, duration: duration)
                        }
                        reload()
                    }
                }
            }

            if live.textAnimation != nil {
                SliderRow(
                    label: "Duration",
                    value: Binding(
                        get: { live.textAnimation?.duration ?? 0.6 },
                        set: { newValue in
                            let kind = live.textAnimation?.kind ?? .typewriter
                            updateClipDirect(clip.id) {
                                $0.textAnimation = TextAnimation(kind: kind, duration: newValue)
                            }
                        }
                    ),
                    range: 0.1...3.0,
                    format: { String(format: "%.2fs", $0) },
                    onCommit: reload
                )
            }
        }
    }

    /// Snapshot + mutate a clip directly, no Task hop. Used by the text
    /// animation picker which needs the inspector to reflect the new
    /// state immediately, then it reloads composition itself.
    private func updateClipDirect(_ id: Clip.ID, _ mutate: (inout Clip) -> Void) {
        model.recordSnapshot()
        for trackIndex in model.project.timeline.tracks.indices {
            if let clipIndex = model.project.timeline.tracks[trackIndex].clips
                .firstIndex(where: { $0.id == id }) {
                mutate(&model.project.timeline.tracks[trackIndex].clips[clipIndex])
                break
            }
        }
    }

    private var stickerSection: some View {
        InspectorSection(title: "Sticker", systemImage: "face.smiling", info: Self.stickerInfo) {
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
        InspectorSection(title: "Filter", systemImage: "wand.and.stars", info: Self.filterInfo) {
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

/// Compact grid cell for picking a text-animation preset. Same shape
/// as TransitionChip but tighter so we can fit 7+ presets in a single
/// inspector section.
private struct AnimationChip: View {
    @Environment(\.theme) private var theme
    let label: String
    let systemImage: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .padding(.vertical, 4)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
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
                RoundedRectangle(cornerRadius: 6)
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

/// Self-contained explainer payload for an inspector section. Each
/// section that opts in supplies one of these and `InspectorSection`
/// renders an "ⓘ" button in the header that opens a popover with the
/// content. The shape is intentionally rigid (summary + numbered
/// steps + optional tip) so every section's explainer reads the same.
struct InspectorInfo {
    let title: String
    let summary: String
    let steps: [Step]
    var tip: String? = nil

    struct Step {
        let symbol: String
        let title: String
        let body: String
    }
}

private struct InspectorSection<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    /// Optional SF Symbol shown beside the section label.
    var systemImage: String? = nil
    /// Optional explainer popover. When set, the section header grows
    /// an `ⓘ` button on its trailing edge that toggles the popover.
    var info: InspectorInfo? = nil
    @ViewBuilder var content: Content

    @State private var showInfo: Bool = false

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
                if let info {
                    Spacer(minLength: 0)
                    Button {
                        showInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("What is \(info.title)?")
                    .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                        InspectorInfoPopover(info: info)
                    }
                }
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

/// Renders an `InspectorInfo` payload as a compact popover: header,
/// summary line, then one row per step (symbol + title + body), and
/// finally an optional accent-tinted tip footer.
private struct InspectorInfoPopover: View {
    @Environment(\.theme) private var theme
    let info: InspectorInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
                Text(info.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
            }

            Text(info.summary)
                .font(.system(size: 11))
                .foregroundStyle(theme.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(info.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.colors.accent)
                            .frame(width: 16, alignment: .center)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.colors.textPrimary)
                            Text(step.body)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let tip = info.tip {
                Divider()
                Text(tip)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 280)
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
