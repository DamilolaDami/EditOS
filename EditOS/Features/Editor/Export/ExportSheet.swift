import AVFoundation
import AppKit
import SwiftUI

/// Modal sheet presented from the editor's top bar Export button. Lets the
/// user pick a resolution, filename, and destination folder, then drives
/// `ExportEngine` with a live progress bar.
struct ExportSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: EditorViewModel

    @State private var preset: Preset = .hd1080
    @State private var filename: String = ""
    @State private var destinationFolder: URL?
    @State private var phase: Phase = .configuring
    @State private var progress: Double = 0
    @State private var exportTask: Task<Void, Never>?

    enum Phase {
        case configuring
        case exporting
        case finished(URL)
        case failed(String)
    }

    enum Preset: String, CaseIterable, Identifiable {
        case hd720, hd1080, uhd4k
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .hd720: return "720p"
            case .hd1080: return "1080p"
            case .uhd4k: return "4K"
            }
        }

        var dimensions: String {
            switch self {
            case .hd720: return "1280 × 720"
            case .hd1080: return "1920 × 1080"
            case .uhd4k: return "3840 × 2160"
            }
        }

        var blurb: String {
            switch self {
            case .hd720: return "Smaller file"
            case .hd1080: return "Recommended"
            case .uhd4k: return "Highest quality"
            }
        }

        var avPreset: String {
            switch self {
            case .hd720: return AVAssetExportPreset1280x720
            case .hd1080: return AVAssetExportPreset1920x1080
            case .uhd4k: return AVAssetExportPreset3840x2160
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
        }
        .frame(width: 540)
        .background(
            LinearGradient(
                colors: [theme.colors.surface, theme.colors.background],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear { initializeDefaults() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.colors.accent.opacity(0.16))
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("Export")
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
                    .background(theme.colors.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: 1)
        }
    }

    private var headerSubtitle: String {
        switch phase {
        case .configuring: return "Choose a quality and where to save it."
        case .exporting:   return "Rendering — keep the app open."
        case .finished:    return "Export complete."
        case .failed:      return "Something went wrong."
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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Quality")
                HStack(spacing: 10) {
                    ForEach(Preset.allCases) { value in
                        PresetCard(value: value, isSelected: value == preset) {
                            preset = value
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("File")

                HStack(spacing: 0) {
                    TextField("Untitled", text: $filename)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    Text(".mp4")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(theme.colors.textSecondary)
                        .padding(.trailing, 12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.colors.surfaceElevated)
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
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.colors.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.colors.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 80)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.colors.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(theme.colors.border, lineWidth: 1)
                )
                .foregroundStyle(theme.colors.textPrimary)
                .keyboardShortcut(.cancelAction)

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
                    .frame(minWidth: 100)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.colors.accent)
                )
                .shadow(color: theme.colors.accent.opacity(0.35), radius: 6, y: 2)
                .opacity(canExport ? 1 : 0.45)
                .disabled(!canExport)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Exporting

    private var exportingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .lastTextBaseline) {
                    Text("\(Int(progress * 100))")
                        .font(.system(size: 36, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("%")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.colors.textSecondary)
                    Spacer()
                    Text("\(preset.displayName) · \(preset.dimensions)")
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
                progressBar
            }

            HStack {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.colors.textTertiary)
                Text("Render runs on the GPU. Closing the window cancels it.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                Spacer()
                Button {
                    exportTask?.cancel()
                    phase = .configuring
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.colors.danger)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.colors.surfaceElevated)
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.colors.accent,
                                theme.colors.accent.opacity(0.7)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, proxy.size.width * progress))
                    .animation(.easeOut(duration: 0.15), value: progress)
            }
        }
        .frame(height: 8)
    }

    // MARK: - Finished

    private func finishedView(url: URL) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.colors.success.opacity(0.15))
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(theme.colors.success)
            }
            .frame(width: 56, height: 56)

            VStack(spacing: 4) {
                Text("Ready to share")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(url.lastPathComponent)
                    .font(theme.typography.caption.monospaced())
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Text("Reveal in Finder")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.colors.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(theme.colors.border, lineWidth: 1)
                )
                .foregroundStyle(theme.colors.textPrimary)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
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
        .padding(.vertical, 12)
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.colors.danger.opacity(0.15))
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
            }

            Button {
                phase = .configuring
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
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
    }

    private var destinationDisplay: String {
        guard let folder = destinationFolder else { return "Pick a folder" }
        let path = folder.path
        // Replace ~/ for compactness.
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
            destinationFolder = ensureDefaultFolder()
        }
    }

    /// Lazily creates ~/Movies/EditOS so every export lands in the same place
    /// out of the box, à la CapCut.
    private func ensureDefaultFolder() -> URL? {
        guard let movies = try? FileManager.default.url(
            for: .moviesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let folder = movies.appending(path: "EditOS", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func startExport() {
        guard let folder = destinationFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cleanName = sanitize(filename: filename)
        let outputURL = folder.appending(path: cleanName).appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outputURL)

        phase = .exporting
        progress = 0

        let engine = environment.exportEngine
        let chosenPreset = preset.avPreset

        exportTask = Task { @MainActor in
            do {
                let composition = try await model.buildComposition()
                let settings = ExportEngine.Settings(
                    preset: chosenPreset,
                    fileType: .mp4,
                    outputURL: outputURL
                )
                try await engine.export(composition, settings: settings) { value in
                    Task { @MainActor in
                        self.progress = Double(value)
                    }
                }
                phase = .finished(outputURL)
            } catch is CancellationError {
                phase = .configuring
            } catch ExportEngine.ExportError.cancelled {
                phase = .configuring
            } catch {
                phase = .failed(humanMessage(for: error))
            }
        }
    }

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = destinationFolder ?? ensureDefaultFolder()
        if panel.runModal() == .OK {
            destinationFolder = panel.urls.first
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
}

// MARK: - Preset card

private struct PresetCard: View {
    @Environment(\.theme) private var theme
    let value: ExportSheet.Preset
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(value.displayName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isSelected ? .white : theme.colors.textPrimary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                    }
                }
                Text(value.dimensions)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : theme.colors.textSecondary)
                Spacer(minLength: 0)
                Text(value.blurb)
                    .font(theme.typography.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : theme.colors.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10)
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
                            : AnyShapeStyle(theme.colors.surfaceElevated)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.white.opacity(0.18) : theme.colors.border,
                        lineWidth: 1
                    )
            )
            .shadow(color: isSelected ? theme.colors.accent.opacity(0.4) : .clear, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }
}
