import Accelerate
import AVFoundation
import Foundation
import OSLog

/// On-device beat tracker. Pure Swift port of librosa's `beat_track`
/// pipeline, built on Accelerate's vDSP for the FFT primitive — every
/// other stage (mel filterbank, spectral flux, autocorrelation, DP
/// backtrack) is hand-rolled so the algorithm stays inspectable and the
/// MIT license stays clean.
///
/// The pipeline:
///
///   PCM (any rate)
///     → mix to mono, resample to 22.05 kHz
///     → STFT (Hann window, n_fft=2048, hop=512 → ~23 ms / frame)
///     → mel-power spectrogram (128 bands, 27.5 Hz → Nyquist)
///     → log power (`log(1 + amplitude)`)
///     → spectral flux (positive frame-to-frame diff, summed across bands)
///     → local-mean subtraction + half-wave rectification → onset envelope
///     → autocorrelation tempo estimate, weighted by log-normal prior
///       centred on 120 BPM
///     → DP forward pass (Ellis 2007): each frame's beat score combines
///       local onset strength with tempo consistency against the best
///       previous candidate inside the search window `[−2P, −P/2]`
///     → robust end-of-track pick (local-max + median-cutoff) → backtrack
///
/// Quality target: pop/rock with a steady kick is locked to within
/// ±1 frame (~23 ms); free-tempo classical / spoken word still produces
/// a plausible onset envelope even if the beat sequence is loose.
struct BeatDetector: Sendable {
    private static let logger = Logger(subsystem: "com.damioffice.EditOS", category: "BeatDetector")

    // MARK: - Pipeline constants

    /// Working sample rate. 22.05 kHz matches librosa's default — high
    /// enough to retain musical onsets, low enough to halve the FFT
    /// cost vs. 44.1 kHz. The resampler does the conversion regardless
    /// of the source rate.
    static let sampleRate: Double = 22050
    /// STFT hop in samples. 512 @ 22.05 kHz → ~23 ms per onset frame.
    static let hopSize: Int = 512
    /// STFT window size in samples. 2048 @ 22.05 kHz → ~93 ms window;
    /// gives 1024 frequency bins after the real FFT.
    static let frameSize: Int = 2048
    /// Number of mel-frequency bands in the filterbank.
    static let melBandCount: Int = 128
    /// Lower bound of the mel filterbank (lowest piano A is 27.5 Hz).
    static let melMinHz: Double = 27.5
    /// Upper bound — capped at Nyquist.
    static var melMaxHz: Double { sampleRate / 2 }

    /// Log-normal tempo prior mean (BPM). Pop / rock / dance music
    /// clusters around 90–130 BPM, so the prior is centred at 120.
    static let tempoPriorMean: Double = 120
    /// Log-normal tempo prior σ (in natural-log units). 1.0 gives the
    /// prior enough width to admit 60 BPM ballads and 200 BPM punk.
    static let tempoPriorSigma: Double = 1.0
    /// Tempo search window in BPM. Outside this band, the autocorrelation
    /// vote is ignored — keeps double / half-tempo bias under control.
    static let tempoMinBPM: Double = 40
    static let tempoMaxBPM: Double = 240

    /// DP "tightness" — penalty weight on tempo deviation. Higher =
    /// stronger preference for steady tempo over chasing local onset
    /// peaks. 100 is librosa's default and is solid for pop/rock; drop
    /// to 50 for music with rubato.
    static let dpTightness: Double = 100
    /// Local-mean window length (in onset frames) used to normalise the
    /// spectral-flux curve. ~0.5 second at hop=512 / 22.05 kHz.
    static let onsetLocalMeanFrames: Int = 22

    // MARK: - Public API

    struct Result: Sendable {
        /// Estimated global tempo in BPM. Zero if the file was too short
        /// or the autocorrelation found no plausible peak.
        let tempo: Double
        /// Beat positions in seconds from the start of the audio.
        let beats: [TimeInterval]
        /// Per-frame onset strength after normalisation. Useful for
        /// rendering a heat-strip in the inspector.
        let onsetEnvelope: [Float]
        /// Seconds between successive onset frames — multiply a frame
        /// index by this to get an absolute time.
        let hopDuration: TimeInterval
    }

    /// Analyse the audio at `url` and return the detected tempo + beat
    /// positions. Runs the heavy lifting on a background priority Task.
    func analyze(url: URL) async throws -> Result {
        let hopDuration = Double(Self.hopSize) / Self.sampleRate
        let samples = try await Self.loadMonoSamples(from: url)

        guard samples.count > Self.frameSize * 2 else {
            // Less than ~200 ms of audio — nothing to track.
            return Result(tempo: 0, beats: [], onsetEnvelope: [], hopDuration: hopDuration)
        }

        let envelope = Self.onsetEnvelope(samples: samples)
        guard envelope.count > 4 else {
            return Result(tempo: 0, beats: [], onsetEnvelope: envelope, hopDuration: hopDuration)
        }

        let normalised = Self.normaliseEnvelope(envelope)
        let tempo = Self.estimateTempo(onset: normalised, hopDuration: hopDuration)
        let beatFrames = Self.trackBeats(
            onset: normalised,
            tempoBPM: tempo,
            hopDuration: hopDuration
        )
        let beatTimes = beatFrames.map { Double($0) * hopDuration }

        let durationSeconds = Double(samples.count) / Self.sampleRate
        Self.logger.info("Detected \(beatTimes.count) beats @ \(tempo, format: .fixed(precision: 1)) BPM over \(durationSeconds, format: .fixed(precision: 1))s")
        return Result(
            tempo: tempo,
            beats: beatTimes,
            onsetEnvelope: normalised,
            hopDuration: hopDuration
        )
    }

    // MARK: - Audio loading

    /// Read the input file, mix to mono, resample to `sampleRate`. Uses
    /// `AVAudioConverter` so any format AVFoundation can decode works
    /// (mp3, m4a, wav, mov audio track, etc.).
    private static func loadMonoSamples(from url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw Error.formatSetupFailed
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Error.formatSetupFailed
        }

        let inputLength = AVAudioFrameCount(file.length)
        guard inputLength > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputLength)
        else {
            return []
        }
        try file.read(into: inputBuffer)

        // Slight over-allocation so the resampler never has to truncate.
        let ratio = sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return []
        }

        var convertError: NSError?
        var hasProvidedInput = false
        let status = converter.convert(to: outputBuffer, error: &convertError) { _, statusOut in
            if hasProvidedInput {
                statusOut.pointee = .endOfStream
                return nil
            }
            hasProvidedInput = true
            statusOut.pointee = .haveData
            return inputBuffer
        }

        if let convertError { throw convertError }
        guard status != .error else { throw Error.resampleFailed }

        let length = Int(outputBuffer.frameLength)
        guard length > 0, let channelData = outputBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channelData, count: length))
    }

    // MARK: - Onset envelope

    /// Compute the raw spectral-flux onset envelope: STFT → mel
    /// magnitudes → log → positive frame-to-frame difference summed
    /// across mel bands. The output is per-frame, length =
    /// `(samples.count - frameSize) / hopSize + 1`.
    private static func onsetEnvelope(samples: [Float]) -> [Float] {
        let frameCount = max(0, (samples.count - frameSize) / hopSize) + 1
        guard frameCount > 1 else { return [] }

        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Pre-compute the Hann window once and re-use across frames.
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        let melFilters = buildMelFilterbank(
            sampleRate: sampleRate,
            fftSize: frameSize,
            bandCount: melBandCount,
            minHz: melMinHz,
            maxHz: melMaxHz
        )

        let halfSize = frameSize / 2
        var realp = [Float](repeating: 0, count: halfSize)
        var imagp = [Float](repeating: 0, count: halfSize)
        var windowed = [Float](repeating: 0, count: frameSize)
        var magnitude = [Float](repeating: 0, count: halfSize)
        var melEnergy = [Float](repeating: 0, count: melBandCount)
        var prevMelLog = [Float](repeating: 0, count: melBandCount)
        var currMelLog = [Float](repeating: 0, count: melBandCount)
        var envelope = [Float](repeating: 0, count: frameCount)

        for frameIdx in 0..<frameCount {
            let start = frameIdx * hopSize
            let end = min(start + frameSize, samples.count)
            // Copy + window. We zero-pad the tail if the last frame
            // doesn't have a full window of samples available.
            for i in 0..<frameSize {
                windowed[i] = (start + i) < end ? samples[start + i] * window[i] : 0
            }

            // Real FFT via the split-complex packed representation.
            windowed.withUnsafeMutableBufferPointer { wPtr in
                realp.withUnsafeMutableBufferPointer { rPtr in
                    imagp.withUnsafeMutableBufferPointer { iPtr in
                        var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                        wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { cPtr in
                            vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfSize))
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }

            // Magnitude = sqrt(re^2 + im^2). `vDSP_zvmags` gives the
            // squared magnitude; we take the square root next so the
            // mel-filterbank dot product weights amplitudes (not powers).
            realp.withUnsafeMutableBufferPointer { rPtr in
                imagp.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    vDSP_zvmags(&split, 1, &magnitude, 1, vDSP_Length(halfSize))
                }
            }
            var n = Int32(halfSize)
            vvsqrtf(&magnitude, magnitude, &n)

            // Mel-band energies via filterbank dot products.
            for band in 0..<melBandCount {
                let filter = melFilters[band]
                var energy: Float = 0
                vDSP_dotpr(filter, 1, magnitude, 1, &energy, vDSP_Length(filter.count))
                melEnergy[band] = energy
            }

            // log(1 + e) compresses dynamic range without singularity
            // at zero — handles silent frames cleanly.
            for i in 0..<melBandCount {
                currMelLog[i] = log10f(1 + melEnergy[i])
            }

            // Positive spectral flux: ReLU of frame-to-frame diff,
            // summed across bands. Negative diffs (energy fading) carry
            // no onset information so we discard them.
            if frameIdx > 0 {
                var flux: Float = 0
                for i in 0..<melBandCount {
                    let diff = currMelLog[i] - prevMelLog[i]
                    if diff > 0 { flux += diff }
                }
                envelope[frameIdx] = flux
            }

            // Carry curr → prev for the next iteration. A plain assign
            // is faster than swap-and-overwrite for 128 floats.
            prevMelLog = currMelLog
        }

        return envelope
    }

    /// Normalise the raw flux curve: subtract a moving local mean (so
    /// loud passages don't dominate quieter ones), half-wave rectify,
    /// then scale to `[0, 1]` by the global max.
    private static func normaliseEnvelope(_ raw: [Float]) -> [Float] {
        let n = raw.count
        guard n > 0 else { return raw }
        var output = [Float](repeating: 0, count: n)
        let half = max(1, onsetLocalMeanFrames / 2)

        // Moving mean via prefix sums — O(n) instead of O(n*window).
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + raw[i] }

        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            let mean = (prefix[hi] - prefix[lo]) / Float(hi - lo)
            output[i] = max(0, raw[i] - mean)
        }

        guard let maxVal = output.max(), maxVal > 1e-9 else { return output }
        let invMax = 1 / maxVal
        vDSP_vsmul(output, 1, [invMax], &output, 1, vDSP_Length(n))
        return output
    }

    // MARK: - Mel filterbank

    
    /// Build a triangular mel filterbank. Each filter is a length-`fftSize/2`
    /// vector of weights that, when dot-producted with a magnitude
    /// spectrum, yields one mel-band energy.
    private static func buildMelFilterbank(
        sampleRate: Double,
        fftSize: Int,
        bandCount: Int,
        minHz: Double,
        maxHz: Double
    ) -> [[Float]] {
        let minMel = hzToMel(minHz)
        let maxMel = hzToMel(maxHz)
        // `bandCount + 2` mel points define `bandCount` overlapping
        // triangles: each triangle peaks at the middle of three points.
        let melSpan = maxMel - minMel
        let melDenom = Double(bandCount + 1)
        var melPoints: [Double] = []
        melPoints.reserveCapacity(bandCount + 2)
        for i in 0...(bandCount + 1) {
            melPoints.append(minMel + melSpan * Double(i) / melDenom)
        }
        let hzPoints = melPoints.map(melToHz)
        let binPoints = hzPoints.map { hz in
            Int(round(Double(fftSize) * hz / sampleRate))
        }

        let halfSize = fftSize / 2
        var filters: [[Float]] = []
        filters.reserveCapacity(bandCount)
        for band in 0..<bandCount {
            let leftBin = max(0, binPoints[band])
            let centerBin = max(leftBin + 1, binPoints[band + 1])
            let rightBin = max(centerBin + 1, binPoints[band + 2])
            var filter = [Float](repeating: 0, count: halfSize)
            // Rising flank
            let upDenom = Float(max(1, centerBin - leftBin))
            for bin in leftBin..<min(centerBin, halfSize) {
                filter[bin] = Float(bin - leftBin) / upDenom
            }
            // Falling flank
            let downDenom = Float(max(1, rightBin - centerBin))
            for bin in centerBin..<min(rightBin, halfSize) {
                filter[bin] = Float(rightBin - bin) / downDenom
            }
            filters.append(filter)
        }
        return filters
    }

    private static func hzToMel(_ hz: Double) -> Double {
        2595 * log10(1 + hz / 700)
    }

    private static func melToHz(_ mel: Double) -> Double {
        700 * (pow(10, mel / 2595) - 1)
    }

    // MARK: - Tempo estimation

    /// Estimate global tempo via autocorrelation of the onset envelope,
    /// weighted by a log-normal prior centred at `tempoPriorMean` BPM.
    /// The prior is what stops the picker locking onto double / half
    /// tempo for music with a strong off-beat (snares vs. kicks).
    private static func estimateTempo(onset: [Float], hopDuration: TimeInterval) -> Double {
        guard onset.count > 4 else { return 0 }

        let minLag = max(1, Int((60.0 / tempoMaxBPM) / hopDuration))
        let maxLag = min(Int((60.0 / tempoMinBPM) / hopDuration), onset.count / 2)
        guard maxLag > minLag else { return tempoPriorMean }

        // Standard biased autocorrelation: ACF[lag] = mean(x[i] * x[i + lag]).
        var acf = [Float](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            let count = onset.count - lag
            var sum: Float = 0
            // Use vDSP_dotpr — much faster than a Swift loop on long
            // envelopes (30-min track → 77k frames).
            onset.withUnsafeBufferPointer { base in
                let ptr = base.baseAddress!
                vDSP_dotpr(ptr, 1, ptr.advanced(by: lag), 1, &sum, vDSP_Length(count))
            }
            acf[lag] = sum / Float(count)
        }

        var bestScore: Float = -.infinity
        var bestLag = minLag
        for lag in minLag...maxLag {
            let bpm = 60.0 / (Double(lag) * hopDuration)
            // log-normal density (ignoring the constant prefactor — we
            // only care about argmax, so the normalising constant is
            // irrelevant).
            let logRatio = log(bpm / tempoPriorMean)
            let prior = exp(-0.5 * (logRatio * logRatio) / (tempoPriorSigma * tempoPriorSigma))
            let score = acf[lag] * Float(prior)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        return 60.0 / (Double(bestLag) * hopDuration)
    }

    // MARK: - Beat tracking (Ellis 2007 DP)

    /// Dynamic-programming beat tracking. Each frame's cumulative score
    /// is `local onset + max over previous-beat candidates of (prev
    /// score − tightness · log(δ/period)²)`. We then pick a robust
    /// end-of-track frame and backtrack through the backpointers to
    /// recover the beat sequence.
    private static func trackBeats(
        onset: [Float],
        tempoBPM: Double,
        hopDuration: TimeInterval
    ) -> [Int] {
        let n = onset.count
        guard n > 4, tempoBPM > 0 else { return [] }
        let period = 60.0 / tempoBPM / hopDuration
        guard period > 1 else { return [] }
        let periodFrames = Int(round(period))
        guard periodFrames > 0 else { return [] }

        // Pre-compute the per-offset transition penalty so the inner
        // loop is a single addition + comparison. Search window is
        // `[−2P, −P/2]` — the same shape librosa uses.
        let windowLo = max(1, periodFrames / 2)
        let windowHi = max(windowLo + 1, 2 * periodFrames)
        var penalty = [Float](repeating: 0, count: windowHi + 1)
        for delta in windowLo...windowHi {
            let logRatio = log(Double(delta) / period)
            penalty[delta] = -Float(dpTightness) * Float(logRatio * logRatio)
        }

        var dpScore = [Float](repeating: 0, count: n)
        var backpointer = [Int](repeating: -1, count: n)
        // First-beat seed: frames in the leading bar can start a beat
        // sequence even without a predecessor.
        let seedEnd = min(periodFrames, n)
        for i in 0..<seedEnd {
            dpScore[i] = onset[i]
        }

        for t in seedEnd..<n {
            let lo = max(0, t - windowHi)
            let hi = max(lo, t - windowLo)
            var bestScore: Float = -.infinity
            var bestPrev = -1
            for prev in lo...hi {
                let delta = t - prev
                guard delta >= windowLo, delta <= windowHi else { continue }
                let candidate = dpScore[prev] + penalty[delta]
                if candidate > bestScore {
                    bestScore = candidate
                    bestPrev = prev
                }
            }
            if bestPrev >= 0 {
                dpScore[t] = onset[t] + bestScore
                backpointer[t] = bestPrev
            } else {
                dpScore[t] = onset[t]
            }
        }

        // Robust end-of-track pick (librosa's heuristic): take the
        // median score across local maxima, then choose the *last*
        // local max whose score exceeds half of that median. This
        // avoids picking a trailing energy spike from fade-out as the
        // final beat.
        let endFrame = pickEndFrame(dpScore: dpScore)
        guard endFrame >= 0 else { return [] }

        var beats: [Int] = []
        var cursor = endFrame
        while cursor >= 0 {
            beats.append(cursor)
            let prev = backpointer[cursor]
            if prev < 0 || prev >= cursor { break }
            cursor = prev
        }
        return beats.reversed()
    }

    /// Pick the last "strong" local maximum of the DP score curve as
    /// the final beat. Robust to fade-outs that would otherwise pull
    /// the argmax past the music's actual end.
    private static func pickEndFrame(dpScore: [Float]) -> Int {
        let n = dpScore.count
        guard n > 2 else { return n - 1 }
        var localMaxScores: [Float] = []
        var localMaxIndices: [Int] = []
        for i in 1..<(n - 1) where dpScore[i] >= dpScore[i - 1] && dpScore[i] >= dpScore[i + 1] {
            localMaxScores.append(dpScore[i])
            localMaxIndices.append(i)
        }
        guard !localMaxScores.isEmpty else { return n - 1 }
        let sorted = localMaxScores.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = 0.5 * median
        for idx in localMaxIndices.reversed() where dpScore[idx] >= threshold {
            return idx
        }
        return localMaxIndices.last ?? (n - 1)
    }

    // MARK: - Errors

    enum Error: Swift.Error, LocalizedError {
        case formatSetupFailed
        case resampleFailed

        var errorDescription: String? {
            switch self {
            case .formatSetupFailed: return "Could not configure audio format for beat detection."
            case .resampleFailed:    return "Failed to resample audio to 22.05 kHz."
            }
        }
    }
}
