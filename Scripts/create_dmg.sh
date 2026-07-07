#!/usr/bin/env bash
# Create a distributable DMG for Ahem.
#
# Usage:
#   ./Scripts/create_dmg.sh /path/to/Ahem.app
#   ./Scripts/create_dmg.sh /path/to/Ahem.app 0.9.0-beta
#
# Prerequisites:
#   - Ahem.app must be Developer ID signed and notarized/stapled before distribution.
#   - hdiutil (included with macOS)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-}"
VERSION_LABEL="${2:-}"

if [[ -z "$APP_PATH" ]]; then
  echo "Usage: $0 /path/to/Ahem.app [version-label]" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH" .app)"

if [[ -z "$VERSION_LABEL" ]]; then
  INFO_PLIST="$APP_PATH/Contents/Info.plist"
  if [[ -f "$INFO_PLIST" ]]; then
  VERSION_LABEL="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || true)"
  fi
  VERSION_LABEL="${VERSION_LABEL:-0.9.0}"
fi

DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/dmg-staging"
DMG_NAME="Ahem-${VERSION_LABEL}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo "Preparing DMG: $DMG_NAME"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Ahem" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGING_DIR"

echo "Created: $DMG_PATH"
echo ""
echo "Verify before upload:"
echo "  hdiutil attach \"$DMG_PATH\""
echo "  spctl -a -vv -t install /Volumes/Ahem/Ahem.app"
