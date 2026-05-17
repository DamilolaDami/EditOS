import SwiftUI

/// Tiny floating bar shown while a screen recording is active. Pulsing
/// red dot + elapsed-time readout + Stop button. Lives in a borderless
/// NSPanel at the bottom-centre of the screen; the user can grab and
/// drag it elsewhere (the panel itself is `isMovableByWindowBackground`).
struct RecordingControlsBar: View {
    @Bindable var recorder: ScreenRecorder
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing red recording indicator.
            ZStack {
                Circle()
                    .fill(Color(red: 0.95, green: 0.32, blue: 0.32).opacity(0.45))
                    .frame(width: 14, height: 14)
                    .scaleEffect(recorder.isRecording ? 1.6 : 1.0)
                    .opacity(recorder.isRecording ? 0 : 0.7)
                    .animation(
                        .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                        value: recorder.isRecording
                    )
                Circle()
                    .fill(Color(red: 0.95, green: 0.32, blue: 0.32))
                    .frame(width: 9, height: 9)
            }

            Text(elapsedLabel)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 64, alignment: .leading)

            Spacer(minLength: 4)

            Button(action: onStop) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Stop")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color(red: 0.95, green: 0.32, blue: 0.32))
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            // Frosted-glass material with a soft inset highlight so the
            // bar floats nicely against any wallpaper.
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22)
                    .fill(.black.opacity(0.35))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private var elapsedLabel: String {
        let total = Int(recorder.elapsedSeconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
