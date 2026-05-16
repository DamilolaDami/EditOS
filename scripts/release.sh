#!/usr/bin/env bash
#
# release.sh — archive → notarize → DMG, all in one.
#
# Prereqs (one-time):
#   1. A "Developer ID Application" cert in your login keychain.
#   2. A notarytool keychain profile named `editos-notary`. Set it up via
#        xcrun notarytool store-credentials editos-notary \
#          --key /path/to/AuthKey_XXXXXXXX.p8 \
#          --key-id XXXXXXXXXX \
#          --issuer ........-....-....-....-............
#
# Output:
#   dist/EditOS-<version>.dmg   — notarized + stapled, ready to publish.
#   dist/EditOS.xcarchive       — archive (kept for crash-symbol uploads).
#
# Usage:
#   ./scripts/release.sh            # full Release build
#   ./scripts/release.sh --no-clean # reuse the existing archive
#
set -euo pipefail

# ----------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------

SCHEME="EditOS"
CONFIGURATION="Release"
PROJECT_PATH="EditOS.xcodeproj"
NOTARY_PROFILE="editos-notary"
EXPORT_OPTIONS_PLIST="scripts/ExportOptions.plist"

DIST_DIR="dist"
ARCHIVE_PATH="$DIST_DIR/EditOS.xcarchive"
EXPORT_DIR="$DIST_DIR/Export"
APP_PATH="$EXPORT_DIR/EditOS.app"
ZIP_PATH="$DIST_DIR/EditOS-notary.zip"

# Colourful, terse progress prints.
say()  { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m⚠ %s\033[0m\n" "$*"; }
fail() { printf "\n\033[1;31m✗ %s\033[0m\n" "$*"; exit 1; }

# ----------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------

cd "$(dirname "$0")/.."  # repo root

[[ -d "$PROJECT_PATH" ]] || fail "Run me from the repo root or inside scripts/."
[[ -f "$EXPORT_OPTIONS_PLIST" ]] || fail "Missing $EXPORT_OPTIONS_PLIST."

# Warn (but don't block) if the dev-only Secrets.plist is missing — the
# resulting build will ship without GIPHY / Freesound integrations.
if [[ ! -f "EditOS/Resources/Secrets.plist" ]]; then
    warn "EditOS/Resources/Secrets.plist not found — GIPHY / Freesound will be disabled in this build."
fi

# Confirm the keychain profile exists. notarytool returns non-zero when
# the profile is unknown, so a noisy preflight here is friendlier than a
# 12-minute archive followed by a notarize fail.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1; then
    fail "notarytool profile '$NOTARY_PROFILE' isn't set up. Run the store-credentials command from the script header."
fi

# Confirm a Developer ID Application cert is installed.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    fail "No 'Developer ID Application' cert in your keychain. Install one via Xcode → Settings → Accounts → Manage Certificates."
fi

# Argparse — single flag, --no-clean, for iterating quickly.
CLEAN=true
for arg in "$@"; do
    case "$arg" in
        --no-clean) CLEAN=false ;;
        --help|-h)
            sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^#//; s/^ //'
            exit 0
            ;;
        *) fail "Unknown arg: $arg" ;;
    esac
done

# ----------------------------------------------------------------------
# 1. Archive
# ----------------------------------------------------------------------

if [[ "$CLEAN" == "true" ]]; then
    say "Cleaning previous build artifacts"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    say "Archiving $SCHEME ($CONFIGURATION)"
    xcodebuild archive \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGN_STYLE=Automatic \
        | grep -E "(error:|warning:|\*\* )" || true

    # xcodebuild swallows fatal errors inside its grep'd output. Verify
    # the archive actually came out the other side.
    [[ -d "$ARCHIVE_PATH" ]] || fail "Archive missing at $ARCHIVE_PATH — check the xcodebuild output above."
else
    say "Reusing existing archive at $ARCHIVE_PATH"
    [[ -d "$ARCHIVE_PATH" ]] || fail "No archive found — drop --no-clean for a fresh build."
fi

# ----------------------------------------------------------------------
# 2. Export the .app from the archive
# ----------------------------------------------------------------------

say "Exporting signed .app"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    | grep -E "(error:|warning:|\*\* )" || true

[[ -d "$APP_PATH" ]] || fail "Export missing at $APP_PATH."

# Confirm the signature looks right before submitting — better to fail
# fast than after a 5-minute notarize round-trip.
say "Verifying codesign"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 \
    | grep -E "valid on disk|satisfies its Designated Requirement" || true

# Hardened runtime + secure timestamp are notarization requirements.
codesign --display --verbose=2 "$APP_PATH" 2>&1 \
    | grep -q "flags=.*runtime" || fail "Bundle isn't hardened-runtime-signed. Check ENABLE_HARDENED_RUNTIME in build settings."

# ----------------------------------------------------------------------
# 3. Notarize
# ----------------------------------------------------------------------

say "Zipping for notary submission"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

say "Submitting to Apple notary (this can take 1–10 minutes)"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

say "Stapling notary ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# ----------------------------------------------------------------------
# 4. Build DMG
# ----------------------------------------------------------------------

# Read the version straight out of the built app's Info.plist so the
# DMG filename always tracks the release.
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_PATH/Contents/Info.plist")
DMG_NAME="EditOS-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

say "Building $DMG_NAME"
rm -f "$DMG_PATH"

# Stage the app + an Applications symlink in a temp folder so the DMG
# opens with the familiar "drag to Applications" layout.
STAGING="$DIST_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "EditOS" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGING"

# Notarization tickets staple to .app and .dmg independently. Stapling
# the DMG too means Gatekeeper validates the wrapper offline.
say "Stapling DMG"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# ----------------------------------------------------------------------
# Done.
# ----------------------------------------------------------------------

say "Done"
printf "  Version : %s (%s)\n" "$VERSION" "$BUILD"
printf "  App     : %s\n" "$APP_PATH"
printf "  DMG     : %s\n" "$DMG_PATH"
printf "  Archive : %s\n" "$ARCHIVE_PATH"
printf "  Size    : %s\n" "$(du -h "$DMG_PATH" | awk '{print $1}')"
