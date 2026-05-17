import SwiftUI

/// Non-interactive visual indicator shown over the screen while a
/// recording is in progress. Same dim-everywhere-cut-out-the-selection
/// effect as `SelectionOverlay`, but with no resize handles, no mode
/// picker, no controls — just a clear viewport over the area being
/// captured so the user always knows exactly what's in frame.
///
/// The host window must set `sharingType = .none` so this overlay is
/// invisible to ScreenCaptureKit, otherwise it would recursively appear
/// in the recording itself.
struct RecordingFrameOverlay: View {
    /// Rectangle to highlight in screen (SwiftUI top-left) coordinates.
    /// `nil` ⇒ full-display recording: skip the dim layer entirely and
    /// draw a thin red border around the screen edge instead.
    let highlight: CGRect?

    var body: some View {
        ZStack {
            if let rect = highlight {
                // Dim mask with the recorded rect cut out via even-odd
                // fill — identical to the selection overlay so the
                // visual transition from selection → recording is
                // continuous.
                GeometryReader { proxy in
                    Path { path in
                        path.addRect(proxy.frame(in: .local))
                        path.addRect(rect)
                    }
                    .fill(.black.opacity(0.35), style: FillStyle(eoFill: true, antialiased: true))
                }

                // Glowing red border to make "you are recording" clear
                // at a glance. Subtle outer drop shadow gives it a bit
                // of presence without obscuring the content beneath.
                Rectangle()
                    .strokeBorder(Color(red: 0.95, green: 0.30, blue: 0.30), lineWidth: 2)
                    .frame(width: rect.width + 2, height: rect.height + 2)
                    .position(x: rect.midX, y: rect.midY)
                    .shadow(color: Color(red: 0.95, green: 0.30, blue: 0.30).opacity(0.55), radius: 6)
            } else {
                // Full-display: just a 4pt red glow around the perimeter.
                Rectangle()
                    .strokeBorder(Color(red: 0.95, green: 0.30, blue: 0.30), lineWidth: 4)
                    .shadow(color: Color(red: 0.95, green: 0.30, blue: 0.30).opacity(0.5), radius: 8)
            }
        }
        .allowsHitTesting(false)
    }
}
