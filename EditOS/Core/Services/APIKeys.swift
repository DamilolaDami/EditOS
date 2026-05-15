import Foundation

/// External-service credentials.
///
/// ⚠️ Replace these before publishing. For an open-source repo these
/// belong outside of source control — either read from a gitignored
/// `Secrets.plist` shipped with the build, an environment variable, or
/// macOS Keychain. Hard-coded here for development speed only.
enum APIKeys {
    static let giphy = "lIgPk1nXLrz8kVyTtHxIXmYawHKKjcmz"
    static let freesound = "QDxUwKIwbm68likTfWvDwgLELAU5RU1qNkpNsaJL"
}
