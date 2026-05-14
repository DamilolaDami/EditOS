import AVFoundation
import Foundation
import Observation

/// Drives playback for an editing session. Wraps `AVPlayer` and exposes the
/// live playhead via `@Observable` so SwiftUI can render the timeline cursor
/// without polling.
@MainActor
@Observable
final class PlaybackEngine {
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying: Bool = false
    private(set) var duration: TimeInterval = 0

    let player: AVPlayer

    private var timeObserver: Any?

    init() {
        self.player = AVPlayer()
        self.player.automaticallyWaitsToMinimizeStalling = true
        observeTime()
    }

    func load(_ result: CompositionResult) {
        let item = AVPlayerItem(asset: result.composition)
        item.audioMix = result.audioMix
        player.replaceCurrentItem(with: item)
        duration = result.composition.duration.seconds
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = clamped
    }

    private func observeTime() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
    }
}
