import AVFoundation
import Foundation
import OSLog
import Speech

/// One spoken phrase chopped out of a recognition result. The transcriber
/// groups SFTranscriptionSegments into roughly sentence-sized chunks so the
/// caller can spawn a text overlay per phrase instead of one giant block.
struct CaptionSegment: Sendable, Identifiable {
    let id = UUID()
    let text: String
    /// Start time relative to the source audio file (seconds).
    let start: TimeInterval
    /// Duration in seconds.
    let duration: TimeInterval
}

/// SFSpeechRecognizer wrapper that transcribes an audio file end-to-end and
/// returns an array of `CaptionSegment`s ready to drop on the caption track.
///
/// Authorization, recognizer availability, and locale fall-back are all
/// handled here so the view model can stay focused on timeline edits.
@MainActor
final class CaptionTranscriber {
    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "CaptionTranscriber")

    /// Cap each caption to ~this many words so they stay readable on screen.
    /// 7 words ≈ 2-3 seconds of speech at a normal rate.
    private let maxWordsPerSegment: Int = 7

    enum TranscribeError: LocalizedError {
        case authorizationDenied
        case recognizerUnavailable
        case noSpeechFound
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .authorizationDenied:
                return "Grant Speech Recognition access in System Settings → Privacy & Security to auto-caption clips."
            case .recognizerUnavailable:
                return "Speech recognition isn't available for this locale right now."
            case .noSpeechFound:
                return "Couldn't find any speech in this clip."
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    /// Ask the user for permission once and cache the answer.
    @discardableResult
    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Transcribe `audioURL` into caption-sized segments. Throws if the user
    /// has denied speech recognition access or the recognizer can't run.
    func transcribe(audioURL: URL) async throws -> [CaptionSegment] {
        let status = await requestAuthorization()
        guard status == .authorized else {
            Self.log.error("Speech recognition not authorized: \(status.rawValue)")
            throw TranscribeError.authorizationDenied
        }

        guard let recognizer = SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw TranscribeError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let segments = try await runRecognition(recognizer: recognizer, request: request)
        if segments.isEmpty {
            throw TranscribeError.noSpeechFound
        }
        return segments
    }

    private func runRecognition(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> [CaptionSegment] {
        try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { [maxWordsPerSegment] result, error in
                if let error {
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(throwing: TranscribeError.underlying(error))
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                if !hasResumed {
                    hasResumed = true
                    let captions = Self.chunk(
                        segments: result.bestTranscription.segments,
                        maxWords: maxWordsPerSegment
                    )
                    continuation.resume(returning: captions)
                }
            }
        }
    }

    /// Group the per-word SFTranscriptionSegments into chunks of at most
    /// `maxWords`, breaking on sentence-ending punctuation when possible.
    private static func chunk(
        segments: [SFTranscriptionSegment],
        maxWords: Int
    ) -> [CaptionSegment] {
        guard !segments.isEmpty else { return [] }

        var output: [CaptionSegment] = []
        var bucket: [SFTranscriptionSegment] = []

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            let text = bucket.map { $0.substring }.joined(separator: " ")
            let start = first.timestamp
            let end = last.timestamp + last.duration
            output.append(CaptionSegment(text: text, start: start, duration: max(0.4, end - start)))
            bucket.removeAll(keepingCapacity: true)
        }

        for segment in segments {
            bucket.append(segment)
            let endsWithPunctuation = segment.substring.last.map { ".!?".contains($0) } ?? false
            if bucket.count >= maxWords || endsWithPunctuation {
                flush()
            }
        }
        flush()
        return output
    }
}
