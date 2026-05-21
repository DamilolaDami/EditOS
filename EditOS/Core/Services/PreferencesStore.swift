import Foundation
import Observation
import SwiftUI

/// User-facing preferences that don't live on a specific project —
/// project defaults, snap behaviour, autosave knobs. Backed by
/// `UserDefaults` via `@AppStorage`-style wrappers so values persist
/// across launches without extra plumbing.
///
/// Read by:
///   - `ProjectStore.createProject(...)` for new-project canvas + fps.
///   - `EditorViewModel` for the per-instance `snapEnabled` seed.
///   - `EditorView`'s autosave wiring for the debounce window.
///
/// Anything new that the General settings tab toggles should land
/// here, not in scattered `UserDefaults` reads — keeps the surface
/// discoverable.
@Observable
@MainActor
final class PreferencesStore {
    /// New-project canvas preset. The General tab presents this as a
    /// segmented picker; `ProjectStore.createProject` reads it at
    /// creation time.
    var defaultCanvasPreset: CanvasPreset {
        didSet { defaults.set(defaultCanvasPreset.rawValue, forKey: Keys.defaultCanvasPreset) }
    }

    /// Frame rate applied to a fresh project's canvas.
    var defaultFrameRate: Double {
        didSet { defaults.set(defaultFrameRate, forKey: Keys.defaultFrameRate) }
    }

    /// Whether new projects open with the timeline-edge magnet on.
    /// Existing projects keep whatever was last set.
    var snapEnabledByDefault: Bool {
        didSet { defaults.set(snapEnabledByDefault, forKey: Keys.snapEnabledByDefault) }
    }

    /// Trailing-edge debounce window for autosave, in seconds. Lower
    /// values feel "more saved" but hammer SwiftData on a fast drag;
    /// higher values delay durability. 0.8s is the sweet spot we ship.
    var autoSaveDebounce: Double {
        didSet { defaults.set(autoSaveDebounce, forKey: Keys.autoSaveDebounce) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // First-run defaults match the hardcoded values that shipped
        // before this preference existed, so existing installs see no
        // behavioural change.
        self.defaultCanvasPreset = CanvasPreset(rawValue: defaults.string(forKey: Keys.defaultCanvasPreset) ?? "")
            ?? .hd
        let storedFps = defaults.double(forKey: Keys.defaultFrameRate)
        self.defaultFrameRate = storedFps > 0 ? storedFps : 30
        // UserDefaults returns false for missing Bool keys — use
        // `object(forKey:)` to distinguish "unset" from "explicitly
        // off" so first launches default to on.
        self.snapEnabledByDefault = (defaults.object(forKey: Keys.snapEnabledByDefault) as? Bool) ?? true
        let storedDebounce = defaults.double(forKey: Keys.autoSaveDebounce)
        self.autoSaveDebounce = storedDebounce > 0 ? storedDebounce : 0.8
    }

    /// Resolve the user-picked canvas preset to a concrete
    /// `CanvasFormat` with the selected frame rate baked in.
    func defaultCanvasFormat() -> CanvasFormat {
        var canvas = defaultCanvasPreset.canvasFormat
        canvas.frameRate = defaultFrameRate
        return canvas
    }

    /// One-line subtitle for the General settings tab — keeps the
    /// preset descriptions consistent between the picker and any
    /// hover help.
    static func subtitle(for preset: CanvasPreset) -> String {
        switch preset {
        case .hd:        return "1920 × 1080 — YouTube standard, Reels horizontal."
        case .uhd:       return "3840 × 2160 — 4K master / future-proof renders."
        case .vertical:  return "1080 × 1920 — TikTok, Reels, Shorts."
        case .square:    return "1080 × 1080 — Instagram feed, profile videos."
        }
    }

    enum Keys {
        static let defaultCanvasPreset = "EditOS.preferences.defaultCanvasPreset"
        static let defaultFrameRate    = "EditOS.preferences.defaultFrameRate"
        static let snapEnabledByDefault = "EditOS.preferences.snapEnabledByDefault"
        static let autoSaveDebounce    = "EditOS.preferences.autoSaveDebounce"
    }
}

/// Stable identifier for a built-in canvas preset. Kept as a string-
/// raw enum (rather than a `CanvasFormat` directly) so we can persist
/// the user's *intent* — "vertical" stays "vertical" even if we tweak
/// the underlying resolution numbers later.
enum CanvasPreset: String, CaseIterable, Identifiable, Sendable {
    case hd
    case uhd
    case vertical
    case square

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hd:       return "HD"
        case .uhd:      return "4K"
        case .vertical: return "Vertical"
        case .square:   return "Square"
        }
    }

    var canvasFormat: CanvasFormat {
        switch self {
        case .hd:        return .hd
        case .uhd:       return .uhd
        case .vertical:  return .vertical
        case .square:    return .square
        }
    }

    var aspectGlyph: String {
        switch self {
        case .hd:        return "rectangle"
        case .uhd:       return "tv"
        case .vertical:  return "iphone"
        case .square:    return "square"
        }
    }
}
