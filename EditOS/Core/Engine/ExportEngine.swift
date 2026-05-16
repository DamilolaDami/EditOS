import AVFoundation
import Foundation
import OSLog

/// Renders a `Project` to a video file via `AVAssetExportSession`.
actor ExportEngine {
    enum ExportError: Error {
        case noExportSession
        case cancelled
        case failed(Error?)
    }

    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "ExportEngine")

    struct Settings: Sendable {
        var preset: String
        var fileType: AVFileType
        var outputURL: URL
        /// Optional chapter markers to bake into the export. Sorted by
        /// time at write-time. We embed them as file-level title metadata
        /// items (AVAssetExportSession can't author full chapter tracks
        /// without AVAssetWriter, but the metadata + sidecar combo covers
        /// the YouTube / podcast use case).
        var chapters: [ChapterMarker] = []

        static func h264_1080p(to outputURL: URL) -> Settings {
            Settings(preset: AVAssetExportPreset1920x1080, fileType: .mp4, outputURL: outputURL)
        }

        static func h264_4k(to outputURL: URL) -> Settings {
            Settings(preset: AVAssetExportPreset3840x2160, fileType: .mp4, outputURL: outputURL)
        }
    }

    /// A timestamped chapter title attached to the exported video.
    struct ChapterMarker: Sendable, Hashable {
        let time: TimeInterval
        let title: String
    }

    func export(
        _ result: CompositionResult,
        settings: Settings,
        onProgress: @escaping @Sendable (Float) -> Void = { _ in }
    ) async throws {
        // AVAssetExportSession returns NSURLErrorCannotCreateFile (-3000)
        // with an inner OSStatus when its parent directory is missing or an
        // older file at the same path can't be overwritten. Do both
        // defensively here so the engine never fails on directory state.
        let parent = settings.outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            Self.log.error("createDirectory failed for \(parent.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ExportError.failed(error)
        }
        if FileManager.default.fileExists(atPath: settings.outputURL.path) {
            try? FileManager.default.removeItem(at: settings.outputURL)
        }
        // Sanity check: verify the parent is writable before AVFoundation
        // touches it, because its error message is unhelpfully terse.
        if !FileManager.default.isWritableFile(atPath: parent.path) {
            Self.log.error("Parent directory not writable: \(parent.path, privacy: .public)")
            throw ExportError.failed(NSError(
                domain: "com.damioffice.EditOS.ExportEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Destination folder isn't writable: \(parent.path)"]
            ))
        }

        guard let session = await AVAssetExportSession(asset: result.composition, presetName: settings.preset) else {
            Self.log.error("Couldn't construct AVAssetExportSession for preset \(settings.preset, privacy: .public)")
            throw ExportError.noExportSession
        }
        session.outputURL = settings.outputURL
        session.outputFileType = settings.fileType
        session.shouldOptimizeForNetworkUse = true
        session.audioMix = await result.audioMix
        session.videoComposition = await result.videoComposition

        // Attach chapter markers as file-level metadata items. Authoring
        // a proper QuickTime chapter track requires AVAssetWriter (TODO);
        // these metadata items survive into the .mp4 / .mov so tools that
        // read mdta/keys atoms can still find the chapter list. The
        // sidecar .chapters.txt written below is the user-facing fallback.
        if !settings.chapters.isEmpty {
            session.metadata = Self.chapterMetadataItems(from: settings.chapters)
        }

        // Poll progress while the session runs so callers can drive a UI bar.
        let progressTask = Task.detached { [weak session] in
            while !Task.isCancelled {
                guard let session else { return }
                let status = session.status
                guard status == .waiting || status == .exporting else { return }
                onProgress(session.progress)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        await session.export()
        progressTask.cancel()

        switch session.status {
        case .completed:
            // Sidecar chapters file in YouTube / podcast format:
            //   00:00 Intro
            //   01:42 Punchline
            // Sits next to the video so creators can paste it straight
            // into YouTube's description box.
            if !settings.chapters.isEmpty {
                Self.writeChaptersSidecar(
                    chapters: settings.chapters,
                    outputURL: settings.outputURL
                )
            }
            onProgress(1.0)
            return
        case .cancelled:
            Self.log.error("Export cancelled")
            print("[ExportEngine] cancelled")
            throw ExportError.cancelled
        case .failed:
            logFailure(session: session, settings: settings, label: "failed")
            throw ExportError.failed(session.error)
        default:
            logFailure(session: session, settings: settings, label: "unexpected status \(session.status.rawValue)")
            throw ExportError.failed(session.error)
        }
    }

    /// Surfaces the underlying NSError so failures show in Xcode's console
    /// and `os_log` instead of disappearing behind `ExportError.failed`.
    private func logFailure(session: AVAssetExportSession, settings: Settings, label: String) {
        let underlying = session.error as NSError?
        let description = underlying?.localizedDescription ?? "<no description>"
        let domain = underlying?.domain ?? "<no domain>"
        let code = underlying?.code ?? -1
        let userInfo = underlying?.userInfo ?? [:]

        Self.log.error(
            "Export \(label, privacy: .public) — preset=\(settings.preset, privacy: .public), output=\(settings.outputURL.path, privacy: .public), domain=\(domain, privacy: .public), code=\(code, privacy: .public), msg=\(description, privacy: .public)"
        )
        // Also drop a stdout line so it's easy to spot in Xcode's debug
        // console when AVFoundation's error path is opaque.
        print("""
        [ExportEngine] \(label)
          preset:   \(settings.preset)
          output:   \(settings.outputURL.path)
          domain:   \(domain) (\(code))
          message:  \(description)
          userInfo: \(userInfo)
        """)
    }

    /// Build the file-level metadata items that carry chapter info. We
    /// emit one title item per chapter plus a combined description so
    /// tools that don't grok per-chapter items still see the list.
    private static func chapterMetadataItems(from chapters: [ChapterMarker]) -> [AVMetadataItem] {
        let sorted = chapters.sorted { $0.time < $1.time }
        var items: [AVMetadataItem] = []

        // Per-chapter title items (informational — proper chapter tracks
        // need AVAssetWriter, see the issue body for the follow-up).
        for chapter in sorted {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = "\(formatTimestamp(chapter.time)) \(chapter.title)" as NSString
            item.locale = .current
            items.append(item)
        }

        // Single aggregated description so the chapter list shows up in
        // file-info inspectors that read description / comment.
        let summary = AVMutableMetadataItem()
        summary.identifier = .commonIdentifierDescription
        summary.value = sorted
            .map { "\(formatTimestamp($0.time)) \($0.title)" }
            .joined(separator: "\n") as NSString
        items.append(summary)

        return items
    }

    /// YouTube / podcast-style chapters file: one chapter per line,
    /// `MM:SS Title` (or `H:MM:SS` past the hour). Sits beside the
    /// rendered video so creators can paste it into upload descriptions.
    private static func writeChaptersSidecar(chapters: [ChapterMarker], outputURL: URL) {
        let sidecarURL = outputURL.deletingPathExtension().appendingPathExtension("chapters.txt")
        let lines = chapters
            .sorted { $0.time < $1.time }
            .map { "\(formatTimestamp($0.time)) \($0.title)" }
        let body = lines.joined(separator: "\n") + "\n"
        do {
            try body.write(to: sidecarURL, atomically: true, encoding: .utf8)
        } catch {
            log.error("Failed to write chapters sidecar: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

