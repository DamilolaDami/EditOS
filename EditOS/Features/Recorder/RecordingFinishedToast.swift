import Foundation
import SwiftUI

/// Floating notification shown after a screen recording finishes.
/// Sits in the top-right of the primary screen for ~8s with a primary
/// "Open in EditOS" action (the whole point of recording in-app), plus
/// secondary Reveal-in-Finder and QuickTime-preview affordances.
struct RecordingFinishedToast: View {
    let url: URL
    /// `true` when a parallel camera recording was also captured. The
    /// toast surfaces a "+ Camera" tag so the user knows both clips
    /// will land on the timeline when they tap Open in EditOS.
    var hasCamera: Bool = false
    let onReveal: () -> Void
    let onOpenInEditor: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.20))
                    .frame(width: 38, height: 38)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Recording saved")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if hasCamera {
                        Text("+ Camera")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.55)))
                    }
                }
                Text(url.lastPathComponent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = humanFileSize {
                    Text(size)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 4)

            VStack(spacing: 6) {
                // Primary action — open the recording in a new EditOS
                // project and jump straight into the editor.
                Button(action: onOpenInEditor) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Open in EditOS")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])

                HStack(spacing: 6) {
                    Button(action: onReveal) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")

                    Button(action: onPreview) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Preview in QuickTime")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black.opacity(0.45))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    private var humanFileSize: String? {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              bytes > 0
        else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
