import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Imports source media into a project. Reads media metadata via AVFoundation
/// and persists a security-scoped bookmark so the URL is reachable across
/// app launches under the sandbox.
struct MediaImporter: Sendable {
    enum ImportError: Error {
        case unsupportedType(URL)
        case bookmarkFailed(URL)
    }

    static let supportedTypes: [UTType] = [.movie, .video, .audio, .image, .quickTimeMovie, .mpeg4Movie]

    func makeAsset(from url: URL) async throws -> MediaAsset {
        let kind = try detectKind(for: url)
        let bookmark = try makeBookmark(for: url)

        let avAsset = AVURLAsset(url: url)
        let duration: TimeInterval
        var nativeSize: CGSize?
        var frameRate: Double?

        switch kind {
        case .video:
            duration = try await avAsset.load(.duration).seconds
            if let track = try await avAsset.loadTracks(withMediaType: .video).first {
                let (naturalSize, transform, nominalFrameRate) = try await track.load(
                    .naturalSize, .preferredTransform, .nominalFrameRate
                )
                let transformed = naturalSize.applying(transform)
                nativeSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                frameRate = Double(nominalFrameRate)
            }
        case .audio:
            duration = try await avAsset.load(.duration).seconds
        case .image:
            duration = 5.0
            if let image = NSImage(contentsOf: url) {
                nativeSize = image.size
            }
        }

        return MediaAsset(
            displayName: url.deletingPathExtension().lastPathComponent,
            kind: kind,
            duration: duration,
            nativeSize: nativeSize,
            frameRate: frameRate,
            bookmark: bookmark
        )
    }

    private func detectKind(for url: URL) throws -> MediaAsset.Kind {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { throw ImportError.unsupportedType(url) }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        throw ImportError.unsupportedType(url)
    }

    private func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw ImportError.bookmarkFailed(url)
        }
    }
}

