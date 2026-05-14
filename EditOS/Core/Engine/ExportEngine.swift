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

    func export(composition: AVComposition, settings: Settings) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: settings.preset) else {
            throw ExportError.noExportSession
        }
        session.outputURL = settings.outputURL
        session.outputFileType = settings.fileType
        session.shouldOptimizeForNetworkUse = true

        await session.export()

        switch session.status {
        case .completed:
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
