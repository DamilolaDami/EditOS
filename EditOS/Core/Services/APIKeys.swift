import Foundation

/// External-service credentials, lazy-loaded from a gitignored
/// `Secrets.plist` bundled with the app at build time.
///
/// Why a runtime plist and not `xcconfig` or `Info.plist` substitution:
/// - The plist file is straightforward to swap per-environment (dev /
///   staging / release) without touching build settings.
/// - The file is gitignored, so contributors can fork without pushing
///   their own keys, and CI can drop a different plist before signing.
///
/// Setup:
/// 1. Copy `EditOS/Resources/Secrets.example.plist` to
///    `EditOS/Resources/Secrets.plist`.
/// 2. Fill in your GIPHY + Freesound keys (both optional — the
///    corresponding panels gracefully disable when the key is missing).
/// 3. Add `Secrets.plist` to the EditOS target via Xcode → File → Add
///    Files… so it's copied into the bundle. (It's gitignored so it
///    won't be committed.)
///
/// Without the plist (or with empty values), the app builds and runs
/// fine — just with the third-party media panels grayed out and an
/// inline hint telling the user to add a key.
enum APIKeys {
    /// GIPHY developer key. `nil` means the Stickers panel disables
    /// itself and shows a "set up your API key" hint.
    static var giphy: String? { value(forKey: "GIPHY_API_KEY") }

    /// Freesound v2 API token. `nil` means the Audio library's
    /// Freesound search disables itself.
    static var freesound: String? { value(forKey: "FREESOUND_API_TOKEN") }

    /// True when at least one external-service key is available. Useful
    /// for first-run UI that wants to mention the integrations only
    /// when they'll actually work.
    static var hasAnyKey: Bool { giphy != nil || freesound != nil }

    // MARK: - Lookup

    /// Read a string from `Secrets.plist`. Returns `nil` when the file
    /// is missing or the value is blank, so call sites always get a
    /// defined-value / nil pair instead of an empty string.
    private static func value(forKey key: String) -> String? {
        let trimmed = secrets[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Lazy-parsed `Secrets.plist`. Empty dictionary when the file is
    /// missing — keeps every call site nil-safe.
    private static let secrets: [String: String] = loadSecrets()

    private static func loadSecrets() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let parsed = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: String]
        else {
            return [:]
        }
        return parsed
    }
}
