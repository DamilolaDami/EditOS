import AVFoundation
import CoreMedia
import Foundation
import Observation
import OSLog

/// Captures the default camera to a `.mov` while the screen recorder
/// is running in parallel.
///
/// Uses `AVCaptureVideoDataOutput` + a manual `AVAssetWriter` rather
/// than `AVCaptureMovieFileOutput`. The latter has a silent-failure
/// mode where `startRecording` is accepted but no
/// `didStartRecordingTo` / `didFinishRecordingTo` delegate callback
/// ever fires — leaving the coordinator awaiting a continuation that
/// never resumes and producing no file on disk. The video-data-output
/// path mirrors how `ScreenRecorder` writes screen frames and gives us
/// every per-frame signal we need to diagnose problems.
@MainActor
@Observable
final class CameraRecorder: NSObject {
    private(set) var isRecording: Bool = false
    private(set) var lastRecordingURL: URL?
    private(set) var lastError: Error?

    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "CameraRecorder")

    /// Host-clock seconds at which the first video sample arrived.
    /// SCStream and AVCaptureVideoDataOutput both stamp samples with
    /// CMClockGetHostTimeClock, so subtracting one from the other
    /// gives the real wall-clock offset between the two recorders'
    /// first frames — proper sync, no guessing.
    private(set) var firstSamplePTSSeconds: TimeInterval?

    /// Exposed so the selection overlay's `AVCaptureVideoPreviewLayer`
    /// can render the live feed.
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let outputQueue = DispatchQueue(label: "com.damioffice.EditOS.CameraRecorder.frames", qos: .userInitiated)
    private var configured = false

    /// Owns the on-disk writer + the per-frame append loop. Lives off
    /// MainActor — the AVCaptureVideoDataOutput delegate fires on a
    /// background queue and writing has to keep up with 30 fps.
    private var output: WriterOutput?

    var isSessionRunning: Bool { session.isRunning }

    // MARK: - Permission

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Session lifecycle

    /// Configure the session + start it running, without writing a
    /// file. Used by the selection overlay to power its live preview
    /// and to keep the camera warm between toggling Camera off → on.
    func prepareSession() async throws {
        guard Self.isAuthorized else { throw CameraRecorderError.permissionDenied }
        try configureIfNeeded()
        guard !session.isRunning else { return }
        await Task.detached { [session] in session.startRunning() }.value
        Self.log.info("Camera session running")
    }

    /// Stop the session and release the camera (turns the green light
    /// off). Best-effort terminates any in-progress recording first.
    func endSession() async {
        if isRecording {
            _ = await stop()
        }
        guard session.isRunning else { return }
        await Task.detached { [session] in session.stopRunning() }.value
        Self.log.info("Camera session stopped")
    }

    // MARK: - Recording

    /// Begin writing frames from the data output to a new `.mov`.
    /// Requires `prepareSession()` has run; runs it itself if not.
    @discardableResult
    func start() async throws -> URL {
        guard !isRecording else { throw CameraRecorderError.alreadyRecording }
        try await prepareSession()

        let url = try Self.makeOutputURL()
        try? FileManager.default.removeItem(at: url)

        // Detect the active capture format's resolution so the writer
        // matches what the input device actually delivers. Falling
        // back to 1280×720 for the (unlikely) case the input isn't
        // queryable yet.
        let dimensions = currentInputDimensions() ?? CGSize(width: 1280, height: 720)
        let evenWidth = (Int(dimensions.width) / 2) * 2
        let evenHeight = (Int(dimensions.height) / 2) * 2
        Self.log.info("Camera writing at \(evenWidth, privacy: .public)x\(evenHeight, privacy: .public) → \(url.path, privacy: .public)")

        let output = try WriterOutput(outputURL: url, width: evenWidth, height: evenHeight)
        guard output.writer.startWriting() else {
            let err = output.writer.error ?? NSError(
                domain: "CameraRecorder", code: -10,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter refused to start"]
            )
            throw CameraRecorderError.writerRefused(err)
        }

        self.output = output
        firstSamplePTSSeconds = nil
        videoOutput.setSampleBufferDelegate(output, queue: outputQueue)

        isRecording = true
        lastRecordingURL = url
        lastError = nil
        return url
    }

    /// Stop the active recording and finalise the file. Watchdog'd at
    /// 5s in case `writer.finishWriting()` ever stalls (it shouldn't,
    /// but defensive).
    @discardableResult
    func stop() async -> URL? {
        guard isRecording, let output else { return nil }
        isRecording = false

        // Detach the delegate so no more frames land while the writer
        // is finalising.
        videoOutput.setSampleBufferDelegate(nil, queue: nil)

        let url = await withTaskGroup(of: URL?.self) { group -> URL? in
            group.addTask { await output.finish() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        // Snapshot the first PTS the writer accepted so the coordinator
        // can compute the wall-clock offset against the screen track.
        if let pts = output.firstSamplePTS {
            firstSamplePTSSeconds = pts.seconds
        }

        if url == nil {
            Self.log.error("Camera stop: finishWriting returned no URL (timeout or status != completed). frames appended: \(output.appendedFrameCount)")
            lastError = NSError(
                domain: "CameraRecorder", code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Writer didn't finalise — \(output.appendedFrameCount) frame(s) appended"]
            )
        } else {
            Self.log.info("Camera stop: wrote \(output.appendedFrameCount) frames")
        }

        self.output = nil
        return url
    }

    // MARK: - Session configuration

    private func configureIfNeeded() throws {
        guard !configured else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CameraRecorderError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraRecorderError.cannotAddInput
        }
        session.addInput(input)

        // BGRA matches what AVAssetWriter's pixel-buffer adaptor wants
        // when we pass `kCVPixelFormatType_32BGRA` source attributes.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        guard session.canAddOutput(videoOutput) else {
            throw CameraRecorderError.cannotAddOutput
        }
        session.addOutput(videoOutput)

        configured = true
    }

    private func currentInputDimensions() -> CGSize? {
        guard let input = session.inputs.first as? AVCaptureDeviceInput else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(input.device.activeFormat.formatDescription)
        guard dims.width > 0, dims.height > 0 else { return nil }
        return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
    }

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
        return dir.appending(path: "Camera \(stamp).mov")
    }
}

// MARK: - Errors

enum CameraRecorderError: LocalizedError {
    case alreadyRecording
    case permissionDenied
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case writerRefused(Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:    return "Camera is already recording."
        case .permissionDenied:    return "Grant Camera access in System Settings → Privacy & Security."
        case .noCamera:            return "No camera was found on this Mac."
        case .cannotAddInput:      return "AVCaptureSession refused the camera input."
        case .cannotAddOutput:     return "AVCaptureSession refused the video output."
        case .writerRefused(let e): return "AVAssetWriter refused to start: \(e.localizedDescription)"
        }
    }
}

// MARK: - WriterOutput (per-frame pump)

/// Owns the camera's `AVAssetWriter` and appends every video frame
/// directly from `AVCaptureVideoDataOutput`'s delegate queue. Lives
/// nonisolated — the queue passed to `setSampleBufferDelegate` is the
/// natural serialisation point.
private final class WriterOutput: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private nonisolated(unsafe) var hasStartedSession = false
    private nonisolated(unsafe) var _appendedFrameCount: Int = 0
    /// PTS of the first kept video sample (in the host-clock domain
    /// AVCaptureVideoDataOutput stamps onto every CMSampleBuffer).
    /// Exposed so the coordinator can compute the wall-clock offset
    /// against the screen recorder's first audio/video sample and
    /// place the cam clip at the exact right position on the
    /// timeline — proper sync, not a guess.
    private nonisolated(unsafe) var _firstSamplePTS: CMTime?
    var firstSamplePTS: CMTime? { _firstSamplePTS }
    var appendedFrameCount: Int { _appendedFrameCount }

    init(outputURL: URL, width: Int, height: Int) throws {
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: NSNumber(value: width),
            AVVideoHeightKey: NSNumber(value: height)
        ]
        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let pbAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height)
        ]
        self.videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pbAttributes
        )
        guard writer.canAdd(videoInput) else {
            throw CameraRecorderError.cannotAddOutput
        }
        writer.add(videoInput)
        super.init()
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard writer.status == .writing else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !hasStartedSession {
            writer.startSession(atSourceTime: pts)
            hasStartedSession = true
            _firstSamplePTS = pts
        }
        if videoInput.isReadyForMoreMediaData {
            if videoAdaptor.append(pixelBuffer, withPresentationTime: pts) {
                _appendedFrameCount += 1
            }
        }
    }

    /// Finalise the writer and return the URL if it lands in
    /// `.completed`. Nil on any other state.
    func finish() async -> URL? {
        if !hasStartedSession {
            videoInput.markAsFinished()
            try? FileManager.default.removeItem(at: writer.outputURL)
            return nil
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        if writer.status == .completed {
            return writer.outputURL
        }
        try? FileManager.default.removeItem(at: writer.outputURL)
        return nil
    }
}
