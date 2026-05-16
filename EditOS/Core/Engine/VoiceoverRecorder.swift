import AVFoundation
import Foundation
import Observation
import OSLog

/// AAC-encoded microphone recorder. Each recording goes into
/// `~/Library/Application Support/EditOS/Voiceovers/<uuid>.m4a` so we keep
/// them with the rest of the project's persistent media. The view model
/// imports the saved file as a regular MediaAsset on completion.
@MainActor
@Observable
final class VoiceoverRecorder: NSObject {
    private(set) var isRecording: Bool = false
    /// Live input level (0…1). Useful for a UI meter; updated 30× per second
    /// while a recording is active.
    private(set) var inputLevel: Double = 0

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "VoiceoverRecorder")

    /// Begin recording. Returns the file URL the recording will write to so
    /// the caller can stash it and surface a label in the UI.
    @discardableResult
    func start() throws -> URL {
        if isRecording { return recorder?.url ?? URL(fileURLWithPath: "/dev/null") }

        let dir = try voiceoverDirectory()
        let url = dir.appending(path: "\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw NSError(domain: "com.damioffice.EditOS.VoiceoverRecorder",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioRecorder refused to start. Is microphone access granted?"])
        }
        self.recorder = recorder
        self.isRecording = true
        startLevelTimer()
        return url
    }

    /// Stop the current recording and return the resulting file URL. Nil if
    /// nothing was active.
    @discardableResult
    func stop() -> URL? {
        guard let recorder, isRecording else { return nil }
        recorder.stop()
        levelTimer?.invalidate()
        levelTimer = nil
        isRecording = false
        inputLevel = 0
        let url = recorder.url
        self.recorder = nil
        return url
    }

    /// Cancel the current recording without keeping the file on disk.
    func cancel() {
        guard let recorder, isRecording else { return }
        recorder.stop()
        levelTimer?.invalidate()
        levelTimer = nil
        isRecording = false
        inputLevel = 0
        try? FileManager.default.removeItem(at: recorder.url)
        self.recorder = nil
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLevel() }
        }
    }

    private func tickLevel() {
        guard let recorder = recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // averagePower is in dB, typically -160…0. Map to a 0…1 visual band.
        let power = recorder.averagePower(forChannel: 0)
        let normalized = max(0, min(1, (power + 50) / 50))
        inputLevel = Double(normalized)
    }

    private func voiceoverDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appending(path: "EditOS/Voiceovers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
