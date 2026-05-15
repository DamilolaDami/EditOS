import AVFoundation
import Foundation

/// Renders a `Project` to a video file via `AVAssetExportSession`.
actor ExportEngine {
    enum ExportError: Error {
        case noExportSession
        case cancelled
        case failed(Error?)
    }

    struct Settings: Sendable {
        var preset: String
        var fileType: AVFileType
        var outputURL: URL

        static func h264_1080p(to outputURL: URL) -> Settings {
            Settings(preset: AVAssetExportPreset1920x1080, fileType: .mp4, outputURL: outputURL)
        }

        static func h264_4k(to outputURL: URL) -> Settings {
            Settings(preset: AVAssetExportPreset3840x2160, fileType: .mp4, outputURL: outputURL)
        }
    }

    func export(
        _ result: CompositionResult,
        settings: Settings,
        onProgress: @escaping @Sendable (Float) -> Void = { _ in }
    ) async throws {
        guard let session = AVAssetExportSession(asset: result.composition, presetName: settings.preset) else {
            throw ExportError.noExportSession
        }
        session.outputURL = settings.outputURL
        session.outputFileType = settings.fileType
        session.shouldOptimizeForNetworkUse = true
        session.audioMix = result.audioMix

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
            onProgress(1.0)
            return
        case .cancelled:
            throw ExportError.cancelled
        case .failed:
            throw ExportError.failed(session.error)
        default:
            throw ExportError.failed(session.error)
        }
    }
}
