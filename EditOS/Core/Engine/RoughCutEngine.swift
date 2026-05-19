import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import OSLog
import Vision

/// On-device "AI rough-cut" pipeline. Walks a clip's audio + video,
/// scores half-second windows by three signals, then picks the
/// strongest non-overlapping segments totalling `targetDuration`.
///
/// V1 signals:
///   - **Audio energy** — per-window RMS of the linear-PCM samples.
///     Speaking / action / impact → high score.
///   - **Face presence** — `VNDetectFaceRectanglesRequest` at 1 fps,
///     weighted by combined bounding-box area. Visible talking heads
///     score higher than empty rooms.
///   - **Motion** — frame-to-frame absolute pixel delta at 2 fps,
///     subsampled to a small thumbnail. High motion (whip pans / hand
///     wobble) is *penalised* — viewers prefer settled framing.
///
/// Each stage produces a `[0…1]` series indexed by 0.5s windows.
/// The combined score is a weighted sum; the picker greedily takes
/// the top non-overlapping runs above a dynamic threshold until the
/// total reaches `targetDuration`.
///
/// Reports progress + completion via `AsyncThrowingStream` so callers
/// can `for try await` the pipeline without needing to thread a
/// `@Sendable` closure through actor boundaries.
struct RoughCutEngine: Sendable {
    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "RoughCutEngine")

    /// One half-second slice of the source's analysis grid.
    static let windowDuration: TimeInterval = 0.5
    /// Don't propose cuts shorter than this — sub-second clips feel
    /// like noise more than highlights.
    static let minSegmentDuration: TimeInterval = 1.5
    /// Cap any single segment so one long high-score block doesn't
    /// swallow the whole `targetDuration` budget.
    static let maxSegmentDuration: TimeInterval = 12.0

    // Weighted blend of the three signals.
    private static let audioWeight = 0.5
    private static let faceWeight  = 0.3
    private static let motionWeight = 0.2

    /// User-visible analysis phases. The sheet binds its progress bar
    /// + status label to whichever is currently running.
    enum Stage: String, Sendable {
        case readingAudio = "Reading audio energy"
        case detectingFaces = "Detecting faces"
        case measuringMotion = "Measuring motion"
        case rankingSegments = "Picking highlights"
    }

    struct ProgressUpdate: Sendable {
        let stage: Stage
        /// `0…1` within the current stage.
        let fraction: Double
    }

    /// Stream-of-events the public API yields while it works. The
    /// final event before `finish()` is always `.complete`.
    enum Event: Sendable {
        case progress(ProgressUpdate)
        case complete(AnalysisResult)
    }

    /// Score for one half-second window of the source.
    struct WindowScore: Sendable {
        let startTime: TimeInterval
        let audioEnergy: Double
        let facePresence: Double
        let motionScore: Double  // 1 = settled, 0 = chaotic

        var combinedScore: Double {
            audioWeight * audioEnergy
                + faceWeight * facePresence
                + motionWeight * motionScore
        }
    }

    /// A proposed highlight segment — a run of high-score windows
    /// merged into a single playable range on the source clip.
    struct Segment: Sendable, Identifiable, Hashable {
        let id: UUID
        let startTime: TimeInterval
        let duration: TimeInterval
        let averageScore: Double

        init(id: UUID = UUID(), startTime: TimeInterval, duration: TimeInterval, averageScore: Double) {
            self.id = id
            self.startTime = startTime
            self.duration = duration
            self.averageScore = averageScore
        }

        var endTime: TimeInterval { startTime + duration }
    }

    /// Full analysis result. Exposes the per-window scores so the UI
    /// can render a heat-strip alongside the proposed segments if the
    /// user wants to see *why* the picker chose what it chose.
    struct AnalysisResult: Sendable {
        let sourceURL: URL
        let sourceDuration: TimeInterval
        let windows: [WindowScore]
        let segments: [Segment]
    }

    // MARK: - Public entrypoint

    /// Stream-based public API. Yields `.progress(...)` while the
    /// pipeline runs and `.complete(...)` once segments are picked.
    /// Throws on a stage failure (asset can't be read, etc.).
    func analyze(
        url: URL,
        targetDuration: TimeInterval
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await Self.runPipeline(
                        url: url,
                        targetDuration: targetDuration,
                        emit: { update in
                            continuation.yield(.progress(update))
                        }
                    )
                    continuation.yield(.complete(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Internal pipeline. `emit` is called from the same Task that
    /// runs the analysis, so no actor crossing is needed.
    private static func runPipeline(
        url: URL,
        targetDuration: TimeInterval,
        emit: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> AnalysisResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > Self.windowDuration else {
            // Clip too short to bother with — return the whole thing
            // as a single segment so the UI still has something to
            // show.
            return AnalysisResult(
                sourceURL: url,
                sourceDuration: duration,
                windows: [],
                segments: [Segment(startTime: 0, duration: max(0.01, duration), averageScore: 1.0)]
            )
        }

        let windowCount = Int((duration / Self.windowDuration).rounded(.down))
        Self.log.info("Analysing \(url.lastPathComponent, privacy: .public): duration=\(duration)s windows=\(windowCount)")

        emit(.init(stage: .readingAudio, fraction: 0))
        let audioScores = await Self.audioEnergy(
            asset: asset,
            duration: duration,
            windowCount: windowCount,
            progress: { emit(.init(stage: .readingAudio, fraction: $0)) }
        )

        emit(.init(stage: .detectingFaces, fraction: 0))
        let faceScores = await Self.facePresence(
            asset: asset,
            duration: duration,
            windowCount: windowCount,
            progress: { emit(.init(stage: .detectingFaces, fraction: $0)) }
        )

        emit(.init(stage: .measuringMotion, fraction: 0))
        let motionScores = await Self.motionStability(
            asset: asset,
            duration: duration,
            windowCount: windowCount,
            progress: { emit(.init(stage: .measuringMotion, fraction: $0)) }
        )

        emit(.init(stage: .rankingSegments, fraction: 0))
        let windows = (0..<windowCount).map { i in
            WindowScore(
                startTime: TimeInterval(i) * Self.windowDuration,
                audioEnergy: audioScores[safe: i] ?? 0,
                facePresence: faceScores[safe: i] ?? 0,
                motionScore: motionScores[safe: i] ?? 1
            )
        }
        let segments = Self.pickSegments(from: windows, targetDuration: targetDuration)
        emit(.init(stage: .rankingSegments, fraction: 1))

        return AnalysisResult(
            sourceURL: url,
            sourceDuration: duration,
            windows: windows,
            segments: segments
        )
    }

    // MARK: - Audio energy

    /// RMS per `windowDuration`-second window, normalised so the
    /// loudest window in the clip scores 1.0.
    private static func audioEnergy(
        asset: AVURLAsset,
        duration: TimeInterval,
        windowCount: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> [Double] {
        var energies = [Double](repeating: 0, count: windowCount)

        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            // No audio → return zeros. Picker leans on face + motion.
            RoughCutEngine.log.info("No audio track on source")
            return energies
        }

        guard let reader = try? AVAssetReader(asset: asset) else { return energies }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return energies }
        reader.add(output)
        guard reader.startReading() else { return energies }

        var samplesPerWindow = 0
        var samplesAccumulated = 0
        var sumOfSquares: Double = 0
        var windowIndex = 0
        var sampleRate: Double = 44_100
        if let desc = audioTrack.formatDescriptions.first {
            // swiftlint:disable:next force_cast
            let formatDesc = desc as! CMAudioFormatDescription
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                sampleRate = basic.pointee.mSampleRate
            }
        }
        samplesPerWindow = max(1, Int(sampleRate * windowDuration))

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                break
            }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.size)
            _ = data.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
            }
            CMSampleBufferInvalidate(sampleBuffer)
            for sample in data {
                let value = Double(sample) / Double(Int16.max)
                sumOfSquares += value * value
                samplesAccumulated += 1
                if samplesAccumulated >= samplesPerWindow {
                    if windowIndex < windowCount {
                        energies[windowIndex] = sqrt(sumOfSquares / Double(samplesAccumulated))
                    }
                    windowIndex += 1
                    samplesAccumulated = 0
                    sumOfSquares = 0
                    if windowIndex % 32 == 0 {
                        progress(min(1, Double(windowIndex) / Double(windowCount)))
                    }
                }
            }
        }
        if samplesAccumulated > 0, windowIndex < windowCount {
            energies[windowIndex] = sqrt(sumOfSquares / Double(samplesAccumulated))
        }

        progress(1)
        return normalised(energies)
    }

    // MARK: - Face presence

    /// Per-window face score, computed by averaging per-second face
    /// metrics across each pair of half-second windows that share the
    /// surrounding seconds.
    private static func facePresence(
        asset: AVURLAsset,
        duration: TimeInterval,
        windowCount: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> [Double] {
        var scores = [Double](repeating: 0, count: windowCount)
        let sampleStep: TimeInterval = 1.0  // 1 fps — Vision is the slow stage
        let sampleCount = max(1, Int(duration / sampleStep))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Downscale — Vision's face detector is happy with 480p input
        // and runs much faster than at native resolution.
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        let request = VNDetectFaceRectanglesRequest()

        var perSecondScores = [Double](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let time = CMTime(seconds: Double(i) * sampleStep + sampleStep / 2, preferredTimescale: 600)
            do {
                let (cg, _) = try await generator.image(at: time)
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                try handler.perform([request])
                let frameArea: CGFloat = 1.0  // bounding boxes are normalised 0…1
                let totalFaceArea = (request.results ?? []).reduce(0.0) { acc, obs in
                    acc + obs.boundingBox.width * obs.boundingBox.height
                }
                perSecondScores[i] = Double(min(1.0, totalFaceArea / frameArea * 3.0))
                // ×3 because a head fills maybe a third of frame in
                // a typical talking-head shot; we want that to read
                // as a near-perfect 1.0.
            } catch {
                perSecondScores[i] = 0
            }
            if i % 4 == 0 || i == sampleCount - 1 {
                progress(Double(i + 1) / Double(sampleCount))
            }
        }

        // Map per-second → per-half-second by sampling.
        for i in 0..<windowCount {
            let t = Double(i) * windowDuration
            let secIdx = min(perSecondScores.count - 1, Int(t))
            scores[i] = perSecondScores[secIdx]
        }
        return scores
    }

    // MARK: - Motion stability

    /// Per-window 1 - normalised(motion). High frame-diff (whip pans,
    /// shaky hand-held) → low score; settled framing → high score.
    private static func motionStability(
        asset: AVURLAsset,
        duration: TimeInterval,
        windowCount: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> [Double] {
        var rawDiffs = [Double](repeating: 0, count: windowCount)
        let sampleStep = windowDuration  // 2 fps
        let sampleCount = max(2, windowCount)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Tiny thumbnails — pixel-diff is dominated by frame size,
        // so 64×36 keeps the pipeline fast without hurting the
        // signal (we only care about gross motion).
        generator.maximumSize = CGSize(width: 64, height: 36)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        var previous: [UInt8]?
        for i in 0..<sampleCount {
            let time = CMTime(seconds: Double(i) * sampleStep + sampleStep / 2, preferredTimescale: 600)
            guard let bytes = try? await Self.grayPixelBytes(at: time, generator: generator) else {
                if i % 8 == 0 { progress(Double(i + 1) / Double(sampleCount)) }
                continue
            }
            defer { previous = bytes }
            guard let prev = previous, prev.count == bytes.count else { continue }
            var sum: Int = 0
            for j in 0..<bytes.count {
                sum += abs(Int(bytes[j]) - Int(prev[j]))
            }
            let perPixel = Double(sum) / Double(bytes.count * 255)
            if i < windowCount {
                rawDiffs[i] = perPixel
            }
            if i % 8 == 0 || i == sampleCount - 1 {
                progress(Double(i + 1) / Double(sampleCount))
            }
        }

        // Normalise + invert so 1.0 means "settled framing".
        let normalised = self.normalised(rawDiffs)
        return normalised.map { 1.0 - $0 }
    }

    /// Generate a frame at `time` and reduce it to a single-channel
    /// grayscale byte array via simple luminance averaging. Sized
    /// to whatever the generator was configured for.
    private static func grayPixelBytes(
        at time: CMTime,
        generator: AVAssetImageGenerator
    ) async throws -> [UInt8] {
        let (cg, _) = try await generator.image(at: time)
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return [] }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var gray = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(rgba[i * 4 + 0])
            let g = Int(rgba[i * 4 + 1])
            let b = Int(rgba[i * 4 + 2])
            // ITU-R BT.601 luma weights — fast integer arithmetic
            // for a single-pass conversion.
            gray[i] = UInt8(min(255, (r * 299 + g * 587 + b * 114) / 1000))
        }
        return gray
    }

    // MARK: - Picker

    /// Greedy picker: smooth the combined scores, find peak runs
    /// above a dynamic threshold, sort by average score, then take
    /// segments (capped to `maxSegmentDuration`) until the total
    /// reaches `targetDuration`.
    private static func pickSegments(
        from windows: [WindowScore],
        targetDuration: TimeInterval
    ) -> [Segment] {
        guard !windows.isEmpty else { return [] }
        let smoothed = smooth(windows.map(\.combinedScore), radius: 1)

        // Dynamic threshold: use the 60th percentile so we don't
        // pick segments from genuinely empty clips, but still find
        // *something* if the whole source is mid.
        let sortedScores = smoothed.sorted()
        let threshold = sortedScores[Int(Double(sortedScores.count) * 0.6)]

        // Walk windows, build candidate segments where smoothed score
        // is above the threshold.
        var candidates: [Segment] = []
        var runStart: Int?
        var runSum: Double = 0
        for i in 0..<smoothed.count {
            if smoothed[i] >= threshold {
                if runStart == nil { runStart = i }
                runSum += smoothed[i]
            } else if let start = runStart {
                let len = i - start
                let avg = runSum / Double(len)
                let segDur = Double(len) * windowDuration
                if segDur >= minSegmentDuration {
                    candidates.append(Segment(
                        startTime: Double(start) * windowDuration,
                        duration: min(segDur, maxSegmentDuration),
                        averageScore: avg
                    ))
                }
                runStart = nil
                runSum = 0
            }
        }
        if let start = runStart {
            let len = smoothed.count - start
            let segDur = Double(len) * windowDuration
            let avg = runSum / Double(len)
            if segDur >= minSegmentDuration {
                candidates.append(Segment(
                    startTime: Double(start) * windowDuration,
                    duration: min(segDur, maxSegmentDuration),
                    averageScore: avg
                ))
            }
        }

        // Take top candidates by avg score until we hit target.
        let ranked = candidates.sorted { $0.averageScore > $1.averageScore }
        var picked: [Segment] = []
        var total: TimeInterval = 0
        for seg in ranked {
            guard total < targetDuration else { break }
            let remaining = targetDuration - total
            let trimmed: Segment
            if seg.duration > remaining {
                trimmed = Segment(
                    id: seg.id,
                    startTime: seg.startTime,
                    duration: max(minSegmentDuration, remaining),
                    averageScore: seg.averageScore
                )
            } else {
                trimmed = seg
            }
            picked.append(trimmed)
            total += trimmed.duration
        }

        // Show in source-time order so the storyboard reads
        // chronologically.
        return picked.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Helpers

    private static func normalised(_ values: [Double]) -> [Double] {
        guard let maxValue = values.max(), maxValue > 0.0001 else {
            return values.map { _ in 0 }
        }
        return values.map { $0 / maxValue }
    }

    /// Box-blur smoothing across a `2*radius+1`-window neighbourhood.
    /// Damps single-window noise so the picker sees stable runs.
    private static func smooth(_ values: [Double], radius: Int) -> [Double] {
        guard radius > 0, values.count > 2 * radius else { return values }
        var out = values
        for i in radius..<(values.count - radius) {
            var sum: Double = 0
            for d in -radius...radius { sum += values[i + d] }
            out[i] = sum / Double(2 * radius + 1)
        }
        return out
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
