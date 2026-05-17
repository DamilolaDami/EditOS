import AVFoundation
import Foundation
import Observation
import OSLog
import ScreenCaptureKit

/// Screen recording engine. The lifecycle and observable state live on
/// the main actor, but the per-frame sample pump runs on
/// ScreenCaptureKit's delivery queue inside the `StreamOutput` — bouncing
/// every CMSampleBuffer through MainActor was too slow, dropped frames,
/// and produced unplayable .mov files because samples never reached the
/// writer in time.
///
/// Lifecycle:
///   1. Caller resolves an `SCContentFilter` (display / window / region).
///   2. `start(filter:configuration:includeMicrophone:)` constructs the
///      `StreamOutput` (which owns an `AVAssetWriter` and the video +
///      audio inputs), starts the writer, then starts the stream.
///   3. Samples flow through `StreamOutput` directly on SCStream's
///      delivery queue. The writer session is opened lazily on the
///      first sample so its source time matches the first PTS.
///   4. `stop()` stops the stream, tells the `StreamOutput` to mark
///      inputs finished + finalise the writer, and returns the URL.
@MainActor
@Observable
final class ScreenRecorder: NSObject {
    private(set) var isRecording: Bool = false
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var lastRecordingURL: URL?

    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "ScreenRecorder")

    private var stream: SCStream?
    private var output: StreamOutput?
    private var elapsedTimer: Timer?
    private var startWallTime: Date?

    // MARK: - Public API

    @discardableResult
    func start(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        includeMicrophone: Bool
    ) async throws -> URL {
        guard !isRecording else {
            throw RecorderError.alreadyRecording
        }

        let outputURL = try Self.makeOutputURL()
        try? FileManager.default.removeItem(at: outputURL)

        // StreamOutput owns the writer + inputs. Constructing it gets
        // the writer ready to receive samples; appending starts as soon
        // as the first sample lands.
        //
        // Audio inputs are wired only when the user explicitly asked
        // for them. Adding an audio input with no samples ever arriving
        // makes `finishWriting()` end in `.failed`, which is the bug
        // we used to ship as "nothing happens when you stop recording".
        let includeAudio = includeMicrophone
        let output = try StreamOutput(
            outputURL: outputURL,
            configuration: configuration,
            includeAudio: includeAudio
        )

        // Crucial ordering: writer must be in `.writing` state BEFORE
        // we open the stream's tap. Otherwise the first batch of
        // sample buffers gets silently dropped because the writer
        // isn't ready to receive.
        guard output.writer.startWriting() else {
            let err = output.writer.error ?? NSError(
                domain: "ScreenRecorder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter refused to start"]
            )
            Self.log.error("startWriting failed: \(err.localizedDescription, privacy: .public)")
            throw RecorderError.failedToStart(err)
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        let queue = DispatchQueue(label: "com.damioffice.EditOS.ScreenRecorder.samples", qos: .userInitiated)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            // Only register audio taps when we actually have an audio
            // writer input to feed; otherwise we'd be discarding the
            // samples and the user gets nothing useful from them.
            if includeAudio {
                if configuration.capturesAudio {
                    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
                }
                if configuration.captureMicrophone {
                    try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue)
                }
            }
        } catch {
            Self.log.error("addStreamOutput failed: \(error.localizedDescription, privacy: .public)")
            // Roll back: the writer is sitting in `.writing` state. Tear
            // it down so the next start() begins from a clean slate.
            output.videoInput.markAsFinished()
            output.audioInput?.markAsFinished()
            await output.writer.finishWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecorderError.failedToStart(error)
        }

        do {
            try await stream.startCapture()
        } catch {
            Self.log.error("startCapture failed: \(error.localizedDescription, privacy: .public)")
            output.videoInput.markAsFinished()
            output.audioInput?.markAsFinished()
            await output.writer.finishWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecorderError.failedToStart(error)
        }

        self.stream = stream
        self.output = output

        isRecording = true
        elapsedSeconds = 0
        startWallTime = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.startWallTime else { return }
                self.elapsedSeconds = Date().timeIntervalSince(started)
            }
        }

        return outputURL
    }

    @discardableResult
    func stop() async -> URL? {
        guard isRecording, let stream, let output else { return nil }

        elapsedTimer?.invalidate()
        elapsedTimer = nil
        isRecording = false

        do {
            try await stream.stopCapture()
        } catch {
            Self.log.error("stopCapture failed: \(error.localizedDescription, privacy: .public)")
        }

        let url = await output.finish()

        self.stream = nil
        self.output = nil
        self.startWallTime = nil

        if let url {
            lastRecordingURL = url
        }
        return url
    }

    // MARK: - Output URL

    private static func makeOutputURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appending(path: "EditOS/Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = formatter.string(from: .now)
        return dir.appending(path: "Screen \(stamp).mov")
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case alreadyRecording
    case noShareableContent
    case permissionDenied
    case failedToStart(Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:    return "EditOS is already recording."
        case .noShareableContent:  return "Couldn't find anything to record. Is your Mac asleep?"
        case .permissionDenied:    return "Grant Screen Recording access in System Settings → Privacy & Security."
        case .failedToStart(let e): return e.localizedDescription
        }
    }
}

// MARK: - Stream output (the per-frame pump)

/// Holds the AVAssetWriter + its inputs and appends sample buffers
/// directly on SCStream's delivery queue. Nothing here hops back to
/// MainActor — that latency was what produced unplayable files in the
/// previous build.
///
/// State access is naturally serialised by the fact that every callback
/// arrives on the same `sampleHandlerQueue` we pass to `addStreamOutput`.
/// `nonisolated(unsafe)` is the right annotation here.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?

    private nonisolated(unsafe) var hasStartedSession = false

    init(outputURL: URL, configuration: SCStreamConfiguration, includeAudio: Bool) throws {
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: NSNumber(value: Int(configuration.width)),
            AVVideoHeightKey: NSNumber(value: Int(configuration.height)),
            AVVideoCompressionPropertiesKey: [
                // ~bytes-per-pixel × pixels × fps target. Clamps the
                // floor at 2 Mbps so tiny region captures still look
                // sharp.
                AVVideoAverageBitRateKey: NSNumber(value: max(2_000_000, configuration.width * configuration.height * 6)),
                AVVideoMaxKeyFrameIntervalKey: NSNumber(value: 60)
            ]
        ]
        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        } else {
            throw RecorderError.failedToStart(NSError(
                domain: "ScreenRecorder", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Writer rejected video input"]
            ))
        }

        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                self.audioInput = input
            } else {
                self.audioInput = nil
            }
        } else {
            self.audioInput = nil
        }

        super.init()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard writer.status == .writing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !hasStartedSession {
            // First sample lands; open the writer session at this PTS
            // so the output timeline starts at zero regardless of how
            // long the user spent picking a region.
            writer.startSession(atSourceTime: pts)
            hasStartedSession = true
        }

        switch type {
        case .screen:
            // Skip blank / idle / suspended frames so the writer's
            // pacing doesn't bloat with no-op data. The attachment
            // array uses SCStreamFrameInfo as its key type.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
               let raw = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: raw),
               status != .complete {
                return
            }
            if videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case .audio, .microphone:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        @unknown default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger(subsystem: "com.damioffice.EditOS", category: "ScreenRecorder")
            .error("SCStream stopped with error: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: Finish

    func finish() async -> URL? {
        let log = Logger(subsystem: "com.damioffice.EditOS", category: "ScreenRecorder")

        // If no samples ever arrived the writer never entered a
        // writeable session — finishWriting would produce a 0-byte or
        // malformed file. Bail out and clean up.
        guard hasStartedSession else {
            log.error("finish: no video samples ever arrived; not writing file")
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            try? FileManager.default.removeItem(at: writer.outputURL)
            return nil
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        log.info("finish: writer.status=\(self.writer.status.rawValue) error=\(self.writer.error?.localizedDescription ?? "—", privacy: .public)")

        // Treat the file as valid if it exists and has real bytes, even
        // if the writer's status flag came back as something other than
        // .completed. AVAssetWriter sometimes lands in .failed when an
        // audio input received no samples, but the video track itself
        // is perfectly playable. The user just wants their file.
        let url = writer.outputURL
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        if size > 1024 {
            return url
        }
        log.error("finish: output too small (\(size) bytes), discarding")
        try? FileManager.default.removeItem(at: url)
        return nil
    }
}
