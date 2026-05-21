import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import OSLog

/// Pre-renders pixel-blended transitions between adjacent video clips
/// and caches them as `.mov` files on disk. The composition pipeline
/// then inserts the cached transition movie as a regular clip on the
/// single shared video track — no custom `AVVideoCompositing` needed.
///
/// Cache layout:
///
///   ~/Library/Application Support/EditOS/Transitions/
///     <sha256(request)>.mov
///
/// Cache key is content-derived (URLs + boundaries + duration + canvas
/// + frame rate + kind), so any user edit that changes the visible
/// blend produces a fresh file. The previous file is left on disk —
/// V1 doesn't reap; an LRU eviction policy is filed as a follow-up.
///
/// Concurrency: an `actor` so two simultaneous composition builds for
/// the same project don't race on `inFlight`; an in-flight render for
/// a given key is shared across callers via a single `Task`.
actor TransitionCache {
    private static let logger = Logger(subsystem: "com.damioffice.EditOS", category: "TransitionCache")

    /// Inputs that fully describe a transition render — used both as
    /// the cache key and as the renderer's parameter bundle.
    struct Request: Hashable, Sendable {
        let leadURL: URL
        let trailURL: URL
        /// End time of the lead clip in *source-asset* coordinates
        /// (seconds). The transition pulls from `leadEnd − duration`
        /// → `leadEnd` of the lead source.
        let leadEndSeconds: TimeInterval
        /// Start time of the trail clip in *source-asset* coordinates.
        /// The transition pulls from `trailStart` → `trailStart +
        /// duration` of the trail source.
        let trailStartSeconds: TimeInterval
        let duration: TimeInterval
        let canvasSize: CGSize
        let frameRate: Double
        let kind: Transition.Kind
    }

    // Unqualified `Error` inside this actor resolves to the nested
    // `TransitionCache.Error` enum (name shadowing). Use `Swift.Error`
    // for the protocol existential.
    private var inFlight: [Request: Task<URL, any Swift.Error>] = [:]

    static let shared = TransitionCache()

    /// Where the cached `.mov` files live. Created on first use.
    private let cacheDirectory: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let dir = support.appending(path: "EditOS/Transitions", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Returns the URL of the cached transition `.mov` for `request`,
    /// rendering it on demand. Multiple callers asking for the same
    /// request share the same in-flight Task — no duplicate renders.
    func transitionURL(for request: Request) async throws -> URL {
        let key = cacheKey(for: request)
        let url = cacheDirectory.appending(path: "\(key).mov")

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let existing = inFlight[request] {
            return try await existing.value
        }
        // Annotate the closure type explicitly so `throws` is untyped
        // (= `any Error`). Without this, Swift's typed-throws inference
        // narrows the Task's Failure to `TransitionCache.Error`, which
        // then can't be stored in our `[Request: Task<URL, any Error>]`
        // table.
        let task: Task<URL, any Swift.Error> = Task { () async throws -> URL in
            try await Self.renderTransition(request: request, outputURL: url)
            return url
        }
        inFlight[request] = task
        defer { inFlight[request] = nil }
        return try await task.value
    }

    // MARK: - Cache key

    /// SHA-256 of the canonical string representation. Stable across
    /// process restarts. Truncated to 32 chars for filename brevity.
    private func cacheKey(for request: Request) -> String {
        var hasher = Hasher()
        hasher.combine(request)
        // Hasher's seed is randomised per-launch, so we can't use it
        // for filenames. Build a stable string instead.
        let raw = "\(request.leadURL.path)|\(request.trailURL.path)|\(request.leadEndSeconds)|\(request.trailStartSeconds)|\(request.duration)|\(Int(request.canvasSize.width))x\(Int(request.canvasSize.height))|\(request.frameRate)|\(request.kind.rawValue)"
        return Self.sha256Hex(raw).prefix(32).description
    }

    private static func sha256Hex(_ input: String) -> String {
        var hasher = SHA256()
        hasher.update(input.utf8)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Rendering

    /// Render the transition into `outputURL`. Pulls frames from both
    /// source assets through `AVAssetReader`, blends each pair via
    /// CIImage compositing at `request.kind`'s curve, scales to canvas,
    /// and writes the result through `AVAssetWriter` as H.264 in a
    /// `.mov` container.
    private static func renderTransition(
        request: Request,
        outputURL: URL
    ) async throws {
        // Don't leave a half-written file behind from a previous failed
        // attempt — fresh file every render.
        try? FileManager.default.removeItem(at: outputURL)

        let leadAsset = AVURLAsset(url: request.leadURL)
        let trailAsset = AVURLAsset(url: request.trailURL)

        guard let leadTrack = try await leadAsset.loadTracks(withMediaType: .video).first else {
            throw Error.assetMissingVideo(request.leadURL)
        }
        guard let trailTrack = try await trailAsset.loadTracks(withMediaType: .video).first else {
            throw Error.assetMissingVideo(request.trailURL)
        }

        let leadTransform = try await leadTrack.load(.preferredTransform)
        let trailTransform = try await trailTrack.load(.preferredTransform)

        // Lead reader: pull the last `duration` seconds of the lead
        // clip's source range. Clamp the start so we don't ask for a
        // negative time when the clip's leadEndSeconds is shorter than
        // the requested transition.
        let leadStart = max(0, request.leadEndSeconds - request.duration)
        let leadRange = CMTimeRange(
            start: CMTime(seconds: leadStart, preferredTimescale: 600),
            duration: CMTime(seconds: request.duration, preferredTimescale: 600)
        )
        let trailRange = CMTimeRange(
            start: CMTime(seconds: max(0, request.trailStartSeconds), preferredTimescale: 600),
            duration: CMTime(seconds: request.duration, preferredTimescale: 600)
        )

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let leadReader = try AVAssetReader(asset: leadAsset)
        leadReader.timeRange = leadRange
        let leadOutput = AVAssetReaderTrackOutput(track: leadTrack, outputSettings: outputSettings)
        leadOutput.alwaysCopiesSampleData = false
        guard leadReader.canAdd(leadOutput) else { throw Error.readerSetupFailed }
        leadReader.add(leadOutput)

        let trailReader = try AVAssetReader(asset: trailAsset)
        trailReader.timeRange = trailRange
        let trailOutput = AVAssetReaderTrackOutput(track: trailTrack, outputSettings: outputSettings)
        trailOutput.alwaysCopiesSampleData = false
        guard trailReader.canAdd(trailOutput) else { throw Error.readerSetupFailed }
        trailReader.add(trailOutput)

        guard leadReader.startReading() else { throw Error.readerStartFailed }
        guard trailReader.startReading() else { throw Error.readerStartFailed }

        // Writer — H.264 in .mov container so the existing
        // CompositionBuilder pipeline ingests it without ceremony.
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(request.canvasSize.width),
                AVVideoHeightKey: Int(request.canvasSize.height)
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(request.canvasSize.width),
                kCVPixelBufferHeightKey as String: Int(request.canvasSize.height)
            ]
        )
        guard writer.canAdd(writerInput) else { throw Error.writerSetupFailed }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw Error.writerStartFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext()
        let frameRate = max(1.0, request.frameRate)
        let frameCount = max(1, Int(round(request.duration * frameRate)))
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        for frameIdx in 0..<frameCount {
            let leadCI = try Self.nextOrientedImage(
                from: leadOutput,
                transform: leadTransform,
                canvasSize: request.canvasSize
            )
            let trailCI = try Self.nextOrientedImage(
                from: trailOutput,
                transform: trailTransform,
                canvasSize: request.canvasSize
            )

            // Curve for the kind — crossfade is linear, dip-to-color
            // ramps through the dip colour at the midpoint, otherwise
            // identical visual behaviour to the existing veil-based
            // path so the user can choose between them.
            let progress = Double(frameIdx) / Double(max(1, frameCount - 1))
            let blended = blend(
                lead: leadCI,
                trail: trailCI,
                progress: progress,
                kind: request.kind,
                canvasSize: request.canvasSize
            )

            // Allocate a buffer from the adaptor's pool — cheaper than
            // CVPixelBufferCreate on each frame.
            var pixelBuffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            }
            guard let pb = pixelBuffer else {
                throw Error.pixelBufferAllocFailed
            }
            ciContext.render(blended, to: pb)

            // The input may not be ready immediately (writer flushing
            // its buffers). Spin politely until it accepts more.
            while !writerInput.isReadyForMoreMediaData {
                await Task.yield()
            }
            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(frameIdx))
            adaptor.append(pb, withPresentationTime: pts)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw Error.writerFinishFailed(writer.error?.localizedDescription ?? "unknown")
        }
        logger.info("Rendered transition \(outputURL.lastPathComponent, privacy: .public) (\(frameCount) frames @ \(frameRate, format: .fixed(precision: 1)) fps)")
    }

    /// Read the next sample from `output`, apply the preferred
    /// transform, and aspect-fit + centre into the canvas. Returns a
    /// black canvas if the reader is exhausted (e.g. the source ran
    /// out before we hit `frameCount` — happens for short clips).
    private static func nextOrientedImage(
        from output: AVAssetReaderTrackOutput,
        transform: CGAffineTransform,
        canvasSize: CGSize
    ) throws -> CIImage {
        guard let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            return blackCanvas(canvasSize: canvasSize)
        }
        defer { CMSampleBufferInvalidate(sample) }
        let raw = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = raw.transformed(by: transform)

        // Re-anchor to origin after the orient transform — transforms
        // that include a translation (rotated portrait video) push the
        // extent off (0,0) and CIImage compositing expects an anchored
        // image to draw correctly.
        let extent = oriented.extent
        let translated = oriented.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x,
            y: -extent.origin.y
        ))

        // Aspect-fit into the canvas. Same shape as
        // CompositionBuilder's per-frame fitting so blended frames
        // align with neighbouring (non-transition) frames.
        let safeWidth = max(1, extent.size.width)
        let safeHeight = max(1, extent.size.height)
        let scale = min(canvasSize.width / safeWidth, canvasSize.height / safeHeight)
        let scaledW = extent.size.width * scale
        let scaledH = extent.size.height * scale
        let tx = (canvasSize.width - scaledW) / 2
        let ty = (canvasSize.height - scaledH) / 2

        return translated
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
            .composited(over: blackCanvas(canvasSize: canvasSize))
    }

    private static func blackCanvas(canvasSize: CGSize) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(origin: .zero, size: canvasSize))
    }

    /// Compose `lead` and `trail` according to the transition `kind`.
    /// All kinds are baked into the cached `.mov` so the timeline
    /// renderer doesn't have to know about transitions at all.
    private static func blend(
        lead: CIImage,
        trail: CIImage,
        progress: Double,
        kind: Transition.Kind,
        canvasSize: CGSize
    ) -> CIImage {
        switch kind {
        case .crossfade:
            // True pixel blend — lead fades out, trail fades in,
            // linearly weighted by progress.
            let leadAlpha = 1 - progress
            let trailAlpha = progress
            let leadDimmed = applyAlpha(leadAlpha, to: lead)
            let trailDimmed = applyAlpha(trailAlpha, to: trail)
            return trailDimmed.composited(over: leadDimmed)

        case .dipToBlack, .dipToWhite:
            // Dip-through-colour. First half: lead fades to dip
            // colour; second half: dip colour fades to trail. Matches
            // the existing dip-fade path's visual exactly so users get
            // a consistent feel whether they pick the dip variant or
            // a true crossfade.
            let dipColor: CIColor = (kind == .dipToBlack)
                ? CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                : CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            let dipCanvas = CIImage(color: dipColor)
                .cropped(to: CGRect(origin: .zero, size: canvasSize))
            if progress < 0.5 {
                // 0 → 0.5 : lead opacity 1 → 0, dip opacity 0 → 1
                let local = progress * 2
                let leadDim = applyAlpha(1 - local, to: lead)
                let dipDim = applyAlpha(local, to: dipCanvas)
                return dipDim.composited(over: leadDim)
            } else {
                // 0.5 → 1 : dip opacity 1 → 0, trail opacity 0 → 1
                let local = (progress - 0.5) * 2
                let dipDim = applyAlpha(1 - local, to: dipCanvas)
                let trailDim = applyAlpha(local, to: trail)
                return trailDim.composited(over: dipDim)
            }
        }
    }

    /// Multiply an image's alpha channel by a scalar via CIColorMatrix.
    /// Cheaper than building a new mask layer every frame.
    private static func applyAlpha(_ alpha: Double, to image: CIImage) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
        return matrix.outputImage ?? image
    }

    // MARK: - Errors

    enum Error: Swift.Error, LocalizedError {
        case assetMissingVideo(URL)
        case readerSetupFailed
        case readerStartFailed
        case writerSetupFailed
        case writerStartFailed(String)
        case writerFinishFailed(String)
        case pixelBufferAllocFailed

        var errorDescription: String? {
            switch self {
            case .assetMissingVideo(let url):
                return "No video track found in \(url.lastPathComponent)."
            case .readerSetupFailed:
                return "Couldn't set up an AVAssetReader for the transition source."
            case .readerStartFailed:
                return "AVAssetReader failed to start."
            case .writerSetupFailed:
                return "Couldn't set up an AVAssetWriter for the transition cache."
            case .writerStartFailed(let detail):
                return "AVAssetWriter failed to start: \(detail)."
            case .writerFinishFailed(let detail):
                return "AVAssetWriter failed to finish: \(detail)."
            case .pixelBufferAllocFailed:
                return "Couldn't allocate a pixel buffer for the transition render."
            }
        }
    }
}

// MARK: - SHA-256

/// Minimal SHA-256 over UTF-8 bytes. Used only for cache filenames —
/// `CryptoKit` would be cleaner but is `@MainActor`-bound on some
/// macOS versions, which makes calling it from an actor awkward.
/// Pure-Swift here keeps the actor isolation story simple.
private struct SHA256 {
    private var data = Data()

    mutating func update(_ bytes: some Sequence<UInt8>) {
        data.append(contentsOf: bytes)
    }

    mutating func finalize() -> [UInt8] {
        // Standard FIPS-180-4 SHA-256, message-length in bits is a
        // 64-bit big-endian integer appended after the 0x80 sentinel
        // and zero-padding to a 512-bit boundary.
        let bitLength = UInt64(data.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLength >> shift) & 0xff))
        }

        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for blockStart in stride(from: 0, to: bytes.count, by: 64) {
                var w = [UInt32](repeating: 0, count: 64)
                for i in 0..<16 {
                    let offset = blockStart + i * 4
                    w[i] = (UInt32(bytes[offset]) << 24)
                        | (UInt32(bytes[offset + 1]) << 16)
                        | (UInt32(bytes[offset + 2]) << 8)
                        |  UInt32(bytes[offset + 3])
                }
                for i in 16..<64 {
                    let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                    let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                    w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                }
                var a = h[0], b = h[1], c = h[2], d = h[3]
                var e = h[4], f = h[5], g = h[6], hh = h[7]
                for i in 0..<64 {
                    let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let temp1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                    let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                    let mj = (a & b) ^ (a & c) ^ (b & c)
                    let temp2 = S0 &+ mj
                    hh = g; g = f; f = e
                    e = d &+ temp1
                    d = c; c = b; b = a
                    a = temp1 &+ temp2
                }
                h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
                h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
            }
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in h {
            for shift in stride(from: 24, through: 0, by: -8) {
                out.append(UInt8((word >> shift) & 0xff))
            }
        }
        return out
    }

    private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
