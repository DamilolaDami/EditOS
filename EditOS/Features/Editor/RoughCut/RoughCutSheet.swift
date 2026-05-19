import AVFoundation
import SwiftUI

/// "Generate Rough Cut…" UI. Drives `RoughCutEngine`, shows live
/// stage + progress while it works, then a storyboard of proposed
/// segments the user can toggle on/off before accepting.
///
/// On accept, calls `onApply` with the user's chosen segments.
/// EditorViewModel takes that list and lays them out as clips on a
/// new video track above the original (which stays intact).
struct RoughCutSheet: View {
    @Environment(\.theme) private var theme
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let sourceURL: URL
    let sourceDisplayName: String
    let sourceDuration: TimeInterval
    let onApply: ([RoughCutEngine.Segment]) -> Void

    @State private var phase: Phase = .ready
    @State private var stage: RoughCutEngine.Stage = .readingAudio
    @State private var stageFraction: Double = 0
    @State private var result: RoughCutEngine.AnalysisResult?
    @State private var excludedSegmentIDs: Set<UUID> = []
    @State private var targetDuration: TimeInterval = 60
    @State private var thumbnails: [UUID: CGImage] = [:]

    enum Phase {
        case ready
        case analysing
        case result
        case error(String)
    }

    private static let availableDurations: [TimeInterval] = [15, 30, 60, 120, 180]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.colors.border.opacity(0.6))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().background(theme.colors.border.opacity(0.6))
            footer
        }
        .frame(width: 720, height: 540)
        .background(theme.colors.background)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
                Text("Generate Rough Cut")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(theme.colors.surface))
                        .overlay(Circle().stroke(theme.colors.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Text("\(sourceDisplayName) · \(Self.formatDuration(sourceDuration)) source")
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.textSecondary)
        }
        .padding(.horizontal, theme.spacing.lg)
        .padding(.vertical, theme.spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready:     readyView
        case .analysing: analysingView
        case .result:    resultView
        case .error(let message): errorView(message)
        }
    }

    private var footer: some View {
        HStack {
            switch phase {
            case .ready:
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    runAnalysis()
                } label: {
                    Label("Generate", systemImage: "wand.and.stars")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

            case .analysing:
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

            case .result:
                Text(acceptedSummaryLabel)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                Spacer()
                Button("Re-run") {
                    runAnalysis()
                }
                Button {
                    apply()
                } label: {
                    Label("Add to timeline", systemImage: "plus.rectangle.on.rectangle")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(acceptedSegments.isEmpty)

            case .error:
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try again") { runAnalysis() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, theme.spacing.lg)
        .padding(.vertical, theme.spacing.md)
        .background(theme.colors.surface.opacity(0.4))
    }

    // MARK: - Phases

    private var readyView: some View {
        VStack(spacing: theme.spacing.xl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(theme.colors.accent.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
            }
            VStack(spacing: 6) {
                Text("Find the highlights")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("EditOS reads audio energy, detects faces, and measures motion to pick the moments most worth keeping. Everything runs on-device.")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            HStack(spacing: 12) {
                Text("Target length")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.colors.textSecondary)
                Picker("", selection: $targetDuration) {
                    ForEach(Self.availableDurations, id: \.self) { d in
                        Text(Self.formatDuration(d)).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
            Spacer()
        }
        .padding(theme.spacing.xl)
    }

    private var analysingView: some View {
        VStack(spacing: theme.spacing.xl) {
            Spacer()
            ProgressView(value: stageFraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 440)
            VStack(spacing: 6) {
                Text(stage.rawValue + "…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Stage \(currentStageIndex) of 4")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }
            Spacer()
        }
        .padding(theme.spacing.xl)
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(resultHeadline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Tap a segment to exclude it from the cut.")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
                Spacer()
                if !excludedSegmentIDs.isEmpty {
                    Button("Reset selection") {
                        excludedSegmentIDs.removeAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.accent)
                    .font(.system(size: 12, weight: .medium))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(result?.segments ?? []) { seg in
                        SegmentCard(
                            segment: seg,
                            isExcluded: excludedSegmentIDs.contains(seg.id),
                            thumbnail: thumbnails[seg.id],
                            onToggle: { toggle(seg) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
        .padding(theme.spacing.lg)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: theme.spacing.md) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(theme.colors.danger)
            Text("Couldn't analyse this clip")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)
            Text(message)
                .font(theme.typography.body)
                .foregroundStyle(theme.colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .padding(theme.spacing.xl)
    }

    // MARK: - Logic

    private func runAnalysis() {
        phase = .analysing
        stage = .readingAudio
        stageFraction = 0
        excludedSegmentIDs = []
        thumbnails = [:]
        result = nil
        let url = sourceURL
        let duration = targetDuration
        let engine = environment.roughCutEngine
        Task {
            do {
                for try await event in engine.analyze(url: url, targetDuration: duration) {
                    switch event {
                    case .progress(let update):
                        stage = update.stage
                        stageFraction = update.fraction
                    case .complete(let analysisResult):
                        result = analysisResult
                        phase = .result
                        await loadThumbnails(for: analysisResult.segments)
                    }
                }
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    private func loadThumbnails(for segments: [RoughCutEngine.Segment]) async {
        for seg in segments {
            let thumb = await environment.thumbnailGenerator.poster(
                for: sourceURL,
                at: seg.startTime + seg.duration / 2,
                size: CGSize(width: 200, height: 112)
            )
            if let thumb {
                await MainActor.run {
                    self.thumbnails[seg.id] = thumb
                }
            }
        }
    }

    private func toggle(_ segment: RoughCutEngine.Segment) {
        if excludedSegmentIDs.contains(segment.id) {
            excludedSegmentIDs.remove(segment.id)
        } else {
            excludedSegmentIDs.insert(segment.id)
        }
    }

    private func apply() {
        onApply(acceptedSegments)
        dismiss()
    }

    private var acceptedSegments: [RoughCutEngine.Segment] {
        (result?.segments ?? []).filter { !excludedSegmentIDs.contains($0.id) }
    }

    private var resultHeadline: String {
        let count = result?.segments.count ?? 0
        let total = result?.segments.reduce(0.0) { $0 + $1.duration } ?? 0
        return "Found \(count) highlight\(count == 1 ? "" : "s") · \(Self.formatDuration(total)) total"
    }

    private var acceptedSummaryLabel: String {
        let count = acceptedSegments.count
        let total = acceptedSegments.reduce(0.0) { $0 + $1.duration }
        return "\(count) selected · \(Self.formatDuration(total))"
    }

    private var currentStageIndex: Int {
        switch stage {
        case .readingAudio:     return 1
        case .detectingFaces:   return 2
        case .measuringMotion:  return 3
        case .rankingSegments:  return 4
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

// MARK: - Segment card

private struct SegmentCard: View {
    @Environment(\.theme) private var theme
    let segment: RoughCutEngine.Segment
    let isExcluded: Bool
    let thumbnail: CGImage?
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 4) {
                thumbnailContent
                    .frame(width: 140, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(borderColor, lineWidth: isExcluded ? 1 : 2)
                    )
                    .opacity(isExcluded ? 0.4 : 1.0)
                    .overlay(alignment: .topTrailing) {
                        if isExcluded {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white, theme.colors.danger)
                                .padding(4)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(durationLabel)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .padding(4)
                    }
                Text(timeLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.colors.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .help(isExcluded ? "Click to include this segment" : "Click to exclude this segment")
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
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            )
        }
    }

    private var borderColor: Color {
        isExcluded ? theme.colors.border : theme.colors.accent
    }

    private var durationLabel: String {
        let total = segment.duration
        if total >= 1 { return String(format: "%.1fs", total) }
        return String(format: "%.2fs", total)
    }

    private var timeLabel: String {
        let s = Int(segment.startTime)
        let m = s / 60
        return String(format: "%02d:%02d", m, s % 60)
    }
}
