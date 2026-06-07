#!/usr/bin/env bash
# scripts/build-dmg.sh
#
# Builds Vaulté Privé for macOS (Mac Catalyst) and packages it as a DMG.
#
# Prerequisites:
#   brew install create-dmg
#
# Usage:
#   ./scripts/build-dmg.sh [--release] [--notarize]
#
# Environment variables:
#   APPLE_TEAM_ID          — your Apple Developer team ID
#   SIGNING_IDENTITY       — codesign identity, e.g. "Developer ID Application: ..."
#   NOTARIZE_PROFILE       — notarytool credential profile name (keychain profile)
#   BUNDLE_ID_MAC          — macOS bundle ID (default: com.vaultePrive.messengermac)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
PROJECT="$ROOT/Vaulté Privé/Vaulté Privé.xcodeproj"
SCHEME="Vaulté Privé"
CONFIGURATION="${RELEASE:+Release}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="$ROOT/build/mac"
ARCHIVE_PATH="$BUILD_DIR/VaultePrivé.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_DIR="$BUILD_DIR/dmg"
APP_NAME="Vaulté Privé"
DMG_NAME="VaultePrivé-mac.dmg"
BUNDLE_ID="${BUNDLE_ID_MAC:-com.vaultePrive.messengermac}"

for arg in "$@"; do
  case $arg in
    --release) CONFIGURATION=Release ;;
    --notarize) NOTARIZE=1 ;;
  esac
done

echo "→ Configuration: $CONFIGURATION"
echo "→ Archive: $ARCHIVE_PATH"

# ── 1. Archive ─────────────────────────────────────────────────────────────────
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS,variant=Mac Catalyst" \
  -archivePath "$ARCHIVE_PATH" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
  | xcpretty 2>/dev/null || true

# ── 2. Export ──────────────────────────────────────────────────────────────────
cat > "$BUILD_DIR/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${APPLE_TEAM_ID:-GC263SD9A3}</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"

# ── 3. Notarize (optional) ─────────────────────────────────────────────────────
if [[ "${NOTARIZE:-0}" == "1" ]]; then
  echo "→ Notarizing…"
  ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/notarize.zip"
  xcrun notarytool submit "$BUILD_DIR/notarize.zip" \
    --keychain-profile "${NOTARIZE_PROFILE:-vaulte-notarize}" \
    --wait
  xcrun stapler staple "$APP_PATH"
fi

# ── 4. Create DMG ──────────────────────────────────────────────────────────────
rm -rf "$DMG_DIR" && mkdir -p "$DMG_DIR"

create-dmg \
  --volname "Vaulté Privé" \
  --volicon "$ROOT/Vaulté Privé/Vaulté Privé/Assets.xcassets/AppIcon.appiconset/66bb9a58eb175e8e3f747e8568d8891a8c246976da1498e1f976b8547ec01d53.jpeg" \
  --window-pos 200 120 \
  --window-size 540 380 \
  --icon-size 100 \
  --icon "$APP_NAME.app" 130 190 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 410 190 \
  "$DMG_DIR/$DMG_NAME" \
  "$EXPORT_DIR/"

echo ""
echo "✓ DMG ready: $DMG_DIR/$DMG_NAME"
