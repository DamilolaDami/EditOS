import AVFoundation
import Foundation

/// Extracts a downsampled peak-amplitude waveform for an audio file, so the
/// timeline can draw a level-bar visualiser ("pitch visualiser") alongside
/// audio clips. Reads PCM samples through `AVAssetReader`, then collapses them
/// into a fixed number of normalised buckets.
actor WaveformGenerator {
    private var cache: [CacheKey: [Float]] = [:]

    struct CacheKey: Hashable {
        let url: URL
        let bucketCount: Int
    }

    /// Returns `bucketCount` peak-amplitude buckets in `[0, 1]`. Empty array if
    /// the file has no readable audio.
    func samples(for url: URL, bucketCount: Int) async -> [Float] {
        let key = CacheKey(url: url, bucketCount: bucketCount)
        if let cached = cache[key] { return cached }

        let result = await Self.extractSamples(from: url, bucketCount: bucketCount)
        cache[key] = result
        return result
    }

    private static func extractSamples(from url: URL, bucketCount: Int) async -> [Float] {
        guard bucketCount > 0 else { return [] }

        let asset = AVURLAsset(url: url)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return []
        }

        guard let reader = try? AVAssetReader(asset: asset) else { return [] }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)

        guard reader.startReading() else { return [] }

        // Estimate total samples so we know our bucket stride. If we can't,
        // fall back to a running stream that buckets as it goes.
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let sampleRate: Double = 44_100  // approximate; only used for stride
        let estimatedTotalSamples = max(Int(duration * sampleRate), bucketCount)
        let samplesPerBucket = max(1, estimatedTotalSamples / bucketCount)

        var buckets = [Float](repeating: 0, count: bucketCount)
        var currentBucket = 0
        var samplesInBucket = 0
        var currentMax: Int16 = 0

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                break
            }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.size)
            _ = data.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: ptr.baseAddress!
                )
            }
            CMSampleBufferInvalidate(sampleBuffer)

            for sample in data {
                let absSample = sample == Int16.min ? Int16.max : Int16(abs(Int32(sample)))
                if absSample > currentMax { currentMax = absSample }
                samplesInBucket += 1
                if samplesInBucket >= samplesPerBucket, currentBucket < bucketCount {
                    buckets[currentBucket] = Float(currentMax) / Float(Int16.max)
                    currentBucket += 1
                    samplesInBucket = 0
                    currentMax = 0
                }
            }
        }

        // Trailing partial bucket.
        if currentBucket < bucketCount, samplesInBucket > 0 {
            buckets[currentBucket] = Float(currentMax) / Float(Int16.max)
            currentBucket += 1
        }

        // Light smoothing so the visualiser doesn't look jagged at high zoom.
        return smoothed(buckets)
    }

    private static func smoothed(_ values: [Float]) -> [Float] {
        guard values.count > 2 else { return values }
        var out = values
        for i in 1..<(values.count - 1) {
            out[i] = (values[i - 1] + values[i] + values[i + 1]) / 3
        }
        // Apply a mild floor so very quiet sections still show as a thin bar.
        return out.map { max($0, 0.04) }
    }
}
