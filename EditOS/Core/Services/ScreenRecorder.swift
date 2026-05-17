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
    /// Last failure surfaced by the writer or the stream. Used by the
    /// coordinator to put a real error message in the failure alert
    /// instead of a generic "something broke" string.
    private(set) var lastError: Error?
    /// Host-clock seconds at which the first kept video sample arrived.
    /// SCStream stamps samples with `CMClockGetHostTimeClock`, the same
    /// clock AVCaptureSession uses, so this can be diff'd against the
    /// camera recorder's first PTS to derive the exact wall-clock
    /// offset between the two recordings (proper sync, no guessing).
    private(set) var firstSamplePTSSeconds: TimeInterval?

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
        firstSamplePTSSeconds = nil
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
        lastError = nil

        do {
            try await stream.stopCapture()
        } catch {
            Self.log.error("stopCapture failed: \(error.localizedDescription, privacy: .public)")
        }

        let result = await output.finish()

        // Snapshot the first PTS for the coordinator's wall-clock
        // offset math against the camera recorder.
        if let pts = output.firstSamplePTS {
            firstSamplePTSSeconds = pts.seconds
        }

        self.stream = nil
        self.output = nil
        self.startWallTime = nil

        if let url = result.url {
            lastRecordingURL = url
            return url
        }
        lastError = result.error
        return nil
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
    /// Pixel-buffer adaptor wrapping `videoInput`. We feed the writer
    /// via this adaptor (extracted CVPixelBuffer + PTS) rather than by
    /// handing the raw CMSampleBuffer to `videoInput.append` directly.
    /// SCStream samples carry attachment arrays that AVAssetWriter
    /// trips over with OSStatus -12737 (`kCMSampleBufferError_ArrayTooSmall`);
    /// the adaptor only sees the pixel data and ignores those.
    let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    let audioInput: AVAssetWriterInput?

    private nonisolated(unsafe) var hasStartedSession = false
    /// First-video-sample PTS, exposed for wall-clock alignment with
    /// the camera recorder.
    private nonisolated(unsafe) var _firstSamplePTS: CMTime?
    var firstSamplePTS: CMTime? { _firstSamplePTS }

    init(outputURL: URL, configuration: SCStreamConfiguration, includeAudio: Bool) throws {
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        // H.264 requires even-numbered dimensions on most encoders.
        let evenWidth = (Int(configuration.width) / 2) * 2
        let evenHeight = (Int(configuration.height) / 2) * 2

        // Codec + dimensions only — mirror Apple's official
        // ScreenCaptureKit sample. The encoder picks sensible defaults
        // for profile / level / colorimetry on macOS.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: NSNumber(value: evenWidth),
            AVVideoHeightKey: NSNumber(value: evenHeight)
        ]
        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        // Tell the adaptor what pixel format / dimensions to expect.
        // Matches what SCStream produces (BGRA via `pixelFormat`).
        let pbAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: NSNumber(value: evenWidth),
            kCVPixelBufferHeightKey as String: NSNumber(value: evenHeight)
        ]
        self.videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pbAttributes
        )
        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        } else {
            throw RecorderError.failedToStart(NSError(
                domain: "ScreenRecorder", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Writer rejected video input"]
            ))
        }

        if includeAudio {
            // SCStream delivers system audio at 48 kHz stereo. Asking
            // the writer for 44.1 kHz forces a resample that the
            // hardware AAC encoder sometimes refuses, ending the
            // whole writer in `.failed`. Match the source rate.
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000
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
            // Open the writer session on the FIRST complete video
            // sample (not on audio — audio frequently lands a beat
            // before video, and starting at the audio PTS would
            // reject all the video samples whose PTSs come slightly
            // earlier than the audio's first frame).
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !hasStartedSession {
                writer.startSession(atSourceTime: pts)
                hasStartedSession = true
                _firstSamplePTS = pts
            }
            // Pull the pixel buffer out and feed it through the
            // adaptor. This skips whatever SCStream-specific sample
            // attachments were triggering -12737 inside AVAssetWriter
            // when we appended the CMSampleBuffer wholesale.
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            if videoInput.isReadyForMoreMediaData {
                if !videoAdaptor.append(pixelBuffer, withPresentationTime: pts) {
                    Logger(subsystem: "com.damioffice.EditOS", category: "ScreenRecorder")
                        .error("pixel adaptor append failed: \(self.writer.error?.localizedDescription ?? "—", privacy: .public) (status=\(self.writer.status.rawValue))")
                }
            }
        case .audio, .microphone:
            // Drop audio that arrives before the first video frame —
            // there's no session to anchor it to yet, and appending
            // pre-session audio would put `writer.status` into
            // `.failed`.
            guard hasStartedSession, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
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

    /// Result type carries the URL on success or the writer's error on
    /// failure, so the coordinator can show a real message instead of
    /// a generic alert.
    struct FinishResult {
        let url: URL?
        let error: Error?
    }

    func finish() async -> FinishResult {
        let log = Logger(subsystem: "com.damioffice.EditOS", category: "ScreenRecorder")

        // If no samples ever arrived the writer never entered a
        // writeable session — finishWriting would produce a 0-byte or
        // malformed file. Bail out and clean up.
        guard hasStartedSession else {
            log.error("finish: no video samples ever arrived; not writing file")
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            try? FileManager.default.removeItem(at: writer.outputURL)
            return FinishResult(url: nil, error: NSError(
                domain: "ScreenRecorder", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "No frames were captured. ScreenCaptureKit didn't deliver any video samples — check that Screen Recording is granted in System Settings."]
            ))
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        log.info("finish: writer.status=\(self.writer.status.rawValue) error=\(self.writer.error?.localizedDescription ?? "—", privacy: .public)")

        // Strict success: only return the URL when the writer actually
        // completed cleanly. A `.failed` status leaves a file with a
        // partial moov atom that QuickTime and AVFoundation both
        // refuse to open — better to delete it and tell the user why.
        if writer.status == .completed {
            return FinishResult(url: writer.outputURL, error: nil)
        }
        // Synthesize a real error even when writer.error is nil — AVAssetWriter
        // sometimes lands in `.failed` with no attached error, and surfacing
        // "the file didn't finish writing" with no domain leaves the user
        // (and us) blind. Capture the raw status integer at minimum.
        let statusName = ["unknown", "writing", "completed", "failed", "cancelled"]
        let statusLabel = (0..<statusName.count).contains(writer.status.rawValue)
            ? statusName[writer.status.rawValue]
            : "raw-\(writer.status.rawValue)"
        let err = writer.error ?? NSError(
            domain: "ScreenRecorder", code: -5,
            userInfo: [NSLocalizedDescriptionKey: "Writer ended in status .\(statusLabel) (raw \(writer.status.rawValue)) with no attached error."]
        )
        try? FileManager.default.removeItem(at: writer.outputURL)
        return FinishResult(url: nil, error: err)
    }
}
