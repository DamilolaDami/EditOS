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

    /// Resume callback that resolves when
    /// `fileOutput(_:didFinishRecordingTo:from:error:)` fires. Closure
    /// rather than a raw continuation so a timeout watchdog and the
    /// delegate can both call it — whoever wins resumes the awaiter
    /// and subsequent calls become no-ops via the lock inside.
    private var stopContinuation: ((URL?) -> Void)?

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
    ///
    /// Bounded by a 5s watchdog: if AVCaptureMovieFileOutput's
    /// finish-recording delegate never fires (we've seen it stick when
    /// the session was interrupted or no frames were actually written),
    /// the watchdog resumes the awaiter with `nil` instead of
    /// deadlocking the whole stop flow. That keeps the coordinator's
    /// post-recording UI alive so the user sees a result either way.
    @discardableResult
    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        let url: URL? = await withCheckedContinuation { cont in
            let lock = NSLock()
            var didResume = false
            let resume: (URL?) -> Void = { value in
                lock.lock()
                let shouldResume = !didResume
                didResume = true
                lock.unlock()
                if shouldResume {
                    cont.resume(returning: value)
                }
            }
            self.stopContinuation = resume
            movieOutput.stopRecording()
            // Watchdog. Independent Task so it isn't tied to MainActor
            // re-entrancy.
            Task.detached {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                Self.log.error("Camera stop timeout — AVCaptureMovieFileOutput delegate never fired within 5s, forcing nil result")
                resume(nil)
            }
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
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        // If this never fires, the recording didn't actually start —
        // important diagnostic since stopRecording then often won't
        // fire `didFinishRecordingTo` either.
        Self.log.info("Camera didStartRecordingTo \(fileURL.path, privacy: .public)")
    }

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
                self.stopContinuation?(nil)
            } else {
                Self.log.info("Camera didFinishRecordingTo \(outputFileURL.path, privacy: .public)")
                self.stopContinuation?(outputFileURL)
            }
            self.stopContinuation = nil
        }
    }
}
