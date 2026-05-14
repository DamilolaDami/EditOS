import AVFoundation
import CoreGraphics
import Foundation

/// Generates poster frames for clips and filmstrip thumbnails for the timeline.
///
/// Returns `CGImage` rather than `NSImage` so results can cross actor
/// boundaries cleanly under Swift 6 strict concurrency.
actor ThumbnailGenerator {
    private var cache: [CacheKey: CGImage] = [:]

    struct CacheKey: Hashable {
        let url: URL
        let timeMillis: Int
        let widthPx: Int
    }

    func poster(
        for url: URL,
        at time: TimeInterval = 0,
        size: CGSize = CGSize(width: 320, height: 180)
    ) async -> CGImage? {
        let key = CacheKey(url: url, timeMillis: Int(time * 1000), widthPx: Int(size.width))
        if let cached = cache[key] { return cached }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size

        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: cmTime)
            cache[key] = cgImage
            return cgImage
        } catch {
            return nil
        }
    }

    func filmstrip(
        for url: URL,
        range: TimeRange,
        frameCount: Int,
        size: CGSize = CGSize(width: 120, height: 80)
    ) async -> [CGImage] {
        guard frameCount > 0 else { return [] }
        let step = range.duration / Double(frameCount)
        var images: [CGImage] = []
        images.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            // Sample the centre of each segment so we get representative frames.
            let time = range.start + (Double(index) + 0.5) * step
            if let image = await poster(for: url, at: time, size: size) {
                images.append(image)
            }
        }
        return images
    }
}
