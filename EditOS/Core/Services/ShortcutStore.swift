import AppKit
import Foundation
import Observation
import OSLog
import SwiftUI

// MARK: - Action catalog

/// Every keyboard shortcut the user can rebind, identified by a stable
/// raw value that's safe to persist across releases. Adding a new
/// shortcut means:
///
///   1. Add a case here.
///   2. Provide its display name + category in the relevant extensions.
///   3. Provide its `defaultBinding`.
///   4. Replace the literal `.keyboardShortcut(...)` call site in
///      `AppCommands.swift` with `.keyboardShortcut(shortcuts.swiftUIShortcut(for: .yourCase))`.
///
/// Persistence keys off `rawValue`, so renaming a case is a breaking
/// change for users who've rebound it.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable, Sendable {
    // File
    case newProject
    case showProjectsWindow

    // Edit
    case undo
    case redo
    case cut
    case copy
    case paste
    case duplicate
    case selectAll
    case deselectAll

    // View
    case zoomIn
    case zoomOut
    case resetZoom
    case toggleSnap
    case toggleLibrary
    case toggleInspector

    // Playback
    case togglePlayback
    case stepBack
    case stepForward
    case back1s
    case forward1s
    case goToStart
    case goToEnd

    // Clip
    case splitAtPlayhead
    case toggleMute
    case deleteClip
    case rippleDelete

    // Markers
    case addMarker
    case prevMarker
    case nextMarker

    // Library
    case libraryMedia
    case libraryAudio
    case libraryText
    case libraryStickers
    case libraryFilters
    case libraryCaptions
    case libraryEffects
    case libraryTransitions

    // Workspace (#64)
    case workspaceEditing
    case workspaceColor
    case workspaceAudio
    case workspaceEffects
    case workspaceFullPreview

    var id: String { rawValue }

    enum Category: String, CaseIterable, Sendable {
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case workspace = "Workspace"
        case playback = "Playback"
        case clip = "Clip"
        case markers = "Markers"
        case library = "Library"
    }

    var category: Category {
        switch self {
        case .newProject, .showProjectsWindow:
            return .file
        case .undo, .redo, .cut, .copy, .paste, .duplicate, .selectAll, .deselectAll:
            return .edit
        case .zoomIn, .zoomOut, .resetZoom, .toggleSnap, .toggleLibrary, .toggleInspector:
            return .view
        case .togglePlayback, .stepBack, .stepForward, .back1s, .forward1s, .goToStart, .goToEnd:
            return .playback
        case .splitAtPlayhead, .toggleMute, .deleteClip, .rippleDelete:
            return .clip
        case .addMarker, .prevMarker, .nextMarker:
            return .markers
        case .libraryMedia, .libraryAudio, .libraryText, .libraryStickers,
             .libraryFilters, .libraryCaptions, .libraryEffects, .libraryTransitions:
            return .library
        case .workspaceEditing, .workspaceColor, .workspaceAudio,
             .workspaceEffects, .workspaceFullPreview:
            return .workspace
        }
    }

    var displayName: String {
        switch self {
        case .newProject:          return "New Project"
        case .showProjectsWindow:  return "Show Projects Window"
        case .undo:                return "Undo"
        case .redo:                return "Redo"
        case .cut:                 return "Cut"
        case .copy:                return "Copy"
        case .paste:               return "Paste"
        case .duplicate:           return "Duplicate"
        case .selectAll:           return "Select All Clips"
        case .deselectAll:         return "Deselect All"
        case .zoomIn:              return "Zoom In Timeline"
        case .zoomOut:             return "Zoom Out Timeline"
        case .resetZoom:           return "Reset Timeline Zoom"
        case .toggleSnap:          return "Toggle Snap"
        case .toggleLibrary:       return "Toggle Library"
        case .toggleInspector:     return "Toggle Inspector"
        case .togglePlayback:      return "Play / Pause"
        case .stepBack:            return "Step Back 1 Frame"
        case .stepForward:         return "Step Forward 1 Frame"
        case .back1s:              return "Back 1 Second"
        case .forward1s:           return "Forward 1 Second"
        case .goToStart:           return "Go to Start"
        case .goToEnd:             return "Go to End"
        case .splitAtPlayhead:     return "Split at Playhead"
        case .toggleMute:          return "Mute / Unmute Clip"
        case .deleteClip:          return "Delete Clip"
        case .rippleDelete:        return "Ripple Delete"
        case .addMarker:           return "Add Marker at Playhead"
        case .prevMarker:          return "Jump to Previous Marker"
        case .nextMarker:          return "Jump to Next Marker"
        case .libraryMedia:        return "Library: Media"
        case .libraryAudio:        return "Library: Audio"
        case .libraryText:         return "Library: Text"
        case .libraryStickers:     return "Library: Stickers"
        case .libraryFilters:      return "Library: Filters"
        case .libraryCaptions:     return "Library: Captions"
        case .libraryEffects:      return "Library: Effects"
        case .libraryTransitions:  return "Library: Transitions"
        case .workspaceEditing:    return "Workspace: Editing"
        case .workspaceColor:      return "Workspace: Color"
        case .workspaceAudio:      return "Workspace: Audio"
        case .workspaceEffects:    return "Workspace: Effects"
        case .workspaceFullPreview: return "Workspace: Full Preview"
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .newProject:          return .init(key: .character("n"), modifiers: [.command])
        case .showProjectsWindow:  return .init(key: .character("0"), modifiers: [.command, .shift])
        case .undo:                return .init(key: .character("z"), modifiers: [.command])
        case .redo:                return .init(key: .character("z"), modifiers: [.command, .shift])
        case .cut:                 return .init(key: .character("x"), modifiers: [.command])
        case .copy:                return .init(key: .character("c"), modifiers: [.command])
        case .paste:               return .init(key: .character("v"), modifiers: [.command])
        case .duplicate:           return .init(key: .character("d"), modifiers: [.command])
        case .selectAll:           return .init(key: .character("a"), modifiers: [.command])
        case .deselectAll:         return .init(key: .character("a"), modifiers: [.command, .shift])
        case .zoomIn:              return .init(key: .character("="), modifiers: [.command])
        case .zoomOut:             return .init(key: .character("-"), modifiers: [.command])
        case .resetZoom:           return .init(key: .character("0"), modifiers: [.command])
        case .toggleSnap:          return .init(key: .character("s"), modifiers: [.command, .shift])
        case .toggleLibrary:       return .init(key: .character("l"), modifiers: [.command, .option])
        case .toggleInspector:     return .init(key: .character("i"), modifiers: [.command, .option])
        case .togglePlayback:      return .init(key: .named(.space), modifiers: [])
        case .stepBack:            return .init(key: .named(.leftArrow), modifiers: [])
        case .stepForward:         return .init(key: .named(.rightArrow), modifiers: [])
        case .back1s:              return .init(key: .named(.leftArrow), modifiers: [.shift])
        case .forward1s:           return .init(key: .named(.rightArrow), modifiers: [.shift])
        case .goToStart:           return .init(key: .named(.upArrow), modifiers: [.command])
        case .goToEnd:             return .init(key: .named(.downArrow), modifiers: [.command])
        case .splitAtPlayhead:     return .init(key: .character("b"), modifiers: [.command])
        case .toggleMute:          return .init(key: .character("m"), modifiers: [.command])
        case .deleteClip:          return .init(key: .named(.delete), modifiers: [])
        case .rippleDelete:        return .init(key: .named(.delete), modifiers: [.shift])
        case .addMarker:           return .init(key: .character("m"), modifiers: [])
        case .prevMarker:          return .init(key: .named(.leftArrow), modifiers: [.command, .option])
        case .nextMarker:          return .init(key: .named(.rightArrow), modifiers: [.command, .option])
        case .libraryMedia:        return .init(key: .character("1"), modifiers: [.command])
        case .libraryAudio:        return .init(key: .character("2"), modifiers: [.command])
        case .libraryText:         return .init(key: .character("3"), modifiers: [.command])
        case .libraryStickers:     return .init(key: .character("4"), modifiers: [.command])
        case .libraryFilters:      return .init(key: .character("5"), modifiers: [.command])
        case .libraryCaptions:     return .init(key: .character("6"), modifiers: [.command])
        case .libraryEffects:      return .init(key: .character("7"), modifiers: [.command])
        case .libraryTransitions:  return .init(key: .character("8"), modifiers: [.command])
        case .workspaceEditing:    return .init(key: .character("1"), modifiers: [.control])
        case .workspaceColor:      return .init(key: .character("2"), modifiers: [.control])
        case .workspaceAudio:      return .init(key: .character("3"), modifiers: [.control])
        case .workspaceEffects:    return .init(key: .character("4"), modifiers: [.control])
        case .workspaceFullPreview: return .init(key: .character("5"), modifiers: [.control])
        }
    }
}

// MARK: - Binding model

/// A single key + modifier combination. Designed so JSON encodes
/// stably across releases — `ShortcutKey` and `ShortcutModifiers` both
/// use raw enum / OptionSet representations rather than re-exporting
/// SwiftUI's `KeyEquivalent` / `EventModifiers` (which aren't Codable).
struct ShortcutBinding: Hashable, Codable, Sendable {
    var key: ShortcutKey
    var modifiers: ShortcutModifiers
}

/// Either a literal character key (e.g. "n", "=") or one of the named
/// non-character keys we care about (space, arrows, delete, etc.).
/// Modelled as a sum type so the JSON form is self-describing and the
/// UI can render the right glyph per case.
enum ShortcutKey: Hashable, Codable, Sendable {
    case character(String)
    case named(NamedKey)

    enum NamedKey: String, CaseIterable, Codable, Hashable, Sendable {
        case space
        case returnKey
        case escape
        case tab
        case delete
        case forwardDelete
        case leftArrow
        case rightArrow
        case upArrow
        case downArrow
    }
}

/// Modifier flags. Mirrors `EventModifiers` but Codable.
struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let shift   = ShortcutModifiers(rawValue: 1 << 1)
    static let option  = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)
}

// MARK: - SwiftUI bridging

extension ShortcutKey {
    /// Convert to SwiftUI's `KeyEquivalent`. Character keys map
    /// directly; named keys map case-by-case to SwiftUI's static
    /// constants.
    var asKeyEquivalent: KeyEquivalent {
        switch self {
        case .character(let str):
            return KeyEquivalent(str.first ?? Character(" "))
        case .named(let name):
            switch name {
            case .space:         return .space
            case .returnKey:     return .return
            case .escape:        return .escape
            case .tab:           return .tab
            case .delete:        return .delete
            case .forwardDelete: return .deleteForward
            case .leftArrow:     return .leftArrow
            case .rightArrow:    return .rightArrow
            case .upArrow:       return .upArrow
            case .downArrow:     return .downArrow
            }
        }
    }
}

extension ShortcutModifiers {
    var asEventModifiers: EventModifiers {
        var out: EventModifiers = []
        if contains(.command) { out.insert(.command) }
        if contains(.shift)   { out.insert(.shift) }
        if contains(.option)  { out.insert(.option) }
        if contains(.control) { out.insert(.control) }
        return out
    }
}

extension ShortcutBinding {
    var asKeyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(key.asKeyEquivalent, modifiers: modifiers.asEventModifiers)
    }
}

// MARK: - NSEvent → binding (record flow)

extension ShortcutBinding {
    /// Build a binding from a live `NSEvent.keyDown`. Returns nil for
    /// modifier-only events (the user hasn't yet committed to a key)
    /// or events we can't usefully represent.
    init?(from event: NSEvent) {
        let mods = ShortcutModifiers(nsFlags: event.modifierFlags)

        // Named-key keycodes (NSEvent virtual key codes).
        // 49 space, 53 esc, 48 tab, 36 return, 51 delete, 117 fwdDelete,
        // 123-126 arrows.
        if let named = ShortcutKey.NamedKey.from(keyCode: event.keyCode) {
            self.key = .named(named)
            self.modifiers = mods
            return
        }

        // Otherwise treat it as a character key. Use
        // `charactersIgnoringModifiers` so Cmd+Shift+S still maps to
        // "s" instead of "S" (case is implied by the .shift modifier).
        guard let raw = event.charactersIgnoringModifiers, let ch = raw.first else {
            return nil
        }
        // Reject obvious junk — bare modifier strokes show up with
        // empty or non-printable characters.
        guard ch.isLetter || ch.isNumber || "-=[]\\;',./`".contains(ch) else {
            return nil
        }
        self.key = .character(String(ch).lowercased())
        self.modifiers = mods
    }
}

extension ShortcutModifiers {
    init(nsFlags: NSEvent.ModifierFlags) {
        var out: ShortcutModifiers = []
        if nsFlags.contains(.command)  { out.insert(.command) }
        if nsFlags.contains(.shift)    { out.insert(.shift) }
        if nsFlags.contains(.option)   { out.insert(.option) }
        if nsFlags.contains(.control)  { out.insert(.control) }
        self = out
    }
}

extension ShortcutKey.NamedKey {
    /// Map an `NSEvent.keyCode` (virtual key code) to our named-key
    /// enum. Returns nil for character keys; callers fall through to
    /// the character path.
    static func from(keyCode: UInt16) -> ShortcutKey.NamedKey? {
        switch keyCode {
        case 49:  return .space
        case 36:  return .returnKey
        case 53:  return .escape
        case 48:  return .tab
        case 51:  return .delete
        case 117: return .forwardDelete
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default:  return nil
        }
    }
}

// MARK: - Display

extension ShortcutBinding {
    /// Human-readable glyph string, e.g. `⌘⇧S`, `⌥⌘←`, `Space`.
    /// Settings table renders this; the menu items pick up the same
    /// thing via SwiftUI's built-in shortcut display.
    var displayLabel: String {
        var parts = ""
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key.displayLabel)
        return parts
    }
}

extension ShortcutKey {
    var displayLabel: String {
        switch self {
        case .character(let s): return s.uppercased()
        case .named(let n):
            switch n {
            case .space:         return "Space"
            case .returnKey:     return "↩"
            case .escape:        return "⎋"
            case .tab:           return "⇥"
            case .delete:        return "⌫"
            case .forwardDelete: return "⌦"
            case .leftArrow:     return "←"
            case .rightArrow:    return "→"
            case .upArrow:       return "↑"
            case .downArrow:     return "↓"
            }
        }
    }
}

// MARK: - Store

/// User-facing keyboard-shortcut overrides, persisted to
/// `~/Library/Application Support/EditOS/shortcuts.json`. Unbound
/// actions fall back to the default declared on `ShortcutAction`.
///
/// `@Observable` so the menu bar (built in `AppCommands`) re-evaluates
/// whenever the user rebinds anything — no app restart required.
@Observable
@MainActor
final class ShortcutStore {
    /// Overrides keyed by `ShortcutAction.rawValue`. Defaults are
    /// applied lazily by `binding(for:)`, so this dictionary only
    /// holds user-changed entries.
    private(set) var overrides: [String: ShortcutBinding] = [:]

    private let fileURL: URL
    private static let logger = Logger(subsystem: "com.damioffice.EditOS", category: "ShortcutStore")

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let dir = support.appending(path: "EditOS", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appending(path: "shortcuts.json")
        load()
    }

    /// Effective binding for an action — override if the user set one,
    /// otherwise the action's compile-time default.
    func binding(for action: ShortcutAction) -> ShortcutBinding {
        overrides[action.rawValue] ?? action.defaultBinding
    }

    /// SwiftUI helper — call sites in `AppCommands` use this directly.
    func swiftUIShortcut(for action: ShortcutAction) -> KeyboardShortcut {
        binding(for: action).asKeyboardShortcut
    }

    /// Replace the binding for `action`. Persists immediately so a
    /// crash mid-edit doesn't lose user customisations.
    func rebind(_ action: ShortcutAction, to binding: ShortcutBinding) {
        overrides[action.rawValue] = binding
        persist()
    }

    /// Drop the override for `action`, falling back to its default.
    func resetToDefault(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action.rawValue)
        persist()
    }

    /// Clear every override.
    func resetAll() {
        overrides.removeAll()
        persist()
    }

    /// Returns true if the user has changed this action away from its
    /// default. Used to gate the "Reset" button visibility.
    func isCustomised(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    /// Other actions whose effective binding equals this one. Used by
    /// the Settings UI to flag conflicts inline.
    func actionsBound(to binding: ShortcutBinding, excluding action: ShortcutAction) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { other in
            other != action && self.binding(for: other) == binding
        }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([String: ShortcutBinding].self, from: data)
            // Drop any keys that no longer map to a known action — keeps
            // old custom bindings from silently lingering after we
            // remove a shortcut.
            let validKeys = Set(ShortcutAction.allCases.map(\.rawValue))
            overrides = decoded.filter { validKeys.contains($0.key) }
        } catch {
            Self.logger.error("Failed to load shortcuts.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(overrides)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Self.logger.error("Failed to persist shortcuts.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
