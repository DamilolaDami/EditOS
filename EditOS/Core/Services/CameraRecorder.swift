import AVFoundation
import Foundation
import Observation
import OSLog

/// Wraps `AVCaptureSession` + `AVCaptureMovieFileOutput` to record from
/// the default camera into a stand-alone `.mov` while the screen
/// recorder is also running. The two recorders are orchestrated in
/// parallel by `RecorderCoordinator` so a single Stop tap finalises
/// both files.
///
/// V1 captures from `defaultDevice(for: .video)` with no per-device
/// configuration — camera selection lives behind a v2 toggle. Audio is
/// intentionally left off this recorder; the screen recorder owns the
/// audio track (system + mic) so mixing them across two outputs would
/// double-record.
@MainActor
@Observable
final class CameraRecorder: NSObject {
    private(set) var isRecording: Bool = false
    private(set) var lastRecordingURL: URL?
    private(set) var lastError: Error?

    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "CameraRecorder")

    /// Exposed so the selection-overlay + recording-active frame
    /// overlay can wire `AVCaptureVideoPreviewLayer` to it and show
    /// the live camera feed before / during the actual recording.
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var configured = false

    /// `true` when the capture session is up and running (which may
    /// be the case even when no recording is active — see
    /// `prepareSession()` for the preview-only path).
    var isSessionRunning: Bool { session.isRunning }

    /// Continuation that resolves when `fileOutput(_:didFinishRecordingTo:from:error:)`
    /// fires. We park `stop()` on this so the coordinator's awaited
    /// stop returns only after the file is actually closed on disk.
    private var stopContinuation: CheckedContinuation<URL?, Never>?

    // MARK: - Permission

    /// `true` when the user has previously granted camera permission;
    /// `false` when they've denied or haven't been asked. Caller pre-
    /// flights this so the macOS TCC prompt fires before any overlay
    /// is on top of it.
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Synchronously triggers the permission dialog if it hasn't been
    /// asked before. Returns true on grant, false on deny / not-asked-
    /// and-deferred. Mirrors `CGRequestScreenCaptureAccess()` shape.
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Public API

    /// Configure the session + start it running, without beginning a
    /// file recording. Used by the selection overlay to show a live
    /// preview before the user hits Start, and to keep the preview
    /// alive between toggling Camera off → on without tearing down
    /// the AVCaptureSession each time.
    func prepareSession() async throws {
        guard Self.isAuthorized else { throw CameraRecorderError.permissionDenied }
        try configureIfNeeded()
        guard !session.isRunning else { return }
        // `startRunning()` is blocking — hop off MainActor so the few
        // hundred ms of camera spin-up don't stall the UI.
        await Task.detached { [session] in session.startRunning() }.value
    }

    /// Stop the session and release the camera. Safe to call when no
    /// session has ever started; idempotent.
    func endSession() async {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        guard session.isRunning else { return }
        await Task.detached { [session] in session.stopRunning() }.value
    }

    /// Begin writing a movie file to disk. Requires that
    /// `prepareSession()` has run successfully (or it runs that path
    /// itself). Returns the file URL being written.
    @discardableResult
    func start() async throws -> URL {
        guard !isRecording else { throw CameraRecorderError.alreadyRecording }
        try await prepareSession()

        let url = try Self.makeOutputURL()
        try? FileManager.default.removeItem(at: url)

        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        lastRecordingURL = url
        lastError = nil
        return url
    }

    /// Stop the active movie recording. Leaves the session running so
    /// the caller can decide whether to also call `endSession()` —
    /// typically used right after to fully release the camera.
    @discardableResult
    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        let url: URL? = await withCheckedContinuation { cont in
            self.stopContinuation = cont
            movieOutput.stopRecording()
        }
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

        guard session.canAddOutput(movieOutput) else {
            throw CameraRecorderError.cannotAddOutput
        }
        session.addOutput(movieOutput)

        configured = true
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

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Camera is already recording."
        case .permissionDenied: return "Grant Camera access in System Settings → Privacy & Security."
        case .noCamera:         return "No camera was found on this Mac."
        case .cannotAddInput:   return "AVCaptureSession refused the camera input."
        case .cannotAddOutput:  return "AVCaptureSession refused the movie output."
        }
    }
}

// MARK: - Delegate

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // The delegate fires on AVFoundation's queue. Hop back to
        // MainActor so the observable state mutates safely and the
        // awaited `stop()` resumes on the actor it was called from.
        Task { @MainActor in
            if let error {
                Self.log.error("Camera finishWriting failed: \(error.localizedDescription, privacy: .public)")
                self.lastError = error
                try? FileManager.default.removeItem(at: outputFileURL)
                self.stopContinuation?.resume(returning: nil)
            } else {
                self.stopContinuation?.resume(returning: outputFileURL)
            }
            self.stopContinuation = nil
        }
    }
}
