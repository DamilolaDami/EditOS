import AVFoundation
import AppKit
import SwiftUI

/// Modal sheet presented from the editor's top bar Export button.
///
/// Three-phase flow: configure → exporting → finished (or failed).
/// Persists the user's last-chosen quality / format / framerate /
/// destination via `@AppStorage` so subsequent exports are one-tap.
struct ExportSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel

    // MARK: - Persisted preferences

    @AppStorage("export.lastQualityRaw") private var qualityRaw: String = Quality.hd1080.rawValue
    @AppStorage("export.lastFormatRaw") private var formatRaw: String = Format.mp4H264.rawValue
    @AppStorage("export.lastFrameRateRaw") private var frameRateRaw: Int = FrameRate.matchSource.rawValue
    @AppStorage("export.includeAudio") private var includeAudio: Bool = true
    @AppStorage("export.openOnFinish") private var openOnFinish: Bool = false
    @AppStorage("export.lastDestinationBookmark") private var destinationBookmark: Data?

    // MARK: - Local state

    @State private var filename: String = ""
    @State private var destinationFolder: URL?
    @State private var phase: Phase = .configuring
    @State private var progress: Double = 0
    /// Animated/smoothed progress for the displayed counter — interpolates
    /// toward `progress` so the number doesn't tick in big jumps.
    @State private var displayProgress: Double = 0
    @State private var exportStartedAt: Date?
    @State private var exportTask: Task<Void, Never>?

    enum Phase {
        case configuring
        case exporting
        case finished(URL)
        case failed(String)
    }

    private var quality: Quality { Quality(rawValue: qualityRaw) ?? .hd1080 }
    private var format: Format { Format(rawValue: formatRaw) ?? .mp4H264 }
    private var frameRate: FrameRate { FrameRate(rawValue: frameRateRaw) ?? .matchSource }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.colors.border.opacity(0.5))
            content
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
        }
        .frame(width: 560)
        .background(
            ZStack {
                theme.colors.background
                LinearGradient(
                    colors: [theme.colors.accent.opacity(0.10), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
        )
        .onAppear { initializeDefaults() }
        .onDisappear { exportTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [theme.colors.accent, theme.colors.accent.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: phaseIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .shadow(color: theme.colors.accent.opacity(0.45), radius: 8, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(headerSubtitle)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }

            Spacer()

            Button {
                exportTask?.cancel()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(theme.colors.surface, in: Circle())
                    .overlay(Circle().stroke(theme.colors.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerTitle: String {
        switch phase {
        case .configuring: return "Export"
        case .exporting:   return "Rendering"
        case .finished:    return "Done"
        case .failed:      return "Export Failed"
        }
    }

    private var headerSubtitle: String {
        switch phase {
        case .configuring: return "Pick a format and save your project as a video."
        case .exporting:   return "Keep this window open — output is being encoded."
        case .finished(let url): return url.lastPathComponent
        case .failed:      return "Something went wrong."
        }
    }

    private var phaseIcon: String {
        switch phase {
        case .configuring: return "square.and.arrow.up.fill"
        case .exporting:   return "gearshape.2.fill"
        case .finished:    return "checkmark"
        case .failed:      return "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Phase content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .configuring:
            configuringView
        case .exporting:
            exportingView
        case .finished(let url):
            finishedView(url: url)
        case .failed(let message):
            failedView(message: message)
        }
    }

    // MARK: - Configuring

    private var configuringView: some View {
        VStack(alignment: .leading, spacing: 18) {
            projectSummary

            qualitySection
            formatSection

            HStack(spacing: 12) {
                fpsSection
                audioToggleSection
            }

            fileSection

            HStack(spacing: 10) {
                openOnFinishToggle
                Spacer()
                cancelButton
                exportButton
            }
        }
    }

    private var projectSummary: some View {
        HStack(spacing: 12) {
            SummaryStat(
                value: formatTime(model.project.timeline.duration),
                label: "Duration"
            )
            divider
            SummaryStat(
                value: "\(Int(model.project.canvas.size.width)) × \(Int(model.project.canvas.size.height))",
                label: "Canvas"
            )
            divider
            SummaryStat(
                value: "\(Int(model.project.canvas.frameRate)) fps",
                label: "Source"
            )
            Spacer(minLength: 0)
            SummaryStat(
                value: estimatedSize,
                label: "Est. size",
                alignment: .trailing
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.colors.surface.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.colors.border.opacity(0.6), lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.colors.border.opacity(0.5))
            .frame(width: 1, height: 28)
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Quality")
            HStack(spacing: 8) {
                ForEach(Quality.allCases) { value in
                    QualityChip(value: value, isSelected: value == quality) {
                        qualityRaw = value.rawValue
                    }
                }
            }
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Format")
            HStack(spacing: 8) {
                ForEach(Format.allCases) { value in
                    FormatChip(value: value, isSelected: value == format) {
                        formatRaw = value.rawValue
                    }
                }
            }
        }
    }

    private var fpsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Frame rate")
            Menu {
                ForEach(FrameRate.allCases) { value in
                    Button {
                        frameRateRaw = value.rawValue
                    } label: {
                        HStack {
                            Text(value.displayName)
                            if value == frameRate {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.colors.textSecondary)
                    Text(frameRate.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.colors.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.colors.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var audioToggleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Audio")
            Toggle(isOn: $includeAudio) {
                HStack(spacing: 6) {
                    Image(systemName: includeAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(includeAudio ? theme.colors.accent : theme.colors.textTertiary)
                    Text(includeAudio ? "Include audio" : "Video only")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.colors.textPrimary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Save as")
            HStack(spacing: 0) {
                TextField("Untitled", text: $filename)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                Text(".\(format.fileExtension)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.colors.textSecondary)
                    .padding(.trailing, 12)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.colors.border, lineWidth: 1)
            )

            Button {
                pickDestination()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(theme.colors.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Save to")
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                        Text(destinationDisplay)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text("Change")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.colors.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.colors.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var openOnFinishToggle: some View {
        Toggle(isOn: $openOnFinish) {
            Text("Open when finished")
                .font(.system(size: 11))
                .foregroundStyle(theme.colors.textSecondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            Text("Cancel")
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 78)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .foregroundStyle(theme.colors.textPrimary)
        .keyboardShortcut(.cancelAction)
    }

    private var exportButton: some View {
        Button {
            startExport()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("Export")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(minWidth: 96)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    LinearGradient(
                        colors: [theme.colors.accent, theme.colors.accent.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .shadow(color: theme.colors.accent.opacity(0.35), radius: 6, y: 2)
        .opacity(canExport ? 1 : 0.45)
        .disabled(!canExport)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: - Exporting

    private var exportingView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .lastTextBaseline) {
                    Text("\(Int(displayProgress * 100))")
                        .font(.system(size: 48, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(theme.colors.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.2), value: Int(displayProgress * 100))
                    Text("%")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.colors.textSecondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(etaLabel)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.colors.textPrimary)
                            .monospacedDigit()
                        Text("ETA")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(theme.colors.textTertiary)
                    }
                }
                progressBar
                exportMetaRow
            }

            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.colors.textTertiary)
                Text("Hardware-encoded on your Mac. Closing this window cancels it.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                Spacer()
                Button {
                    exportTask?.cancel()
                    phase = .configuring
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.colors.danger)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.colors.surface)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.colors.accent,
                                theme.colors.accent.opacity(0.65)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, proxy.size.width * displayProgress))
                    .shadow(color: theme.colors.accent.opacity(0.55), radius: 4, y: 0)
                    .animation(.easeOut(duration: 0.2), value: displayProgress)
                // Indeterminate shimmer effect, visible while not at 100.
                if displayProgress > 0.01 && displayProgress < 0.99 {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                        let phase = context.date.timeIntervalSince1970
                            .truncatingRemainder(dividingBy: 1.5) / 1.5
                        Capsule()
                            .fill(.white.opacity(0.16))
                            .frame(width: 60)
                            .offset(x: CGFloat(phase) * proxy.size.width)
                            .mask(
                                Capsule()
                                    .frame(width: max(0, proxy.size.width * displayProgress))
                            )
                    }
                }
            }
        }
        .frame(height: 10)
    }

    private var exportMetaRow: some View {
        HStack(spacing: 16) {
            metaPair(icon: "rectangle.expand.vertical", label: quality.displayName, hint: quality.dimensions)
            metaPair(icon: "film", label: format.displayName, hint: format.codecHint)
            if let started = exportStartedAt {
                metaPair(
                    icon: "timer",
                    label: formatTime(Date().timeIntervalSince(started)),
                    hint: "elapsed"
                )
            }
            Spacer()
        }
    }

    private func metaPair(icon: String, label: String, hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.colors.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(theme.colors.textTertiary)
            }
        }
    }

    private var etaLabel: String {
        guard displayProgress > 0.01, let started = exportStartedAt else { return "—" }
        let elapsed = Date().timeIntervalSince(started)
        let total = elapsed / max(displayProgress, 0.01)
        let remaining = max(0, total - elapsed)
        return formatTime(remaining)
    }

    // MARK: - Finished

    private func finishedView(url: URL) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.colors.success.opacity(0.4), theme.colors.success.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .stroke(theme.colors.success.opacity(0.45), lineWidth: 1)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(theme.colors.success)
            }
            .frame(width: 62, height: 62)
            .shadow(color: theme.colors.success.opacity(0.35), radius: 14)

            VStack(spacing: 4) {
                Text("Export ready")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(url.lastPathComponent)
                    .font(theme.typography.caption.monospaced())
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(humanFileSize(at: url))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.colors.textTertiary)
            }

            HStack(spacing: 10) {
                secondaryAction(icon: "doc.on.doc", title: "Copy Path") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(url.path, forType: .string)
                }
                secondaryAction(icon: "magnifyingglass", title: "Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                secondaryAction(icon: "play.fill", title: "Open") {
                    NSWorkspace.shared.open(url)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.colors.accent)
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func secondaryAction(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.colors.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.colors.danger.opacity(0.4), theme.colors.danger.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "exclamationmark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(theme.colors.danger)
            }
            .frame(width: 56, height: 56)

            VStack(spacing: 4) {
                Text("Export failed")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(message)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }

            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Text("Close")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(theme.colors.border, lineWidth: 1)
                )
                Button {
                    phase = .configuring
                    progress = 0
                    displayProgress = 0
                } label: {
                    Text("Try Again")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.colors.accent)
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(theme.typography.sectionLabel)
            .tracking(0.8)
            .foregroundStyle(theme.colors.textTertiary)
    }

    private var canExport: Bool {
        destinationFolder != nil
            && !filename.trimmingCharacters(in: .whitespaces).isEmpty
            && model.project.timeline.duration > 0.001
    }

    private var destinationDisplay: String {
        guard let folder = destinationFolder else { return "Pick a folder" }
        let path = folder.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func initializeDefaults() {
        if filename.isEmpty {
            filename = defaultFilename(for: model.project.name)
        }
        if destinationFolder == nil {
            destinationFolder = resolvedBookmarkFolder() ?? ensureDefaultFolder()
        }
    }

    private func resolvedBookmarkFolder() -> URL? {
        guard let data = destinationBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url
    }

    private func ensureDefaultFolder() -> URL? {
        if let movies = try? FileManager.default.url(
            for: .moviesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            let candidate = movies.appending(path: "EditOS", directoryHint: .isDirectory)
            if (try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)) != nil,
               FileManager.default.isWritableFile(atPath: candidate.path) {
                return candidate
            }
        }
        if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            let fallback = support.appending(path: "EditOS/Exports", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
        return nil
    }

    private func startExport() {
        guard let folder = destinationFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cleanName = sanitize(filename: filename)
        let outputURL = folder.appending(path: cleanName).appendingPathExtension(format.fileExtension)
        try? FileManager.default.removeItem(at: outputURL)

        phase = .exporting
        progress = 0
        displayProgress = 0
        exportStartedAt = Date()

        // Smooth the displayed progress so the number ramps instead of
        // sitting at 0 and snapping to 100 — AVAssetExportSession only
        // produces a handful of progress callbacks for short renders.
        let pollTask = Task { @MainActor in
            while !Task.isCancelled {
                let target = self.progress
                if abs(target - self.displayProgress) > 0.001 {
                    self.displayProgress += (target - self.displayProgress) * 0.18
                }
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30Hz
                if case .configuring = self.phase { return }
                if case .failed = self.phase { return }
                if self.displayProgress >= 0.999 && self.progress >= 0.999 { return }
            }
        }

        let engine = environment.exportEngine
        let chosenPreset = preset(forQuality: quality, format: format)
        let outputFileType = format.outputFileType
        let stripAudio = !includeAudio
        let overrideFrameRate = frameRate.value
        let captureQualityRaw = qualityRaw

        exportTask = Task { @MainActor in
            defer { pollTask.cancel() }
            do {
                let composition = try await model.buildComposition()
                let finalComposition: CompositionResult
                if overrideFrameRate != nil || stripAudio {
                    finalComposition = await tunedComposition(
                        composition,
                        targetFrameRate: overrideFrameRate,
                        stripAudio: stripAudio
                    )
                } else {
                    finalComposition = composition
                }
                let settings = ExportEngine.Settings(
                    preset: chosenPreset,
                    fileType: outputFileType,
                    outputURL: outputURL
                )
                try await engine.export(finalComposition, settings: settings) { value in
                    Task { @MainActor in
                        self.progress = Double(value)
                    }
                }
                self.displayProgress = 1
                model.lastExportedURL = outputURL
                phase = .finished(outputURL)
                if openOnFinish {
                    NSWorkspace.shared.open(outputURL)
                }
                _ = captureQualityRaw
            } catch is CancellationError {
                phase = .configuring
            } catch ExportEngine.ExportError.cancelled {
                phase = .configuring
            } catch {
                phase = .failed(humanMessage(for: error))
            }
        }
    }

    /// Build a tuned variant of the composition result — override the
    /// videoComposition's frame rate and / or drop the audio mix when the
    /// user has flipped those toggles.
    private func tunedComposition(
        _ result: CompositionResult,
        targetFrameRate: Int?,
        stripAudio: Bool
    ) async -> CompositionResult {
        var newVideoComp = result.videoComposition
        if let target = targetFrameRate,
           let original = result.videoComposition,
           let mutable = original.mutableCopy() as? AVMutableVideoComposition {
            mutable.frameDuration = CMTime(value: 1, timescale: CMTimeScale(target))
            newVideoComp = mutable.copy() as? AVVideoComposition
        }
        return CompositionResult(
            composition: result.composition,
            videoComposition: newVideoComp,
            audioMix: stripAudio ? nil : result.audioMix
        )
    }

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = destinationFolder ?? ensureDefaultFolder()
        if panel.runModal() == .OK, let url = panel.urls.first {
            destinationFolder = url
            // Persist a security-scoped bookmark so we can write here again
            // next session without re-prompting.
            destinationBookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    private func defaultFilename(for projectName: String) -> String {
        let stripped = projectName.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: .now)
        let base = stripped.isEmpty ? "EditOS" : stripped
        return "\(base) \(stamp)"
    }

    private func sanitize(filename: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_."))
        let scalars = filename.unicodeScalars.filter { allowed.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "EditOS" : cleaned
    }

    private func humanMessage(for error: Error) -> String {
        switch error {
        case ExportEngine.ExportError.noExportSession:
            return "Couldn't start an export session for that resolution. Try a different preset."
        case ExportEngine.ExportError.failed(let underlying):
            return underlying?.localizedDescription ?? "Export failed."
        default:
            return error.localizedDescription
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remaining = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remaining)
    }

    /// Rough estimate based on a target bitrate per resolution × duration.
    /// Errs slightly high so users aren't surprised by a bigger file.
    private var estimatedSize: String {
        let bitsPerSecond: Double = {
            switch quality {
            case .sd480:  return 2_000_000
            case .hd720:  return 4_500_000
            case .hd1080: return 8_000_000
            case .uhd4k:  return 30_000_000
            }
        }()
        let codecMultiplier: Double = format == .mp4H265 ? 0.55 : 1.0
        let totalBits = bitsPerSecond * codecMultiplier * model.project.timeline.duration
        let totalBytes = totalBits / 8
        return humanBytes(totalBytes)
    }

    private func humanFileSize(at url: URL) -> String {
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
            return humanBytes(Double(size))
        }
        return ""
    }

    private func humanBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(max(0, bytes)))
    }

    private func preset(forQuality quality: Quality, format: Format) -> String {
        switch format {
        case .mp4H264, .mov:
            return quality.h264Preset
        case .mp4H265:
            return quality.h265Preset
        }
    }
}

// MARK: - Models

extension ExportSheet {
    enum Quality: String, CaseIterable, Identifiable {
        case sd480 = "480"
        case hd720 = "720"
        case hd1080 = "1080"
        case uhd4k = "2160"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .sd480:  return "480p"
            case .hd720:  return "720p"
            case .hd1080: return "1080p"
            case .uhd4k:  return "4K"
            }
        }
        var dimensions: String {
            switch self {
            case .sd480:  return "854 × 480"
            case .hd720:  return "1280 × 720"
            case .hd1080: return "1920 × 1080"
            case .uhd4k:  return "3840 × 2160"
            }
        }
        var blurb: String {
            switch self {
            case .sd480:  return "Smallest"
            case .hd720:  return "Lean"
            case .hd1080: return "Recommended"
            case .uhd4k:  return "Highest"
            }
        }
        var h264Preset: String {
            switch self {
            case .sd480:  return AVAssetExportPreset640x480
            case .hd720:  return AVAssetExportPreset1280x720
            case .hd1080: return AVAssetExportPreset1920x1080
            case .uhd4k:  return AVAssetExportPreset3840x2160
            }
        }
        var h265Preset: String {
            switch self {
            case .sd480:  return AVAssetExportPresetHEVC1920x1080  // 480p falls back to 1080p HEVC if unavailable
            case .hd720:  return AVAssetExportPresetHEVC1920x1080
            case .hd1080: return AVAssetExportPresetHEVC1920x1080
            case .uhd4k:  return AVAssetExportPresetHEVC3840x2160
            }
        }
    }

    enum Format: String, CaseIterable, Identifiable {
        case mp4H264 = "mp4_h264"
        case mp4H265 = "mp4_h265"
        case mov     = "mov"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .mp4H264: return "MP4 · H.264"
            case .mp4H265: return "MP4 · H.265"
            case .mov:     return "MOV"
            }
        }
        var codecHint: String {
            switch self {
            case .mp4H264: return "Universal"
            case .mp4H265: return "Smaller, modern devices"
            case .mov:     return "ProRes-friendly"
            }
        }
        var fileExtension: String {
            switch self {
            case .mp4H264, .mp4H265: return "mp4"
            case .mov:               return "mov"
            }
        }
        var outputFileType: AVFileType {
            switch self {
            case .mp4H264, .mp4H265: return .mp4
            case .mov:               return .mov
            }
        }
    }

    enum FrameRate: Int, CaseIterable, Identifiable {
        case matchSource = 0
        case fps24 = 24
        case fps30 = 30
        case fps60 = 60

        var id: Int { rawValue }
        var displayName: String {
            switch self {
            case .matchSource: return "Match source"
            case .fps24: return "24 fps"
            case .fps30: return "30 fps"
            case .fps60: return "60 fps"
            }
        }
        var value: Int? {
            self == .matchSource ? nil : rawValue
        }
    }
}

// MARK: - Sub-views

private struct SummaryStat: View {
    @Environment(\.theme) private var theme
    let value: String
    let label: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(theme.colors.textPrimary)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

private struct QualityChip: View {
    @Environment(\.theme) private var theme
    let value: ExportSheet.Quality
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(value.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isSelected ? .white : theme.colors.textPrimary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                    }
                }
                Text(value.dimensions)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : theme.colors.textSecondary)
                Text(value.blurb)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : theme.colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        theme.colors.accent,
                                        theme.colors.accent.opacity(0.85)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(theme.colors.surface)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isSelected ? Color.white.opacity(0.18) : theme.colors.border,
                        lineWidth: 1
                    )
            )
            .shadow(color: isSelected ? theme.colors.accent.opacity(0.35) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

private struct FormatChip: View {
    @Environment(\.theme) private var theme
    let value: ExportSheet.Format
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(value.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : theme.colors.textPrimary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                Text(value.codecHint)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : theme.colors.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [theme.colors.accent, theme.colors.accent.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(theme.colors.surface)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.white.opacity(0.18) : theme.colors.border,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
