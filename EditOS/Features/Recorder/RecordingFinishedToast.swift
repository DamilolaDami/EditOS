import Foundation
import SwiftUI

/// Floating notification shown after a screen recording finishes.
/// Sits in the top-right of the primary screen for ~8s with Reveal /
/// Open actions and the resulting filename + file size. Mirrors the
/// system "Screenshot saved" toast that macOS itself uses.
struct RecordingFinishedToast: View {
    let url: URL
    let onReveal: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.20))
                    .frame(width: 40, height: 40)
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Recording saved")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(url.lastPathComponent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = humanFileSize {
                    Text(size)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)

            VStack(spacing: 4) {
                Button(action: onReveal) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                Button(action: onOpen) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Open in QuickTime")
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
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping the toast itself reveals in Finder — same as the
            // Reveal button. The Dismiss is the implicit auto-timeout
            // handled by the coordinator.
            onReveal()
        }
    }

    /// Pretty-printed on-disk size of the resulting file.
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
